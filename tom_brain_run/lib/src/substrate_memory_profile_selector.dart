// SubstrateMemoryProfileSelector — the concrete, host-built
// `MemoryProfileSelector` that drives the `profile_selector` substrate role
// (I-10 remainder; access spec § 7.4; substrate § 6.2a).
//
// ── Why this lives in `tom_brain_run` ────────────────────────────────────
//
// `tom_brain_access` defines the `MemoryProfileSelector` *interface* but
// depends on neither `tom_brain_substrate` nor `tom_brain_memory` (PE-1:
// access never reaches the substrate directly). The run assembly is the one
// layer that holds both a `TomBrainSubstrateClient` and the memory's profile
// names, so the substrate-backed selector is composed here and injected into
// the access layer as the interface — exactly the seam discipline the
// classifier embed/complete pair already uses.
//
// ── What it does ─────────────────────────────────────────────────────────
//
// It mirrors `SubstrateBridge.retrievalRole('profile_selector', …)`: builds an
// anchored, budgeted `LlmCall` for `role: profile_selector` with the
// `{prompt, history, knownProfiles}` inputs, drains the completion, strips a
// markdown JSON fence, `jsonDecode`s, and lifts the payload through
// `parseRetrievalRoleOutput('profile_selector', json)` into a
// `ProfileSelectorOutput(profile, confidence)` → `ProfileSelection`.
//
// ── The failure contract ─────────────────────────────────────────────────
//
// `MemoryProfileSelector.select` has exactly two outcomes the manager
// understands: a returned `ProfileSelection`, or a *throw* (which
// `SessionManager.selectMemoryProfile` catches → `selectorUnavailable`,
// falling back to `selection.default`; PE-6 graceful degrade). So both a
// genuine substrate failure (the completion stream fails) and a
// *well-returned but unusable* result (non-JSON text, or JSON that does not
// match the role schema) surface here as a throw — in the latter case there is
// no usable profile name to return, so degrading to the default is the only
// honest outcome. The `isKnownProfile` flag carries the orthogonal "the model
// picked a name that is not a real profile" signal, which the manager maps to
// its own `profileUnknown` fall-back without a throw.

import 'dart:convert';

import 'package:tom_brain_access/tom_brain_access.dart'
    show MemoryProfileSelector, ProfileSelection;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SelectionSettings;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Budget, HistoryTurn;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        LlmCall,
        LlmTextDelta,
        LlmRunCompleted,
        LlmRunFailed,
        ProfileSelectorOutput,
        RetrievalRoleDegraded,
        RetrievalRoleParsed,
        TomBrainSubstrateClient,
        parseRetrievalRoleOutput;

/// Builds the substrate-backed memory-profile selector when [selection] is
/// enabled, or returns `null` when it is off (the off-by-default path; access
/// spec § 7.4, PE-6).
///
/// This is the run-assembly gate the provisioner calls: a `null` result leaves
/// `BrainAccessConfig.profileSelector` unset, so the `SessionManager` reports
/// `disabled` and every conversation recalls against the process default
/// profile. When enabled it composes a [SubstrateMemoryProfileSelector] over the
/// booted [substrate] and the live [knownProfiles] lister, using the configured
/// [SelectionSettings.role] as the substrate role id.
MemoryProfileSelector? buildMemoryProfileSelector({
  required TomBrainSubstrateClient substrate,
  required Future<List<String>> Function() knownProfiles,
  required SelectionSettings selection,
}) {
  if (!selection.enabled) return null;
  return SubstrateMemoryProfileSelector(
    substrate: substrate,
    knownProfiles: knownProfiles,
    role: selection.role,
  );
}

/// Thrown by [SubstrateMemoryProfileSelector.select] when the substrate role
/// produces no usable pick — either the completion stream failed, or it
/// returned text that does not parse against the `profile_selector` schema.
///
/// The access-layer `SessionManager` catches any throw from a selector and
/// degrades to `selection.default` (`access.profile.selector.unavailable`,
/// PE-6), so this type exists only to carry a readable [message] into a test
/// or a trail; the manager does not branch on its runtime type.
final class MemoryProfileSelectorException implements Exception {
  /// Why the selection could not be produced.
  final String message;

  const MemoryProfileSelectorException(this.message);

  @override
  String toString() => 'MemoryProfileSelectorException: $message';
}

/// The substrate-backed [MemoryProfileSelector].
///
/// Constructed by the run provisioner from the booted
/// [TomBrainSubstrateClient] and a [knownProfiles] lister (the memory's
/// `<root>/profiles/` names, read live so a newly-created profile is picked
/// up on the next selection). Off by default — the provisioner builds one only
/// when `memory_retrieval.selection.enabled` is set.
final class SubstrateMemoryProfileSelector implements MemoryProfileSelector {
  SubstrateMemoryProfileSelector({
    required TomBrainSubstrateClient substrate,
    required Future<List<String>> Function() knownProfiles,
    String role = 'profile_selector',
    Budget? budget,
  }) : _substrate = substrate,
       _knownProfiles = knownProfiles,
       _role = role,
       _budget = budget ?? _selectorBudget;

  final TomBrainSubstrateClient _substrate;
  final Future<List<String>> Function() _knownProfiles;
  final String _role;
  final Budget _budget;

