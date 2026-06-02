// Inbound classifier (Plan step D.15;
// `tom_brain_procedure_prototype_specification.md` § 10.2).
//
// The second stage of the dispatcher's `accept → classify → select →
// schedule` pipeline. Given an admitted [Access], it produces the *inbound
// kind* string that procedure selection (D.16) maps to a procedure id.
//
// Policy (spec § 10.2, Plan D.15):
//
//   1. **Kind-hint pass-through.** The Phase-E heuristic classifier (E.33)
//      pre-fills `access.envelope.kindHint` when it is confident. The
//      dispatcher *accepts* that hint verbatim — it does not re-classify a
//      request the edge already classified.
//   2. **Fallback.** When no hint is present (null or whitespace-only), the
//      dispatcher runs `classify_inbound_v1` — a stub for the prototype.
//      The real heuristic/script version arrives later (Plan D.15: "the
//      real version arrives later"); for the prototype every un-hinted
//      inbound is a plain `user_prompt`.
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

/// The dispatcher's inbound classifier (Plan D.15; spec § 10.2).
///
/// Stage two of the dispatcher pipeline: turns an admitted [Access] into an
/// inbound-kind string for selection (D.16). It owns one decision —
/// accept the edge's kind-hint, or fall back to `classify_inbound_v1`.
final class InboundClassifier {
  /// Builds a classifier over a [fallback] (default [classifyInboundV1]).
  ///
  /// The fallback is injectable so the prototype stub can be replaced by
  /// the real classifier later, and so tests can prove the pass-through /
  /// fallback boundary without depending on the stub's verdict.
  InboundClassifier({ClassifyFallback fallback = classifyInboundV1})
      : _fallback = fallback;

  final ClassifyFallback _fallback;

  /// Classifies [access] into an inbound kind.
  ///
  /// Kind-hint pass-through: a non-blank `access.envelope.kindHint`
  /// (pre-filled by the Phase-E heuristic classifier) is accepted and
  /// returned, trimmed of surrounding whitespace — the dispatcher does not
  /// second-guess a hint the edge was confident enough to attach.
  ///
  /// Fallback: an absent (`null`) or whitespace-only hint means "no hint";
  /// the [fallback] (`classify_inbound_v1` by default) then decides.
  ///
  /// The classifier never reads the prompt *body* (`envelope.text`): the
  /// prototype's stub fallback ignores it, and the kind-hint path consults
  /// only the hint. The body is the answer step's concern (D.37), not the
  /// classifier's.
  String classify(Access access) {
    final hint = access.envelope.kindHint;
    if (hint != null && hint.trim().isNotEmpty) {
      return hint.trim();
    }
    return _fallback(access);
  }
}
