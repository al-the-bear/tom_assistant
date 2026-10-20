// Extension-H memory-profile selector — the substrate-backed host
// implementation of the access layer's `MemoryProfileSelector` seam
// (I-10 remainder; access spec § 7.4; substrate § 6.2a).
//
// The access layer defines the `MemoryProfileSelector` interface and the
// `SessionManager` graceful-degrade contract (those are covered by
// `tom_brain_access/test/identity/memory_profile_selection_test.dart`). This
// suite covers the *concrete* selector composed in `tom_brain_run`: it builds
// an anchored `LlmCall` for `role: profile_selector` over a fake substrate,
// drains the completion, de-fences + decodes JSON, and lifts it through
// `parseRetrievalRoleOutput` into a `ProfileSelection`.
//
// The two outcomes the manager understands are a returned `ProfileSelection`
// or a *throw* (→ `selectorUnavailable`, PE-6). So every unusable path — a
// failed stream, a stream that closes with no terminal event, non-JSON text,
// and a schema-degraded JSON object — surfaces here as a throw. A confident,
// well-formed pick returns; the `isKnownProfile` flag is set from the live
// known-profile list so the manager can map an off-list name to its own
// `profileUnknown` fall-back without a throw.

import 'package:tom_brain_run/tom_brain_run.dart'
    show
        MemoryProfileSelectorException,
        SubstrateMemoryProfileSelector,
        buildMemoryProfileSelector;
import 'package:tom_brain_access/tom_brain_access.dart'
    show
        AccessChannel,
        MemoryProfileSelectionStatus,
        MemoryProfileSelector,
        ProfileSelection,
        SessionManager;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SelectionSettings;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show HistoryTurn, InboundRequest, ResolvedIdentity;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        LlmCall,
        LlmCallReport,
        LlmFailure,
        LlmTextDelta,
        LlmRunCompleted,
        LlmEvent,
        LlmRunFailed,
        LlmRunStarted,
        TomBrainSubstrateClient;
import 'package:test/test.dart';

LlmCallReport _report() => const LlmCallReport(
  providerId: 'fake',
  modelId: 'm',
  anchorHash: 'a',
  promptHash: 'p',
  tokensIn: 0,
  tokensOut: 0,
  retries: 0,
  wallClockMs: 0,
);

/// A fake substrate that scripts the `profile_selector` completion: either a
/// list of chunk texts terminated by `LlmRunCompleted`, or — when [failure]
/// is set — a terminal `LlmRunFailed`, or — when [closeWithoutTerminal] is
/// set — a stream that ends with neither (a contract violation). Records the
/// last `LlmCall` so the role + inputs can be asserted. Every other
/// `TomBrainSubstrateClient` member throws (the selector touches none of them).
final class _ScriptedSubstrate implements TomBrainSubstrateClient {
  _ScriptedSubstrate({
    this.chunks = const <String>[],
    this.failure,
    this.closeWithoutTerminal = false,
  });

  final List<String> chunks;
  final LlmFailure? failure;
  final bool closeWithoutTerminal;

