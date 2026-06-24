// Procedure selection (Plan step D.16;
// `tom_brain_procedure_specification.md` § 10.2).
//
// The third stage of the dispatcher's `accept → classify → select →
// schedule` pipeline. Given the inbound *kind* the classifier (D.15)
// produced, it resolves the *procedure id* the run coordinator (D.18) will
// schedule.
//
// Policy (spec § 10.2, Plan D.16; route-flip § 4.0.1): for the prototype,
// every inbound classified as `user_prompt` routes to the entry router
// `prompt_analyzer_v1`; anything else surfaces `UnsupportedProcedureKind`.
// This is the single point where the open kind strings the classifier emits
// are narrowed to the closed set of procedures the prototype actually ships
// — the boundary at which an unanticipated kind fails loudly (Q-D.15.1)
// instead of being silently dropped or guessed. The answer branches are
// *not* selectable: they are reached only through the router's two-phase
// dispatch (§ 4.0.1).
//
// The selector owns *two* doors into the same closed procedure set
// (Q-E.50.1):
//
//   - [ProcedureSelector.select] — the **no-hint** door. The fallback
//     classifier (D.15) emits an inbound *kind*; this maps kind → procedure
//     id (`user_prompt` → `prompt_analyzer_v1`), rejecting an unknown kind
//     with `UnsupportedProcedureKind`.
//   - [ProcedureSelector.resolveHintedProcedure] — the **confident-hint**
//     door. The Phase-E heuristic classifier (E.33) already chose a procedure
//     (memory's centroid `bestMatch`), attached as `Access.envelope.kindHint`;
//     this validates that *procedure id* against the shipped set, rejecting an
//     unknown one with `UnknownProcedureHint`. The kind → procedure map is
//     **not** consulted — a centroid hint names the procedure to run, not a
//     kind, so it survives the moment a second procedure exists.

import 'package:tom_brain_shared/tom_brain_shared.dart' show InboundKinds;

import 'unknown_procedure_hint.dart';
import 'unsupported_procedure_kind.dart';

/// Well-known system-procedure ids the dispatcher works with.
///
/// After the Todo-6 route-flip (§ 4.0.1) the dispatcher routes every
/// `user_prompt` to the **entry router** [promptAnalyzerV1]; the router then
/// chooses between the two answer branches ([answerWithMemoryV1] /
/// [answerWithThinkingV1]) and the dispatcher runs the chosen one as a
/// second, top-level streaming run. These holders name the ids so selection,
/// the dispatcher's two-phase route, and the engine-side script loader share
/// one spelling instead of duplicating magic strings (mirroring
/// [InboundKinds] on the classifier side).
abstract final class SystemProcedures {
  /// The entry router: one `analyser` classification call that picks the
  /// answer branch (§ 4.0). Every `user_prompt` routes here first.
  static const String promptAnalyzerV1 = 'prompt_analyzer_v1';

  /// The normal answer branch: `recall → answer → persist` (spec § 4.4).
  /// Reached only via the router's `normal` verdict.
  static const String answerWithMemoryV1 = 'answer_with_memory_v1';

  /// The thinking answer branch: the recursive deliberation loop
  /// (§ 4.1–4.7). Reached only via the router's `thinking` verdict.
  static const String answerWithThinkingV1 = 'answer_with_thinking_v1';

  /// The passthrough relay: one role-anchored substrate call, no memory
  /// (`session_configuration.md` § 5.2, SC-3). The entry procedure
  /// `mode: passthrough` selects. Named here so the profile entry door
  /// (§ 5.1) and the engine-side loader share one spelling; the script itself
  /// lands in plan step 7.
  static const String passthroughV1 = 'passthrough_v1';
}

/// The closed set of *entry* procedure ids a profile may select via its
/// `mode` / `entryProcedure` (`session_configuration.md` § 3.2, § 5.1).
///
/// One id per [ProfileMode]: `cognitive` → [SystemProcedures.promptAnalyzerV1],
/// `answer` → [SystemProcedures.answerWithMemoryV1], `passthrough` →
/// [SystemProcedures.passthroughV1]. This is the validation registry for
/// [ProcedureSelector.resolveEntryProcedure] — the profile entry door
/// (Plan step 6 / SCP-22) — kept **distinct** from
/// [ProcedureSelector.knownProcedureIds] (the kindHint door's
/// routing-derived set, `[prompt_analyzer_v1]`). The two namespaces were
/// already separated by Q-E.50.1; the entry set lets a profile reach the
/// `answer`/`passthrough` entries without widening the kindHint door's set.
const Set<String> defaultEntryProcedures = <String>{
  SystemProcedures.promptAnalyzerV1,
  SystemProcedures.answerWithMemoryV1,
  SystemProcedures.passthroughV1,
};

/// The default kind → procedure-id routing table for the prototype.
///
/// One entry: `user_prompt` → `prompt_analyzer_v1` (the entry router, after
/// the Todo-6 route-flip § 4.0.1). The answer branches are *not* routing
/// targets — they are reachable only through the router's two-phase dispatch.
/// Any kind absent from this map is unsupported and rejected by
/// [ProcedureSelector.select].
const Map<String, String> defaultProcedureRouting = <String, String>{
  InboundKinds.userPrompt: SystemProcedures.promptAnalyzerV1,
};

