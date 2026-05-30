// Barrel for the `retrieval/` module (Plan step A.23).
//
// Owns the four-mode retrieval pipeline described in
// `memory_specification.md` § 6:
//
//   - BM25 over FTS5.
//   - Vector recall via sqlite-vec.
//   - Graph walk over the closed 12-edge alphabet (§ 4.2).
//   - Symbolic / structured recall (NodeType + attribute predicates).
//
// Plus the fusion layer (§ 6.2 — RRF + MMR) and the optional LLM re-rank
// hook (§ 6.3). Retrieval is the hot path; nothing here is allowed to
// call an LLM on the synchronous path except via the explicit re-rank
// opt-in.
//
// Wiring across later Phase A steps:
//
//   - A.55+ — RecallQuery / RecallResult types, single-mode executors.
//   - A.57+ — fusion (RRF, MMR), cost accounting (§ 6.4).
//   - A.58+ — optional LLM re-rank wiring (substrate-owned).
//
// At A.23 this folder is intentionally empty. No exports yet.