  LlmCall? lastCall;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) async* {
    lastCall = call;
    yield const LlmRunStarted(callId: 'c1', providerId: 'fake', modelId: 'm');
    for (final chunk in chunks) {
      yield LlmTextDelta(chunk);
    }
    if (closeWithoutTerminal) return;
    if (failure != null) {
      yield LlmRunFailed(callId: 'c1', failure: failure!, report: _report());
      return;
    }
    yield LlmRunCompleted(callId: 'c1', report: _report());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SubstrateMemoryProfileSelector _selectorOver(
  _ScriptedSubstrate substrate, {
  List<String> profiles = const <String>['work', 'home'],
}) => SubstrateMemoryProfileSelector(
  substrate: substrate,
  knownProfiles: () async => profiles,
);

Future<ProfileSelection> _select(
  SubstrateMemoryProfileSelector selector, {
  String prompt = 'help me at the office',
  List<HistoryTurn> history = const <HistoryTurn>[],
}) => selector.select(prompt: prompt, history: history);

void main() {
  group('a well-formed pick returns a ProfileSelection', () {
    test('a confident plain-JSON pick lifts profile + confidence', () async {
      final substrate = _ScriptedSubstrate(
        chunks: <String>['{"profile": "work", "confidence": 0.9}'],
      );
      final selection = await _select(_selectorOver(substrate));

      expect(selection.profile, 'work');
      expect(selection.confidence, 0.9);
      expect(selection.isKnownProfile, isTrue);
    });

    test('a markdown ```json fence is stripped before decoding', () async {
      final substrate = _ScriptedSubstrate(
        chunks: <String>[
          '```json\n',
          '{"profile": "home", "confidence": 0.7}\n',
          '```',
        ],
      );
      final selection = await _select(_selectorOver(substrate));

      expect(selection.profile, 'home');
      expect(selection.confidence, 0.7);
      expect(selection.isKnownProfile, isTrue);
    });

    test(
      'a pick of a name not in the known list reports isKnownProfile false',
      () async {
        final substrate = _ScriptedSubstrate(
          chunks: <String>['{"profile": "nope", "confidence": 0.95}'],
        );
        final selection = await _select(
          _selectorOver(substrate, profiles: <String>['work', 'home']),
        );

        // The selector still returns the pick — mapping an off-list name to a
        // fall-back is the manager's job, signalled by this flag.
        expect(selection.profile, 'nope');
        expect(selection.isKnownProfile, isFalse);
      },
    );
  });

  group('the LlmCall the selector builds', () {
    test(
      'carries the profile_selector role, anchored, with joined inputs',
      () async {
        final substrate = _ScriptedSubstrate(
          chunks: <String>['{"profile": "work", "confidence": 0.9}'],
        );
        await _select(
          _selectorOver(substrate, profiles: <String>['work', 'home']),
          prompt: 'the prompt',
          history: <HistoryTurn>[
            const HistoryTurn(userPrompt: 'hi', brainAnswer: 'hello'),
          ],
        );

        final call = substrate.lastCall!;
        expect(call.roleId, 'profile_selector');
        expect(call.anchored, isTrue);
        expect(call.inputs['prompt'], 'the prompt');
        expect(call.inputs['knownProfiles'], 'work, home');
        expect(call.inputs['history'], contains('user: hi'));
        expect(call.inputs['history'], contains('assistant: hello'));
      },
    );

    test('an empty history renders an empty history input', () async {
      final substrate = _ScriptedSubstrate(
        chunks: <String>['{"profile": "work", "confidence": 0.9}'],
      );
      await _select(_selectorOver(substrate));

      expect(substrate.lastCall!.inputs['history'], '');
    });
  });

  group('an unusable result throws (manager degrades to default, PE-6)', () {
    test('a failed completion stream throws', () async {
      final substrate = _ScriptedSubstrate(
        failure: const LlmFailure(
          classCode: 'no_route_available',
          message: 'all providers down',
        ),
      );
      expect(
        () => _select(_selectorOver(substrate)),
        throwsA(isA<MemoryProfileSelectorException>()),
      );
    });

    test('a stream that closes with no terminal event throws', () async {
      final substrate = _ScriptedSubstrate(
        chunks: <String>['{"profile": "work", "confidence": 0.9}'],
        closeWithoutTerminal: true,
      );
      expect(
        () => _select(_selectorOver(substrate)),
        throwsA(isA<MemoryProfileSelectorException>()),
      );
    });

    test('non-JSON answer text throws', () async {
      final substrate = _ScriptedSubstrate(
        chunks: <String>['I think you should use the work profile.'],
      );
      expect(
        () => _select(_selectorOver(substrate)),
        throwsA(isA<MemoryProfileSelectorException>()),
      );
    });

    test('a JSON array (not an object) throws', () async {
      final substrate = _ScriptedSubstrate(chunks: <String>['["work", 0.9]']);
      expect(
        () => _select(_selectorOver(substrate)),
        throwsA(isA<MemoryProfileSelectorException>()),
      );
    });

    test('JSON that fails the profile_selector schema throws', () async {
      // Valid JSON object, but `confidence` is missing — the role parser
      // degrades, which the selector surfaces as a throw.
      final substrate = _ScriptedSubstrate(
        chunks: <String>['{"profile": "work"}'],
      );
      expect(
        () => _select(_selectorOver(substrate)),
        throwsA(isA<MemoryProfileSelectorException>()),
      );
    });
  });

  group('buildMemoryProfileSelector gate (off by default)', () {
    test('returns null when selection is disabled (the default)', () {
      final selector = buildMemoryProfileSelector(
        substrate: _ScriptedSubstrate(),
        knownProfiles: () async => const <String>['work'],
        selection: const SelectionSettings(), // enabled defaults to false
      );
      expect(selector, isNull);
    });

    test('returns a SubstrateMemoryProfileSelector when enabled', () {
      final MemoryProfileSelector? selector = buildMemoryProfileSelector(
        substrate: _ScriptedSubstrate(),
        knownProfiles: () async => const <String>['work'],
        selection: const SelectionSettings(enabled: true),
      );
      expect(selector, isA<SubstrateMemoryProfileSelector>());
    });
  });

  // The boot-wiring proof: the selector the gate composes — concrete, over a
  // scripted substrate — drives a *real* SessionManager to a pin, exactly as
  // the access process consumes it. The disabled gate leaves the manager on the
  // process default.
  group('boot wiring: gate-composed selector drives a real SessionManager', () {
    const enabled = SelectionSettings(
      enabled: true,
      defaultProfile: 'default',
      inconclusiveThreshold: 0.5,
    );

    Future<MemoryProfileSelectionStatus> driveFirstTurn(
      MemoryProfileSelector? selector, {
      required SelectionSettings selection,
      required String text,
    }) async {
      final manager = SessionManager(
        sessionIdMinter: () => 'sess-0',
        profileSelector: selector,
        selection: selection,
      );
      final envelope = InboundRequest(text: text);
      final res = manager.resolve(
        identity: ResolvedIdentity(principalId: 'p1'),
        channel: AccessChannel.openai,
        envelope: envelope,
      );
      final outcome = await manager.selectMemoryProfile(
        resolution: res,
        envelope: envelope,
      );
      return outcome.status;
    }

    test(
      'enabled ⇒ non-null selector ⇒ a confident pick pins the session',
      () async {
        final substrate = _ScriptedSubstrate(
          chunks: <String>['{"profile": "work", "confidence": 0.92}'],
        );
        final selector = buildMemoryProfileSelector(
          substrate: substrate,
          knownProfiles: () async => const <String>['work', 'home'],
          selection: enabled,
        );
        expect(selector, isNotNull);

        final status = await driveFirstTurn(
          selector,
          selection: enabled,
          text: 'help me at the office',
        );

        expect(status, MemoryProfileSelectionStatus.pinned);
      },
    );

    test('disabled ⇒ null selector ⇒ the manager reports disabled', () async {
      final selector = buildMemoryProfileSelector(
        substrate: _ScriptedSubstrate(),
        knownProfiles: () async => const <String>['work'],
        selection: const SelectionSettings(), // disabled default
      );
      expect(selector, isNull);

      final status = await driveFirstTurn(
        selector,
        selection: const SelectionSettings(),
        text: 'hello',
      );

      expect(status, MemoryProfileSelectionStatus.disabled);
    });
  });
}
