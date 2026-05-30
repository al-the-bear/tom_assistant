// Barrel for the `edges/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `EdgeType` — the closed 12-edge alphabet from
//     `memory_specification.md` § 4.2 (mentions, derived_from,
//     superseded_by, satisfied_by, motivates, evidence_for,
//     contradicts, part_of, produced_by, authored_by, targets,
//     caused_by). The earlier draft list in the original A.23 barrel
//     header (relatesTo / supports / instanceOf / mentionedIn /
//     observedIn / anchoredTo) was superseded by the final spec; see
//     Q-A.24.1.
//   - `EdgeDirection` — direction filter for
//     `TomBrainMemory.edgesOf`.
//   - `Edge` — read-side record returned by `edgesOf` and graph-walk
//     recall.
//
// Wiring across later Phase A steps:
//
//   - A.36 — `edge(...)` write path enforces `allowedOutgoing` /
//             `allowedIncoming` against the NodeType registry.
//   - A.37 — `edgesOf(...)` query path with direction + type filters.
//   - A.61 — graph-walk recall mode (`memory_specification.md` § 10).

export 'edge.dart' show Edge;
export 'edge_type.dart' show EdgeDirection, EdgeType;
