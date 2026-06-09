/// @procedure
/// id: think_v1
/// version: 1
/// summary: No-op think stub — a callable target for the sugar `think(…)`
///   alias and the depth/fallback machinery until the real thinking loop
///   lands with the system library (Phase D).
/// successCriterion: returns a succeeded result without touching memory,
///   the substrate, or any other effect surface.
/// budget: { wallClockMs: 1000 }
/// inputs:
///   - { name: prompt, type: String, required: false }
/// outputs:
///   - { name: stub, type: String }
/// requires: []
//
// think_v1 — the prototype's no-op stub procedure
// (`tom_brain_procedure_specification.md` § 1.4, § 5.2; Q-C.2.1).
//
// This is a machinery fixture, not a behavioural example. Its `requires: []`
// cannot be exercised because it calls no primitive; for an end-to-end
// procedure that meaningfully drives the bridges, see `answer_with_memory_v1`.
//
// § 5.2: `think(…)` is sugar over `runProcedure('think_v1', …)`. The
// prototype ships only this stub so the sugar verb has a real target and
// the depth-cap / fallback machinery can exercise a callable procedure
// without dragging the (Phase D) thinking-loop scope into Phase C. Per
// Q-C.2.1 the stub is a pure no-op: it calls no primitive, reads no input,
// and returns a fixed result. ProcedureResult is not yet bridged into d4rt
// (Q-C.38.2), so the entry point returns a plain map the engine coerces
// into a succeeded ProcedureResult; the `stub` marker lets a caller verify
// the stub (rather than some other procedure) ran.
Object? run(Object? inputs) => <String, Object?>{'stub': 'think_v1'};
