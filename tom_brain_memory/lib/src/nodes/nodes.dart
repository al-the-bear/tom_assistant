// Barrel for the `nodes/` module (Plan step A.23).
//
// Owns the open node-type system described in `memory_specification.md`
// § 4.1:
//
//   - `NodeTypeDecl` — the schema-and-policy declaration registered via
//     `propose_node_type_v1`.
//   - `NodeDraft` / `Node` — write-side and read-side records.
//   - The 21 bootstrap node types (Event, Claim, Concept, Conclusion,
//     Question, Pattern, Contradiction, Source, Stack, StackEntry,
//     Trail, Procedure, Run, Role, Persona, Substrate, Centroid,
//     MigrationCursor, Tombstone, NodeTypeDecl, EdgeMeta).
//   - Per-type indexPolicy / retentionPolicy / classificationPolicy.
//
// Hard invariant (§ 1.3): **node types are open**, but new types only
// arrive via the `propose_node_type_v1` procedure path, never as a code
// edit alone. The 12-edge alphabet (`edges/`) is closed.
//
// Wiring across later Phase A steps:
//
//   - A.40+ — NodeTypeDecl, NodeDraft, Node record shapes.
//   - A.42+ — the 21 bootstrap registrations.
//   - A.44+ — registry CRUD + persistence in `memory.db`.
//
// At A.23 this folder is intentionally empty. No exports yet.
