// Procedure selection (Plan step D.16;
// `tom_brain_procedure_specification.md` § 10.2).
//
// The third stage of the dispatcher's `accept → classify → select →
// schedule` pipeline. Given the inbound *kind* the classifier (D.15)
// produced, it resolves the *procedure id* the run coordinator (D.18) will
// schedule.
//
// Policy (spec § 10.2, Plan D.16): for the prototype, every inbound
// classified as `user_prompt` routes to `answer_with_memory_v1`; anything
// else surfaces `UnsupportedProcedureKind`. This is the single point where
// the open kind strings the classifier emits are narrowed to the closed set
// of procedures the prototype actually ships — the boundary at which an
// unanticipated kind fails loudly (Q-D.15.1) instead of being silently
// dropped or guessed.
//
// The selector owns *two* doors into the same closed procedure set
// (Q-E.50.1):
//
//   - [ProcedureSelector.select] — the **no-hint** door. The fallback
//     classifier (D.15) emits an inbound *kind*; this maps kind → procedure
//     id (`user_prompt` → `answer_with_memory_v1`), rejecting an unknown kind
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

/// Well-known system-procedure ids the dispatcher selects.
///
/// The prototype ships exactly one *real* routed procedure,
/// [answerWithMemoryV1]; this holder names its id so selection and the
/// engine-side script loader share one spelling instead of duplicating a
/// magic string (mirroring [InboundKinds] on the classifier side).
abstract final class SystemProcedures {
  /// The one real system procedure: `recall → answer → persist`
  /// (spec § 11). Every `user_prompt` routes here.
  static const String answerWithMemoryV1 = 'answer_with_memory_v1';
}

/// The default kind → procedure-id routing table for the prototype.
///
/// One entry: `user_prompt` → `answer_with_memory_v1`. Any kind absent from
/// this map is unsupported and rejected by [ProcedureSelector.select].
const Map<String, String> defaultProcedureRouting = <String, String>{
  InboundKinds.userPrompt: SystemProcedures.answerWithMemoryV1,
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
  ProcedureSelector({Map<String, String> routing = defaultProcedureRouting})
      : _routing = Map<String, String>.unmodifiable(routing);

  final Map<String, String> _routing;

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

  /// Resolves [kind] to the procedure id to run.
  ///
  /// For the prototype `user_prompt` → `answer_with_memory_v1`. Any other
  /// kind has no mapping and is rejected with [UnsupportedProcedureKind] —
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
}
