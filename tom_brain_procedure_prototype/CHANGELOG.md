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
- C.16 — `D4rtDcliHost` (`lib/src/d4rt_host/d4rt_dcli_host.dart`): composes
  one `D4rt` interpreter with the two brain bridges (`BrainBridges.register`),
  a `D4rtCliApi` (`D4rtCliController`) over the same interpreter, and an
  `installNativePrimitives` seam for the C.19 engine-native primitives.
  Bridges reach procedure scripts as the named globals `mem` / `sub`
  (`registerGlobalVariable` keyed to the bridge library URIs) — the
  injection convention Q-C.15.1 left open, resolved to named globals because
  it is the only form compatible with the spec entry point
  `run(ProcedureInputs)` (Q-C.16.1). Stack surface stays flat (Q-C.16.2).
  `host.run(source, {entryPoint = 'run', inputs})` executes a script and
  awaits the entry point. Unix/VS Code reach stays disabled (only
  `BrainBridges` is registered) — the locked prototype default; the opt-in
  is C.17. 10 host tests (`test/d4rt_dcli_host_test.dart`): boot +
  same-interpreter composition, bridge resolve+dispatch with a bare-interp
  negative control, named-global injection round-trips (mem / sub / both /
  default+custom entry point), and the native-primitive seam.
- C.17 — Sandbox switches: `SandboxConfig`
  (`lib/src/config/sandbox_config.dart`) carries two independent flags
  (`enableUnixCommands`, `enableVsCodeIntegration`), both off by default;
  `SandboxConfig.locked()` is the prototype's posture. `D4rtDcliHost` gains a
  `sandbox` parameter plus two pluggable surface installers
  (`installUnixCommands` / `installVsCodeIntegration`); each switch, when on,
  runs its installer against the host interpreter at boot, and an enabled
  switch with no installer throws a `StateError` at construction. The
  prototype's `answer_with_memory_v1` runs locked (neither surface
  registered). The choice of which `tom_d4rt_dcli` bridges constitute each
  surface is left to the engine config (C.42), so the host never pulls the
  dcli process/network/FS surface into the prototype binary (Q-C.17.1). 14
  tests (`test/sandbox_config_test.dart`): config value semantics + host
  opt-in behaviour (locked default, per-switch install, missing-installer
  refusal, switch independence, surface-reachable-from-script).
- C.18 — `D4rtDcliHost` acceptance suite
  (`test/host_acceptance_test.dart`): the three plan-named criteria as one
  group each, driven only through the public `host.run(String)` seam under
  the locked sandbox default (the `answer_with_memory_v1` posture) — host
  boots (live interpreter + CLI over the same interpreter, trivial script
  runs), bridges resolve (memory + substrate from string-source scripts;
  bare interpreter does not — negative control), and a bridged method call
  returns the expected result (memory recall, substrate llm, and both in
  one procedure). 8 tests. No production code changed; test-only step.
- C.19 — First engine-native primitive: the depth-capped `runProcedure`.
  `RunProcedurePrimitive` (`lib/src/primitives_native/run_procedure_primitive.dart`)
  tracks the current frame depth and refuses any `runProcedure(id, inputs,
  {version, depthDelta})` whose target depth exceeds the hard cap of 10
  (PE-3; definition § 7.3) with `RecursionLimitExceeded`
  (`recursion_limit_exceeded.dart`) — the executor is never invoked on a
  breach. No `request_depth_extension` in v1. Resolution + execution of the
  target are kept behind an injectable `ProcedureExecutor` seam
  (`ProcedureCall` value) the store/engine fill at C.23–C.26 / C.38.
  `nativePrimitivesInstaller` (`native_primitives_installer.dart`) wires
  `runProcedure` as a top-level d4rt function through the host's
  `installNativePrimitives` seam (C.16); `ProcedureInputs` / `ProcedureResult`
  cross the d4rt boundary as opaque host objects (no bridging needed —
  Q-C.19.2). The typed I/O contract `ProcedureInputs` / `ProcedureResult` /
  `ProcedureStatus` is introduced in `lib/src/api/` because the primitive
  needs it (the rest of the `api/` surface lands at C.38–C.41). 19 unit
  tests (`test/run_procedure_primitive_test.dart`) + 4 d4rt-wiring tests
  (`test/native_primitives_installer_test.dart`).
