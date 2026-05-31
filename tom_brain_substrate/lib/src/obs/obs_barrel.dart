// Barrel for the `obs/` module (Plan step B.37).
//
// Owns the package-level logging surface — a thin, category-tagged
// wrapper over the global `tomLog` instance from `tom_basics`. See
// `substrate_log.dart` for the design rationale and the six categories
// spec § 10.1 names.
//
// B.37 — `substrate_log.dart`: `SubstrateLogCategory` (the closed enum
// of six categories — `tom_brain.substrate.llm`, `…roles`, `…embed`,
// `…web`, `…mcp`, `…router`) and `SubstrateLog` (the const-instance
// facade with the six `SubstrateLog.<area>` statics). Call sites use
// `SubstrateLog.llm.status('…')`, `SubstrateLog.router.warn('…')`,
// etc.; the wrapper prepends `'[tom_brain.substrate.<area>] '` and
// forwards to `tomLog`.
//
// Spec-vs-plan note: plan step B.37 lists five categories
// (`llm` / `roles` / `embed` / `web` / `mcp`); spec § 10.1 lists six
// (the same five plus `router`). The wrapper includes all six — the
// spec is authoritative and the router subsystem (B.18+) is a
// first-class category. See Q-B.37.1 in
// `prototype_implementation_questions.md`.
//
// Future steps may add categories. New categories are added by editing
// the enum + the matching static in `substrate_log.dart`; ad-hoc
// string categories are not supported on purpose.
//
// Pending B.37 follow-ups:
//
//   - B.38 will land `SubstrateEvent` stream and the rest of the
//     observability triple (logger + event stream + stats). Logger
//     lands first because every other subsystem already imports it
//     transitively for boot-time status lines.
//   - B.39 will pair behavioural tests (config roundtrip + event
//     ordering + logger categorisation) around the trio.

export 'substrate_log.dart' show SubstrateLog, SubstrateLogCategory;
