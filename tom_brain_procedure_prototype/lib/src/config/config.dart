// Barrel for the `config/` module (Plan step C.8).
//
// Owns engine configuration and observability
// (`tom_brain_procedure_prototype_specification.md` § 11, Plan steps
// C.42–C.45):
//
//   - `EngineConfig` — YAML loader for the `scripts/system/` path,
//     `scripts/user/` path, sandbox switches, and deadline defaults.
//   - `TomLogger` categories: `tom_brain.engine.host`, `…bridge`,
//     `…store`, `…recorder`, `…preemption`.
//   - `EngineEvent` stream: `InvocationStarted`, `PrimitiveCalled`,
//     `StepYielded`, `InvocationCompleted`, `InvocationFailed`.
//
// Wiring across later Phase C steps:
//
//   - C.17 ✅ — `SandboxConfig` (`sandbox_config.dart`): the two host
//     sandbox switches (`enableUnixCommands`, `enableVsCodeIntegration`),
//     both disabled by default. The full `EngineConfig` (C.42) carries
//     a `SandboxConfig` as its "sandbox switches" field.
//   - C.42 ✅ — `EngineConfig` YAML loader (`engine_config.dart`): the
//     `scripts/system/` + `scripts/user/` paths, the `SandboxConfig`
//     switches, and the hard per-step deadline, loaded from a small YAML
//     document via the `yaml` package. Malformed documents are funnelled
//     through `EngineConfigInvalid` (`engine_config_invalid.dart`).
//   - C.43 ✅ — `TomLogger` category wiring (`engine_log.dart`): the
//     closed `EngineLogCategory` enum of the five engine categories
//     (`tom_brain.engine.host`, `…bridge`, `…store`, `…recorder`,
//     `…preemption`) and the `EngineLog` const-instance facade with the
//     five `EngineLog.<area>` statics. Call sites use
//     `EngineLog.host.status('…')`; the wrapper prepends
//     `'[tom_brain.engine.<area>] '` and forwards to `tomLog`. Mirrors
//     `MemoryLog` (A.84) and `SubstrateLog` (B.37).
//   - C.44 — `EngineEvent` stream.
//   - C.45 — config-roundtrip / event-ordering / logger tests.

export 'engine_config.dart';
export 'engine_config_invalid.dart';
export 'engine_log.dart';
export 'sandbox_config.dart';
