/// @procedure
/// id: answer_with_memory_v1
/// version: 1
/// summary: No-op answer-with-memory stub — the callable target the Phase D
///   dispatcher routes every `user_prompt` to (D.16), standing in until the
///   real recall→answer→persist loop lands at D.10 (D.36–D.42).
/// successCriterion: returns a succeeded result without touching memory,
///   the substrate, or any other effect surface (stub stage only — D.10
///   replaces this with the recall + persist post-conditions).
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12, memoryWrites: 6 }
/// inputs:
///   - { name: text, type: String, required: false }
/// outputs:
///   - { name: stub, type: String }
/// requires: []
//
// answer_with_memory_v1 — the prototype's no-op stub procedure
// (`prototype_implementation_plan.md` D.8; full body at D.10 / D.36–D.42;
// `tom_brain_procedure_prototype_specification.md` § 1.4, § 5).
//
// D.8 (plan): "Add `scripts/system/answer_with_memory_v1.dart` as a stub."
// This is the second shipped system procedure alongside `think_v1.dart`. The
// dispatcher's procedure-selection step (D.16) routes every inbound
// classified as `user_prompt` to `answer_with_memory_v1`; shipping the stub
// now gives that route a real, resolvable, runnable target before the
// dispatcher half is wired, so D.14–D.16 can be written and tested against a
// procedure that exists rather than a `ProcedureNotFound`.
//
// The stub mirrors `think_v1` exactly (the proven shipped-stub convention):
//   - a valid `@procedure` header so the loader/resolver index it,
//   - `requires: []` because the no-op body calls no bridged primitive (the
//     real `recall`/`llm`/`persist`/`edge` list lands with the body at D.10),
//   - the loose `Object? run(Object? inputs)` entry the d4rt host executes
//     and coerces into a succeeded `ProcedureResult` (`ProcedureResult` is
//     not yet bridged into d4rt — Q-C.38.2), returning a fixed `stub` marker
//     so a caller can verify *this* stub (not some other procedure) ran.
//
// What D.10 changes (recorded so the contract is explicit):
//   - the body becomes the real recall→answer→persist loop (D.37–D.41),
//   - `text` flips to `required: true` (step 1 reads `access.envelope.text`),
//   - the `stub` output becomes `answer`,
//   - `requires` declares `[recall, llm, persist, edge]` (plus stack pushes).
Object? run(Object? inputs) => <String, Object?>{'stub': 'answer_with_memory_v1'};
