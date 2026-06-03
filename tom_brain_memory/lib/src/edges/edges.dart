// Barrel for the `edges/` module (A.23 layout; A.24 / A.36 surface).
//
// Current exports:
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
//   - `EdgeWriter` — in-process owner of the `edge(...)` write path
//     (A.36). Enforces endpoint existence, type registration, and
//     the `allowedOutgoing` / `allowedIncoming` permission table.
//   - `EdgeReader` — in-process owner of the `edgesOf(...)` read
//     path (A.37). Supports direction + type filters with a
//     deterministic `created_at_ms ASC, id ASC` ordering.
//   - `EdgeCreated`, `EdgeRejected` — `MemoryEvent` leaves emitted
//     by `EdgeWriter` (A.36).
//   - `EdgeWriteException` family — typed refusals from the writer
//     (`EdgeEndpointMissing`, `EdgeNotPermitted`,
//     `UnknownNodeTypeForEdge`).
//
// Wiring across later Phase A steps:
//
//   - A.61 — graph-walk recall mode (`memory_specification.md` § 10).

// `Edge` and `EdgeType`/`EdgeDirection` moved to `tom_brain_shared` at
// A.88 (todo #16); re-exported here so the barrel keeps its surface.
export 'package:tom_brain_shared/tom_brain_shared.dart'
    show Edge, EdgeDirection, EdgeType;
export 'edge_events.dart' show EdgeCreated, EdgeRejected;
export 'edge_reader.dart' show EdgeReader;
export 'edge_write_exception.dart'
    show
        EdgeEndpointMissing,
        EdgeEndpointSide,
        EdgeNotPermitted,
        EdgeRejectionReason,
        EdgeWriteException,
        UnknownNodeTypeForEdge;
export 'edge_writer.dart' show EdgeWriter;