  /// A generous diagnostic budget for one selection completion. Profile
  /// selection runs once per session (and re-checks rarely), so the cap is a
  /// guard against a wedged provider, not a tight per-turn allowance. (The
  /// `LlmCall` doc refers to a `Budget.unlimited` sentinel; that constant is
  /// not implemented, so a concrete envelope stands in. The public `Budget`
  /// factory is non-`const`, so this is a `static final`, not a `const`.)
  static final Budget _selectorBudget = Budget(
    wallClockMs: 30000,
    tokenSpend: 8000,
    toolCalls: 0,
    memoryWrites: 0,
  );

  @override
  Future<ProfileSelection> select({
    required String prompt,
    required List<HistoryTurn> history,
  }) async {
    final List<String> profiles = await _knownProfiles();
    final LlmCall call = LlmCall(
      roleId: _role,
      inputs: <String, Object?>{
        'prompt': prompt,
        'history': _renderHistory(history),
        'knownProfiles': profiles.join(', '),
      },
      budget: _budget,
      // The Postulate-3 anchor leads the role's system channel, as for every
      // self-issued call.
      anchored: true,
    );

    final String text = await _drainCompletion(call);

    final Map<String, Object?> json = _decodeJsonObject(text);
    final parse = parseRetrievalRoleOutput(_role, json);
    switch (parse) {
      case RetrievalRoleParsed(:final output):
        // The `profile_selector` role id guarantees a ProfileSelectorOutput;
        // any other shape would be a parser bug, not an operational event.
        final selectorOutput = output as ProfileSelectorOutput;
        return ProfileSelection(
          profile: selectorOutput.profile,
          confidence: selectorOutput.confidence,
          // The manager maps an unknown name to its own `profileUnknown`
          // fall-back; the reserved `global` profile is coerced there too.
          isKnownProfile: profiles.contains(selectorOutput.profile),
        );
      case RetrievalRoleDegraded(:final reason):
        // A well-returned but unusable result has no profile to commit to —
        // degrade to the manager's default exactly as a substrate outage does.
        throw MemoryProfileSelectorException(
          'profile_selector output unusable: $reason',
        );
    }
  }

  /// Drains the role completion to its full text, throwing on a stream
  /// failure (the manager catches → `selectorUnavailable`). Mirrors the
  /// substrate bridge's `_completeOnce` drain, minus the trail / tool-call
  /// concerns a retrieval role does not have.
  Future<String> _drainCompletion(LlmCall call) async {
    final StringBuffer buffer = StringBuffer();
    await for (final event in _substrate.completeStream(call)) {
      switch (event) {
        case LlmTextDelta(:final text):
          buffer.write(text);
        case LlmRunCompleted():
          return buffer.toString();
        case LlmRunFailed(:final failure):
          throw MemoryProfileSelectorException(
            'profile_selector completion failed '
            '(${failure.classCode}): ${failure.message}',
          );
        default:
          // Started / tool-call-proposed events carry no answer text.
          break;
      }
    }
    // A well-behaved substrate always terminates with Completed or Failed;
    // reaching here is a contract violation, surfaced as an unavailable selector.
    throw const MemoryProfileSelectorException(
      'profile_selector completion closed without a terminal event',
    );
  }

  /// Renders the conversation [history] into the role's `history:` input line —
  /// one `user:` / `assistant:` pair per turn, oldest first. An empty history
  /// (the `useHistory: false` path, or a brand-new session) renders empty.
  static String _renderHistory(List<HistoryTurn> history) {
    if (history.isEmpty) return '';
    final StringBuffer buffer = StringBuffer();
    for (final turn in history) {
      buffer
        ..writeln('user: ${turn.userPrompt}')
        ..writeln('assistant: ${turn.brainAnswer}');
    }
    return buffer.toString().trimRight();
  }

  /// De-fences and decodes [text] into a JSON object, throwing when it is not
  /// JSON or not an object. A live medium model wraps structured output in a
  /// markdown ```json … ``` fence; a fenced-but-well-formed answer is usable.
  static Map<String, Object?> _decodeJsonObject(String text) {
    final String stripped = _stripJsonFence(text.trim());
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException catch (e) {
      throw MemoryProfileSelectorException(
        'profile_selector output is not JSON: ${e.message}',
      );
    }
    if (decoded is! Map) {
      throw const MemoryProfileSelectorException(
        'profile_selector output is not a JSON object',
      );
    }
    final Map<String, Object?> json = <String, Object?>{};
    decoded.forEach((Object? key, Object? value) => json['$key'] = value);
    return json;
  }

  /// Strips a leading ```json (or ```) fence and its closing ``` from [text].
  /// Mirrors the substrate bridge's `_stripJsonFence` so both structured-output
  /// readers in the brain follow one fence convention.
  static String _stripJsonFence(String text) {
    if (!text.startsWith('```')) return text;
    var inner = text;
    final firstNewline = inner.indexOf('\n');
    if (firstNewline != -1) inner = inner.substring(firstNewline + 1);
    if (inner.endsWith('```')) inner = inner.substring(0, inner.length - 3);
    return inner.trim();
  }
}
