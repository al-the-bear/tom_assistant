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
