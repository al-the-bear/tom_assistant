// Barrel for the `nodes/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `Node` / `NodeDraft` / `NodeStatus` — read- and write-side
//     records used by `TomBrainMemory.persist`, `get`, `getMany`,
//     `stream`.
//   - `NodeTypeDecl` + supporting structs — schema-and-policy
//     declaration registered via `registerNodeType`.
//   - `FieldSpec`, `FieldType`, `IndexPolicy`, `EmbeddingPolicy`,
//     `RetentionPolicy` — the per-type policy primitives.
//
// The 21 bootstrap node-type *instances* land at A.32 (per the plan).
// The A.24 surface only declares the *shape* of a `NodeTypeDecl`.
//
// Wiring across later Phase A steps:
//
//   - A.32 — YAML manifest loader + 21 bootstrap registrations
//     (`NodeTypeYamlLoader`, `bootstrap_node_types.yaml`).
//   - A.33 — `registerNodeType` with critique-driven overlap check.
//   - A.34 — `persist(NodeDraft, Scope)` write path.
//   - A.35 — `get` / `getMany` / `demote` / `forget`.

export 'critique_hook.dart'
    show CritiqueApproved, CritiqueHook, CritiqueOutcome, CritiqueRejected;
export 'node.dart' show Node, NodeDraft, NodeStatus;
export 'node_type_decl.dart'
    show
        EmbeddingPolicy,
        FieldSpec,
        FieldType,
        IndexPolicy,
        NodeTypeDecl,
        RetentionPolicy;
export 'node_type_events.dart' show NodeTypeRegistered;
export 'node_type_registration.dart'
    show
        InvalidNodeTypeDecl,
        NodeTypeAlreadyExists,
        NodeTypeNotFound,
        NodeTypeRegistrationException,
        NodeTypeRejected,
        NodeTypeVersionNotMonotonic;
export 'node_type_registry.dart' show NodeTypeRegistry;
export 'node_type_yaml_loader.dart'
    show
        NodeTypeManifestException,
        NodeTypeYamlLoader,
        kBootstrapManifestPackageUri,
        kSupportedManifestVersion;
