// Barrel for the `isolate_adapter/` module (Plan step A.23).
//
// Owns the procedure-engine bridge described in
// `memory_specification.md` § 3.3 — the isolate-safe adapter that lets
// the procedure engine (running in a separate isolate per Phase B+)
// call the in-process `TomBrainMemory` surface without sharing state
// across isolate boundaries.
//
// Scope:
//
//   - Request/response message envelopes (sendable across SendPort).
//   - Argument and result serialisation for each `TomBrainMemory`
//     method (the same surface defined under `api/`).
//   - Back-pressure and budget enforcement on the adapter side: the
//     procedure engine cannot bypass per-procedure write budgets by
//     spamming the adapter.
//   - Lifecycle: adapter spin-up/tear-down tied to procedure-engine
//     isolate lifecycle.
//
// Hard invariants honoured here:
//
//   - § 1.5 — embeddings are owned by substrate, so the adapter never
//     carries embedding-generation requests; it carries vectors that
//     substrate already produced.
//   - § 5 — stack mutations through the adapter are still transactional
//     against `memory.db`; the adapter does not buffer them.
//
// Wiring across later Phase A steps:
//
//   - A.83 — adapter message envelopes + dispatch table.
//   - A.84 — SendPort wiring + isolate lifecycle.
//   - A.85 — multi-machine variant (RPC over the canonical-authority
//             transport described in § 10).
//
// At A.23 this folder is intentionally empty. No exports yet.