/// The dispatcher's procedure selector (Plan D.16; spec § 10.2).
///
/// Stage three of the dispatcher pipeline: turns the inbound-kind string the
/// classifier (D.15) produced into the procedure id the coordinator (D.18)
/// schedules. It owns one decision — map the kind to a procedure, or reject
/// it loudly.
final class ProcedureSelector {
  /// Builds a selector over a kind → procedure-id [routing] table (default
  /// [defaultProcedureRouting]).
  ///
  /// The routing is injectable so the selector can grow new kinds as later
  /// procedures land, and so tests can prove the mapping / rejection
  /// boundary without depending on the prototype's single live entry. The
  /// table is copied defensively so a caller's later mutation cannot
  /// re-route a constructed selector.
  ProcedureSelector({
    Map<String, String> routing = defaultProcedureRouting,
    Set<String> entryProcedures = defaultEntryProcedures,
  })  : _routing = Map<String, String>.unmodifiable(routing),
        _entryProcedures = Set<String>.unmodifiable(entryProcedures);

  final Map<String, String> _routing;

  /// The closed set of entry procedure ids the profile door
  /// ([resolveEntryProcedure]) will admit, defaulting to
  /// [defaultEntryProcedures]. Injectable so the run side can widen it from
  /// the configured profiles' entries ("fed from the resolved profile",
  /// § 5.1) once custom-entry profiles exist. Copied defensively.
  final Set<String> _entryProcedures;

  /// The inbound kinds this selector can route, in insertion order.
  ///
  /// Used by [select] to populate the rejection message and exposed so a
  /// caller (or a trail entry) can report the accepted set.
  List<String> get supportedKinds => List<String>.unmodifiable(_routing.keys);

  /// The procedure ids this selector recognises, in first-seen order and
  /// de-duplicated (several kinds may route to one procedure).
  ///
  /// The accepted set for [resolveHintedProcedure]: a confident centroid hint
  /// (E.33) is routed only if it names one of these. Distinct from
  /// [supportedKinds] — kinds are the classifier's vocabulary, procedure ids
  /// are the engine's (Q-E.50.1).
  List<String> get knownProcedureIds =>
      List<String>.unmodifiable(_routing.values.toSet());

  /// The entry procedure ids the profile door ([resolveEntryProcedure])
  /// admits, in iteration order.
  ///
  /// Distinct from [knownProcedureIds] (the kindHint door's routing-derived
  /// set): a profile selects an *entry* procedure — one of the closed
  /// [defaultEntryProcedures] — whereas a centroid hint names a routing
  /// target. Keeping the sets separate is what lets a profile reach
  /// `answer_with_memory_v1` / `passthrough_v1` without re-routing the
  /// kindHint door (SCP-22).
  List<String> get knownEntryProcedures =>
      List<String>.unmodifiable(_entryProcedures);

  /// Resolves [kind] to the procedure id to run.
  ///
  /// For the prototype `user_prompt` → `prompt_analyzer_v1` (the entry
  /// router, § 4.0.1). Any other kind has no mapping and is rejected with
  /// [UnsupportedProcedureKind] —
  /// loudly, never silently. The thrown error names the offending kind and
  /// the supported set, and (per the D.14 contract) propagates unchanged
  /// through `Dispatcher.accept`.
  ///
  /// This is the **no-hint** door: it is reached only when the inbound
  /// carried no confident centroid hint and the fallback classifier (D.15)
  /// produced a kind. A confident hint routes through
  /// [resolveHintedProcedure] instead, bypassing this kind → procedure map.
  String select(String kind) {
    final procedureId = _routing[kind];
    if (procedureId == null) {
      throw UnsupportedProcedureKind(
        kind: kind,
        supportedKinds: supportedKinds,
      );
    }
    return procedureId;
  }

  /// Resolves a confident kind-hint that already names a *procedure id*
  /// (Q-E.50.1).
  ///
  /// The Phase-E heuristic classifier (E.33) attaches memory's centroid
  /// `bestMatch` — a procedure id, not an inbound kind — as
  /// `Access.envelope.kindHint`. When confident, the dispatcher routes it
  /// directly: this trims [procedureId] and returns it if it names a shipped
  /// procedure ([knownProcedureIds]). The kind → procedure map is **not**
  /// consulted — a procedure-id hint is already the routing target.
  ///
  /// A hint that names no shipped procedure (a centroid/classifier drift) is
  /// rejected with [UnknownProcedureHint] — loudly, never silently — and the
  /// error propagates unchanged through `Dispatcher.accept` (D.14).
  String resolveHintedProcedure(String procedureId) {
    final trimmed = procedureId.trim();
    if (!_routing.values.contains(trimmed)) {
      throw UnknownProcedureHint(
        procedureId: trimmed,
        knownProcedureIds: knownProcedureIds,
      );
    }
    return trimmed;
  }

  /// Resolves a profile-selected *entry* procedure id (the profile door,
  /// Plan step 6 / SCP-21–SCP-22; `session_configuration.md` § 5.1).
  ///
  /// `resolveProcedureId`'s first door reads `Access.profile.entryProcedure`
  /// (a `ResolvedProfile` already validated at boot) and routes it directly
  /// when the profile selects a non-cognitive-baseline entry. This trims
  /// [procedureId] and returns it if it names one of the closed
  /// [knownEntryProcedures] — the same validate-against-a-known-set shape the
  /// `kindHint` door uses (§ 5.1), but over the entry registry rather than the
  /// routing values, so `answer_with_memory_v1` / `passthrough_v1` are
  /// admissible here while the kindHint door's set stays `[prompt_analyzer_v1]`
  /// (SCP-22).
  ///
  /// An entry naming no shipped entry procedure is a should-never-happen
  /// safety net (boot step 3 already rejects a malformed/conflicting entry);
  /// it is surfaced loudly with [UnknownProcedureHint] (reused per SCP-23),
  /// carrying [knownEntryProcedures] as the accepted set.
  String resolveEntryProcedure(String procedureId) {
    final trimmed = procedureId.trim();
    if (!_entryProcedures.contains(trimmed)) {
      throw UnknownProcedureHint(
        procedureId: trimmed,
        knownProcedureIds: knownEntryProcedures,
      );
    }
    return trimmed;
  }
}
