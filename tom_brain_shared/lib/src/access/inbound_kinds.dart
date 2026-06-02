// InboundKinds — the cross-phase inbound-kind vocabulary (Plan step D.52
// reuse-extraction pass; def § 1.5; proto spec § 10.2).
//
// ── Why this lives in shared (the D.52 extraction) ──────────────────────
//
// `InboundRequest.kindHint` already lives here (D.11): the Phase-E
// heuristic classifier (E.33) *fills* that field, and the Phase-D
// dispatcher classifier (D.15) *reads* it. The two phases must agree on
// the spelling of the well-known kind strings, yet the holder for those
// strings (`InboundKinds`) was authored inside
// `tom_brain_procedure_prototype` at D.15. That left Phase E with no way
// to write a confident `kindHint` without either hard-coding the magic
// string or taking a dependency on the dispatcher package purely to reach
// one constant.
//
// At the Phase-D review (D.51) `InboundKinds` was surfaced as a reuse
// candidate; the D.52 pass promotes it here, beside the `kindHint` field
// it names. Now the *producer* (Phase E) and the *consumer* (Phase D)
// share one spelling through the shared vocabulary, exactly as
// `EffortMetrics` (C.48) and `PreemptionState` (C.48) were promoted when
// two components landed on one contract.
//
// ── What stays in the dispatcher ────────────────────────────────────────
//
// `SystemProcedures` (the procedure-id holder) is *not* extracted: Phase E
// never selects a procedure — that decision is the dispatcher's alone
// (D.16). Its sole reader is `defaultProcedureRouting`, a dispatcher
// internal. Promoting it would be speculative (no second consumer), the
// failure mode the clean-code rules call out. It stays in
// `procedure_selector.dart`.
//
// ── Open vocabulary, not a sealed enum ──────────────────────────────────
//
// Kinds are open strings deliberately (D.15): the real classifier will
// emit kinds this prototype never anticipates, and a sealed enum here
// would force exactly the backwards-incompatible growth the quest forbids.
// This holder names only the one kind the prototype routes; selection
// (D.16) narrows the open kind space to the closed set of shipped
// procedures and rejects everything else loudly.

/// The well-known inbound kinds shared by the Phase-E classifier (which
/// fills [InboundRequest.kindHint]) and the Phase-D dispatcher (which reads
/// it).
///
/// The classifier emits open kind strings; only [userPrompt] carries
/// meaning in the prototype — it is the one kind D.16 selection routes
/// (`user_prompt` → `answer_with_memory_v1`). This holder exists so the
/// edge producer and the dispatcher consumer share one spelling of the
/// token instead of each repeating a magic string.
abstract final class InboundKinds {
  /// A plain user prompt — the only kind the prototype routes
  /// (`user_prompt` → `answer_with_memory_v1`, D.16).
  static const String userPrompt = 'user_prompt';
}
