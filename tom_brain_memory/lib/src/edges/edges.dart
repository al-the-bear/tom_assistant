// Barrel for the `edges/` module (Plan step A.23).
//
// Owns the closed 12-edge alphabet described in `memory_specification.md`
// § 4.2. The alphabet is permanent (hard invariant § 1.3 — "open node
// types, closed edges"):
//
//   1. relatesTo            7. derivedFrom
//   2. supports             8. supersededBy
//   3. contradicts          9. satisfiedBy
//   4. partOf              10. observedIn
//   5. instanceOf          11. authoredBy
//   6. mentionedIn         12. anchoredTo
//
// Wiring across later Phase A steps:
//
//   - A.45+ — EdgeType enum, Edge record, EdgeDirection.
//   - A.47+ — edge writes and `edgesOf` queries against `memory.db`.
//   - A.48+ — `EdgeMeta` node for per-edge classification/weight metadata
//             (the meta records that ride alongside the edge itself).
//
// At A.23 this folder is intentionally empty. No exports yet.
