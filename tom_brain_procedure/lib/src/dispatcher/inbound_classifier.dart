// Inbound classifier (Plan step D.15;
// `tom_brain_procedure_specification.md` § 10.2).
//
// The second stage of the dispatcher's `accept → classify → select →
// schedule` pipeline. Given an admitted [Access] that carried *no confident
// centroid hint*, it produces the *inbound kind* string that procedure
// selection (D.16) maps to a procedure id.
//
// Policy (spec § 10.2, Plan D.15; Q-E.50.1):
//
//   The confident-hint branch is **not** this classifier's concern. The
//   Phase-E heuristic classifier (E.33) pre-fills `access.envelope.kindHint`
//   with a *procedure id* (memory's centroid `bestMatch`); the route
//   (`resolveProcedureId`) routes that hint directly to the procedure,
//   bypassing the kind → procedure map. This classifier is reached only on
//   the **no-hint** path, where it runs `classify_inbound_v1` — a stub for
//   the prototype. The real heuristic/script version arrives later (Plan
//   D.15: "the real version arrives later"); for the prototype every
//   un-hinted inbound is a plain `user_prompt`.
//
// Kinds are open strings, not a closed enum, deliberately. The real
// classifier will emit kinds this prototype never anticipates; a sealed
// enum here would force exactly the backwards-incompatible growth the
// quest's "no backwards compatibility" rule is meant to avoid. Selection
// (D.16) special-cases the one kind it understands (`user_prompt`) and
// rejects everything else with `UnsupportedProcedureKind`, so an unknown
// kind fails loudly at selection rather than silently here.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Access, InboundKinds;

/// The fallback classifier invoked when an [Access] carries no kind-hint.
///
/// Returns the inbound kind for an un-hinted request. The default is
/// [classifyInboundV1]; a later step (or a test) can inject a different
/// fallback without changing the [InboundClassifier] contract.
typedef ClassifyFallback = String Function(Access access);

/// The prototype's `classify_inbound_v1` stub fallback.
///
/// The real classifier — heuristic or a procedure script — arrives later
/// (Plan D.15). For the prototype every request that reaches the fallback
/// (i.e. arrived with no edge-supplied hint) is treated as a plain user
/// prompt, so it routes to `answer_with_memory_v1` (D.16).
///
/// Pure and stateless: the result depends only on the (currently ignored)
/// argument, so it is trivially testable and safe to call repeatedly.
String classifyInboundV1(Access access) => InboundKinds.userPrompt;

/// The dispatcher's no-hint inbound classifier (Plan D.15; spec § 10.2).
///
/// Stage two of the dispatcher pipeline, on the **no-hint** branch only: turns
/// an admitted [Access] that carried no confident centroid hint into an
/// inbound-kind string for selection (D.16). The confident-hint branch routes
/// directly via `resolveProcedureId` (Q-E.50.1) and never reaches here.
final class InboundClassifier {
  /// Builds a classifier over a [fallback] (default [classifyInboundV1]).
  ///
  /// The fallback is injectable so the prototype stub can be replaced by
  /// the real classifier later, and so tests can observe whether the no-hint
  /// path ran (E.50) without depending on the stub's verdict.
  InboundClassifier({ClassifyFallback fallback = classifyInboundV1})
      : _fallback = fallback;

  final ClassifyFallback _fallback;

  /// Classifies [access] into an inbound kind via the [fallback].
  ///
  /// Reached only on the no-hint path: the route (`resolveProcedureId`) has
  /// already established that `access.envelope.kindHint` was absent or blank,
  /// so this classifier never inspects the hint — the [fallback]
  /// (`classify_inbound_v1` by default) decides. The classifier never reads
  /// the prompt *body* (`envelope.text`) either: the prototype's stub ignores
  /// it, and the body is the answer step's concern (D.37), not the
  /// classifier's.
  String classify(Access access) => _fallback(access);
}
