# Changelog

## 0.0.1 — 2026-06-01 (Phase C.6)

Initial project scaffold:

- `pubspec.yaml` — minimal skeleton, no runtime dependencies yet (deferred
  to C.7 per the plan).
- Empty barrel `lib/tom_brain_procedure_prototype.dart`.
- `lib/src/` placeholder (`.gitkeep`) for the module layout that lands in C.8.
- Smoke test verifying the package loads (`test/package_loads_test.dart`).
- Local copilot guidelines at `_copilot_guidelines/index.md`.
- `analysis_options.yaml` with `package:lints/recommended.yaml`.
- C.12 — `MemoryBridge` source class (`lib/src/bridges/memory_bridge.dart`):
  the eleven memory primitives (`recall`, `persist`, `edge`,
  `propose_node_type`, `stack.*`) re-exposed over the `TomBrainMemoryClient`
  interface boundary (PE-10) with primitive-typed signatures (Q-C.12.1).
  Plain class, no annotation — selected by the C.11 `build.yaml`. 21 native
  conversion unit tests (`test/memory_bridge_test.dart`).
- C.13 — `SubstrateBridge` source class
  (`lib/src/bridges/substrate_bridge.dart`): the four substrate primitives
  (`llm`, `embed`, `search`, `fetch`) re-exposed over the
  `TomBrainSubstrateClient` interface boundary (PE-10) with primitive-typed
  signatures. `llm` drains `completeStream` to recover the answer text the
  `LlmCallReport` does not carry (Q-C.13.1); a failed stream surfaces as a
  thrown `LlmCompletionFailure`. Anchor invariant (PE-7) preserved
  structurally — the bridge supplies a `role` + `inputs`, never a raw wire
  prompt. Plain class, selected by the C.11 `build.yaml`. 13 native
  conversion unit tests (`test/substrate_bridge_test.dart`).
- C.14 — Ran `dart run build_runner build`: the generated bridges
  (`brain_bridges.b.dart` → `AllBridge`,
  `package_tom_brain_procedure_prototype_bridges.b.dart`,
  `d4rt_bridges.b.dart` barrel, `bridges_trigger.b.dart`) compile and
  register with the d4rt interpreter. `generateDartscript` turned OFF and
  registration moved to the hand-authored `BrainBridges.register`
  (`lib/src/bridges/brain_bridges_registrar.dart`) because the 1.8.24
  generator's dartscript template does not compile (Q-C.14.1); `libraryPath`
  pinned to `lib/src/bridges` to keep generated output inside the existing
  folder. 11 generated-bridge contract tests
  (`test/generated_bridges_test.dart`); the C.11 `build_yaml_config_test`
  revised to lock the new (dartscript-off) contract.
- C.15 — Generator-output round-trip smoke
  (`test/bridge_roundtrip_test.dart`): a d4rt script imports the bridge
  libraries, receives a natively-constructed `MemoryBridge` /
  `SubstrateBridge` as a `main` positional arg, calls a method on it, and
  reads the flattened primitive result — exercising the generated bridge's
  primitive⇄domain conversion end-to-end through the interpreter against
  recording `TomBrainMemoryClient` / `TomBrainSubstrateClient` doubles. 4
  tests (recall read-path, llm read-path, both-bridges-in-one-script,
  persist write-path). Native bridge instances are injected as `main`
  positional args (Q-C.15.1).