- C.20 — Second engine-native primitive: `note(category, payload)`.
  `NotePrimitive` (`lib/src/primitives_native/note_primitive.dart`) builds a
  `TrailNote` (`trail_note.dart`) carrying the call's category, a
  defensively-copied immutable payload, and an injected-clock `recordedAt`,
  then forwards it to an injectable `TrailSink` seam. The trail itself — its
  lifecycle, persistence, and the `inflight` / `recent_runs` stacks — stays
  with the `RunRecorder` (C.31, § 8); C.20 owns only the act of producing a
  note and handing it to the recorder (same deferral strategy as C.19's
  `ProcedureExecutor`). `automationCandidateCategory` exposes the
  `automation_candidate` wire value the dispatcher's harvester keys on
  (§ 5.1). `nativePrimitivesInstaller` now takes named
  (`runProcedurePrimitive`, `notePrimitive`) parameters and wires `note` as a
  top-level d4rt function alongside `runProcedure`; the payload is coerced
  from a d4rt map literal into `Map<String, Object?>` at the boundary
  (String keys enforced). 10 unit tests (`test/note_primitive_test.dart`) +
  3 d4rt-wiring tests (`test/native_primitives_installer_test.dart`).
- C.21 — Third engine-native primitive: `yield_if_foreground_waiting()`.
  `PreemptionState` (`lib/src/preemption/preemption_state.dart`) is the
  shared cooperative-preemption object: a "foreground waiting" flag plus a
  `Completer`-backed resume signal, driven by the coordinator
  (`requestForegroundPreemption` / `signalResume`, both idempotent) and read
  by the engine (`isForegroundWaiting` / `resumeSignal`). `YieldPrimitive`
  (`lib/src/primitives_native/yield_primitive.dart`) reads that state: it
  returns immediately when no foreground is waiting and parks on the resume
  signal until the coordinator signals resume otherwise (PE-5; definition
  § 7.1, § 14.10) — a foreground arrival preempts the background at its next
  checkpoint, never mid-step. The coordinator write-side
  (`PreemptionController`, deadline) stays with C.34/C.36; C.21 owns only the
  read-side checkpoint + the shared state contract. `nativePrimitivesInstaller`
  now takes a third named `yieldPrimitive` parameter and wires
  `yield_if_foreground_waiting` as a top-level d4rt function. 9 unit tests
  (`test/yield_primitive_test.dart`) + 2 d4rt-wiring tests
  (`test/native_primitives_installer_test.dart`).
- C.22 — Consolidated acceptance suite for the three engine-native
  primitives (`test/c22_native_primitives_test.dart`, 8 tests). Drives all
  three end-to-end through `D4rtDcliHost` against the live production
  constants and pins the three plan facts: the depth cap is honoured (a
  self-re-entering chain reaches depth 10, the 11th level errors with
  `RecursionLimitExceeded` surfaced out of the script, carrying
  attempted-depth 11 / cap 10 / target id); a `note` appears in the trail
  (the `RunRecorder`'s `TrailSink` seam modelled by a collecting list) with
  the right category (`automation_candidate` and free-form, in call order);
  `yield_if_foreground_waiting` returns immediately when no foreground is
  waiting and suspends until the coordinator signals resume when one is.
  A final test runs `note` + `yield` + `runProcedure` together in one
  script on one host. No production code changed — C.22 is a test-only step.
  Full suite green at 179/179.
- C.23 — Procedure store with two backends behind one interface
  (`lib/src/procedure_store/`, § 9). `ProcedureStore` (the I/O-only
  interface: `list`, `handles`, `read`) plus three implementations:
  `DiskProcedureStore` (system + user `.dart` files under `scripts/system/`
  + `scripts/user/`, missing-user-dir tolerated, deterministic ordering),
  `MemoryProcedureStore` (brain-authored `Procedure` nodes streamed +
  read through the `TomBrainMemoryClient` boundary, PE-10), and
  `CompositeProcedureStore` (fans `list`, routes `read` by `handles`).
  Value types `ProcedureOrigin` / `ProcedureRef` / `ProcedureSource`.
  The store traffics in raw source keyed by physical location; header
  parsing (C.24) and version resolution (C.25) layer on top. 25 unit tests
  (`test/procedure_store_test.dart`), including a backend-equivalence check
  through the interface. Full suite green at 204/204.

- C.24 — Procedure loader: parses the structured `/// @procedure`
  doc-comment header (§ 4.4) into a typed `ProcedureHeader`
  (`lib/src/procedure_store/procedure_loader.dart`). `ProcedureLoader`
  extracts the contiguous `///` block at the `@procedure` marker, parses it
  as YAML (the `yaml` package, promoted from transitive to direct), and
  builds the header — id, version, summary, successCriterion, inputs,
  outputs, budget caps, requires. A header missing `id` / `version` /
  `summary` / `successCriterion` / `budget`, or that fails to parse, is
  rejected with `ProcedureHeaderInvalid` (code `procedure.header.invalid`).
  Value types `ProcedureHeader` / `ProcedureBudget` / `ProcedureInputDecl` /
  `ProcedureOutputDecl` and the `LoadedProcedure` bundle (ref + header +
  verbatim source). The loader never parses the body and never resolves
  versions (C.25's job). 25 unit tests (`test/procedure_loader_test.dart`).
  Full suite green at 229/229.
