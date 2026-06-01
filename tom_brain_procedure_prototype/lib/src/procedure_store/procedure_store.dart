// Barrel for the `procedure_store/` module (Plan step C.8).
//
// Owns procedure storage, loading, and version resolution
// (`tom_brain_procedure_prototype_specification.md` § 6, Plan steps
// C.23–C.26):
//
//   - `ProcedureStore` — two backends behind one interface:
//     (a) **disk** for `scripts/system/` (well-known) + `scripts/user/`,
//     (b) **memory** for brain-authored procedures stored as
//     `Procedure` nodes via the memory client.
//   - Procedure loader — parses the structured header (procedure id,
//     version, summary, success criterion, budget caps).
//   - Procedure resolver — fallback chain `[v_latest, …, v1]`. For the
//     prototype only `v1` exists; the chain machinery is still present.
//
// Wiring across later Phase C steps:
//
//   - C.23 — `ProcedureStore` disk + memory backends.
//   - C.24 — header-parsing loader.
//   - C.25 — version resolver with fallback chain.
//   - C.26 — backend-equivalence + malformed-header + resolver tests.
//
// At C.8 this folder is intentionally empty. No exports yet.
