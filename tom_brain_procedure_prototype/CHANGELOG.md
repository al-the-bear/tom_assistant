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
- C.25 — Procedure resolver: indexes loaded procedures by `(id → version)`
  and resolves a request to one `LoadedProcedure`, exposing the fallback
  chain `[v_latest, …, v1]` (PE-6)
  (`lib/src/procedure_store/procedure_resolver.dart`). `ProcedureResolver`
  groups by id with each group ordered descending by version; `resolve(id)`
  returns the latest, `resolve(id, version:)` the exact version, and
  `fallbackChain(id, {from})` the newest-first chain (full, or stepped down
  from a given version). A duplicate `(id, version)` is rejected at
  construction with `ArgumentError`; an unknown id/version raises the new
  `ProcedureNotFound` (code `procedure.not_found`). `fromStore` is the
  production path — enumerate → read → load → resolve, skipping a ref that
  reads back `null` (benign list/read race) and propagating a malformed
  header unchanged. In the prototype only `v1` of any procedure exists, so a
  chain is a singleton; the chain machinery is present regardless (PE-6). 26
  unit tests (`test/procedure_resolver_test.dart`). Full suite green at
  255/255.
- C.26 — Procedure store + loader + resolver acceptance suite
  (`test/procedure_store_acceptance_test.dart`): the dedicated test step for
  the C.6 subphase, raising the three pillars from the unit level to the
  integrated `store → loader → resolver` pipeline. Pillar 1 — a disk store
  and a memory store seeded with the *same* procedure sources produce
  equivalent resolvers (same ids, versions, and resolved headers), proving
  the backends behave identically all the way up to a resolved version, not
  just at the raw `read` layer. Pillar 2 — a table of ten malformed-header
  shapes is rejected with `ProcedureHeaderInvalid`
  (`procedure.header.invalid`), and the rejection propagates when a
  malformed header reaches the loader through `ProcedureResolver.fromStore`.
  Pillar 3 — over a `CompositeProcedureStore` mixing a disk-backed v1 and a
  brain-authored v2, the resolver picks the latest by default, the exact
  version on request, and builds the cross-backend `[2, 1]` fallback chain;
  unknown id/version raise `ProcedureNotFound`. 17 acceptance tests; no
  production code changed. Full suite green at 272/272.
- C.27 — Header validator (`lib/src/validator/header_validator.dart`,
  `HeaderValidator`): the first of the three validator layers (§ 7, row 1 →
  `procedure.header.invalid`). Runs before a procedure reaches
  `draft`/runnable. `validateHeader` re-affirms the five required fields at
  the header-object boundary (non-empty `id` / `summary` / `successCriterion`,
  positive `version`, non-empty `budget`) so a brain-authored `Procedure`
  node built directly in memory — not via the loader — still has a gate; the
  success-criterion presence check is the explicit § 7 requirement.
  `validateVersionChain` adds the check the loader cannot make from one
  header: across an id's whole version set, versions must be positive and
  strictly increasing (duplicates and zero/negative versions rejected; gaps
  allowed, since procedures are demoted, never deleted). `validateAll`
  composes both over a loaded set. Failures throw `ProcedureHeaderInvalid`
  (wire code `procedure.header.invalid`). 17 unit tests
  (`test/header_validator_test.dart`). Full suite green at 289/289.
- C.28 — Sandbox validator (`lib/src/validator/sandbox_validator.dart`,
  `SandboxValidator`): the second of the three validator layers (§ 7, row 3 →
  `procedure.sandbox.violation`) — the *static* half of the PE-1 surface
  lock. Scans a procedure's verbatim source before it reaches the host and
  rejects any `import`/`export` directive (procedures may not import
  anything, § 4.2) or reference to a disallowed top-level identifier (the
  SDK gateways for file system, processes, sockets, isolates, the standard
  streams, and `eval`). The scan runs over a **code projection** that blanks
  comment bodies and string-literal text (newlines preserved for line
  numbers) while keeping interpolated code (`${ ... }` / `$id`), so a banned
  word in a comment or string literal does not trip the gate but one smuggled
  through an interpolation does. Only top-level references match
  (`obj.Process` and `Processor` are not flagged). Deny sets are configurable
  via the constructor; `SandboxValidator.shared` uses the defaults. Failures
  throw `ProcedureSandboxViolation` (wire code `procedure.sandbox.violation`)
  carrying `kind` / `offender` / `line` / `procedureId`. 24 unit tests
  (`test/sandbox_validator_test.dart`). Full suite green at 313/313.
- C.29 — Contract validator (`lib/src/validator/contract_validator.dart`,
  `ContractValidator`): the third and final validator layer (§ 7, rows 4–5).
  Two checks. (1) **Signature** — the source must declare
  `Future<ProcedureResult> run(ProcedureInputs inputs) async { … }`; a
  missing entry point, wrong return type, wrong/absent/multiple parameter, or
  non-`async` function is rejected with `ProcedureContractInvalid` (wire code
  `procedure.contract.invalid`) carrying a `ContractViolationKind`. (2)
  **Requires-vs-actual** — the header's declared `requires` set must exactly
  equal the bridged primitives the body calls; an undeclared call, an unused
  declaration, or a `requires` entry that names no bridged primitive is
  rejected with `ProcedureRequiresMismatch` (wire code
  `procedure.requires.mismatch`) carrying a `RequiresMismatchKind` +
  `offender`. The bridged-primitive surface is enumerated in a new
  `BridgedPrimitiveCatalog` (memory + substrate + engine-native + sugar), which
  also derives the accepted call-site spellings (dotted `stack.push` and
  camelCase `stackPush` both count, pending the Q-C.12.2 wiring decision). The
  C.28 comment-and-string-aware projection was extracted into a shared
  `CodeProjection` and is reused here so a `run(` token in a comment is never
  the entry point and a primitive name in a string literal is never counted as
  a call, while a call inside an interpolation is. 25 unit tests
  (`test/contract_validator_test.dart`). Full suite green at 338/338.
- C.30 — Validator branch-coverage / consolidation acceptance suite
  (`test/c30_validator_branch_coverage_test.dart`, tests only): one
  malformed-input case per documented rejection branch of all three validator
  layers (header required-fields + version-chain, sandbox directive +
  identifier families, contract signature `ContractViolationKind`s, contract
  requires `RequiresMismatchKind`s), each asserted on its stable wire code and
  `kind` / `field` / `offender`. Adds the cross-layer gate test that drives the
  three validators in the engine's order (header → sandbox → contract) over a
  loaded set: a clean procedure clears all three; a procedure malformed in one
  layer is rejected by that layer; layer ordering is proven by sources
  malformed in two layers surfacing the earlier layer's fault. Per-group
  coverage guards assert every enum value / required field has a case. 45 new
  tests. Full suite green at 383/383.
- C.31 — Run recorder (`lib/src/recorder/`, § 8). `RunRecorder`
  (`run_recorder.dart`) records one procedure run end-to-end against the
  `TomBrainMemoryClient` boundary (PE-10): `start` opens a per-run trail
  (`openTrail`), writes the `invocation` entry, persists a `status: running`
  `ProcedureRun` marker and pushes its id onto the `inflight` stack;
  `recordPrimitiveCall` / `recordError` append trail entries; the `note` sink
  (`noteSink`, the C.20 `TrailSink` seam) appends `TrailEntryKind.note` lines;
  `complete` persists the authoritative final `ProcedureRun` (status, summary,
  effort, produced-node ids, startedAt/finishedAt), draws `derived_from` to
  the procedure node (when memory-resident) and `produced_by` from each result
  node back to the run, removes the marker from `inflight`, pushes the final
  record to `recent_runs`, and closes the trail with the outcome. Two
  append-only records (running marker + final) reconcile "on `inflight` at
  start" with "final effort on the node" under immutable memory (Q-C.31.1);
  `derived_from` is conditional on a procedure node id (Q-C.31.2).
  `EffortMetrics` (`effort_metrics.dart`) carries the closed seven-field metric
  set (`wallClockMs`, `llmCalls`, `inputTokens`, `outputTokens`, `toolCalls`,
  `memoryReads`, `memoryWrites`; primary metric `estimatedTokens =
  inputTokens + outputTokens`) with `plus` / `withWallClockMs` combinators for
  C.32's per-primitive accumulation. Value types `RunStart` / `RunCompletion` /
  `ProcedureRunRecord` and the well-known names (`inflight`, `recent_runs`,
  `ProcedureRun`) in `run_records.dart`. 26 unit tests
  (`test/run_recorder_test.dart`): EffortMetrics algebra + the full recorder
  lifecycle against a stub memory/stacks. Full suite green at 409/409.
- C.32 — Effort accounting (`lib/src/recorder/effort_accountant.dart`, § 8;
  definition § 7.4). `EffortAccountant` is a pure, stateless classifier that
  maps one bridged-primitive call to its `EffortMetrics` delta: `llm` →
  `+1 llmCall` plus `inputTokens`/`outputTokens` read off the call's `report`;
  `embed`/`search`/`fetch` → `+1 toolCall`; `recall`/`stack.list`/`stack.peek`
  → `+1 memoryRead`; `persist`/`edge`/`propose_node_type`/`stack.create`/`.push`/
  `.pop`/`.update`/`.remove` → `+1 memoryWrite`; engine-native control flow
  (`runProcedure`/`note`/`yield_if_foreground_waiting`) and unrecognised names →
  zero. Dotted (`stack.push`) and camelCase (`stackPush`) names normalise to the
  same bucket; malformed/negative token fields degrade to zero. `RunRecorder`
  now folds each recorded primitive call into a running `accumulatedEffort`
  (via `EffortMetrics.plus`) and `complete` persists `accumulatedEffort + the
  caller-supplied completion effort`, stamping the run's measured wall clock
  unless a non-zero one is injected. `wallClockMs` is never summed from per-call
  latencies — it is the run's elapsed, stamped once. 31 accountant unit tests
  (`test/effort_accountant_test.dart`) + 4 recorder-accumulation tests added to
  `test/run_recorder_test.dart`. Full suite green at 444/444.
- C.33 — Run-recorder ↔ stub-memory integration tests
  (`test/run_recorder_integration_test.dart`, § 8). Test-only step: where
  C.31/C.32 drive capture-only stubs, C.33 drives the recorder as a black box
  against a *stateful* in-memory double of `TomBrainMemoryClient` + `StackApi`
  that actually models nodes (resolvable by `get`), trails (read back in order
  via `readTrail`, with `closeTrail` synthesising the `outcome` line), and live
  stacks (`push`/`peek`/`pop`/`remove`). The four plan-acceptance assertions read
  the observable store state, not the recorder's mirror: full lifecycle
  round-trips; trail entries appear in order; `inflight` resolves to a `running`
  marker mid-run; the final run lands in `recent_runs` (with the accumulated
  effort) and leaves `inflight` on completion. Two extra integration tests cover
  two sequential runs landing independently and the `derived_from` edge. 6 new
  tests. Full suite green at 450/450.
- C.34 — `PreemptionState` ownership finalised (`lib/src/preemption/`, § 9, PE-5,
  § 10.3). Opens subphase C.9. The state object (the "foreground waiting" flag +
  a `Completer` for the resume signal — the contract the engine-native
  `yield_if_foreground_waiting()` checkpoint reads against) was first cut early as
  a dependency of the C.21 yield primitive; C.34 is its owning step. No production
  logic changed — the object already matched the plan text exactly. The C.21-era
  doc framing in `preemption_state.dart` and the `preemption.dart` barrel is
  corrected: the `PreemptionController` / `RunCoordinator` that *drive* this state
  belong to the Phase D dispatcher (spec § 10.3; build order D.23–D.25), not to
  C.34, and the hard step deadline is C.36; C.34 owns *only* the shared object.
  The state's unit tests are extracted from `yield_primitive_test.dart` into a
  dedicated `test/preemption_state_test.dart` (mirroring the lib file), with one
  added edge case (a redundant `signalResume` after a completed cycle is a no-op):
  7 tests. Full suite green at 451/451.
- C.35 — `yield_if_foreground_waiting()` against `PreemptionState`
  (`lib/src/primitives_native/yield_primitive.dart`, § 5.1, § 9, PE-5). Owning
  step for the cooperative checkpoint within subphase C.9. The `YieldPrimitive`
  and its d4rt installer wiring were first cut at C.21 (subphase C.5) so the
  installer had something to register; C.35 finalises the checkpoint against the
  C.34-finalised state object, the same way C.34 finalised the state the C.21
  primitive depended on. No production logic changed. The C.21-era doc framing
  in `yield_primitive.dart` and the `primitives_native.dart` barrel is corrected:
  the `RunCoordinator` / `PreemptionController` that *drive* the state belong to
  the Phase D dispatcher (spec § 10.3; build order D.23–D.25), not to C.34; the
  hard step deadline is C.36. One new Dart-level edge case pins the
  reusable-across-cycles contract (a single primitive instance parks during a
  request→resume cycle, then returns immediately once the state is idle again):
  4 tests in `yield_primitive_test.dart`. Full suite green at 452/452.
- C.36 — `StepDeadline` (`lib/src/preemption/step_deadline.dart`, § 9, PE-5;
  def § 7.1, § 14.10). The hard per-step wall-clock cap (default 60 s,
  `defaultStepDeadline`) that force-yields a runaway background step. `start`
  arms an injectable wall-clock timer (`DeadlineTimerFactory`, default
  `Timer.new`); `guard<T>` races the step future against it and reports a sealed
  `StepOutcome<T>` — `StepCompleted` (step wins, timer cancelled), `StepTruncated`
  (deadline wins, carries the breached limit). A step error before the deadline
  propagates; a late result/error on an abandoned (truncated) step is dropped.
  The engine step-runner (C.38) maps `StepTruncated` onto
  `RunCompletion(status: preempted, …)` + a `step_truncated`
  (`stepTruncatedNoteCategory`) trail note. Independent of `PreemptionState`
  (C.34): the state bounds the wait to one step *cooperatively*; the deadline
  bounds the step itself *hard*. Driving the foreground/background coordinator
  stays with the Phase D dispatcher (spec § 10.3; build order D.23–D.25). 13
  deterministic unit tests via a `_FakeTimer` double
  (`test/step_deadline_test.dart`). Full suite green at 465/465.

- C.37 — cooperative-preemption subphase (C.9) integration tests
  (`test/cooperative_preemption_test.dart`, § 9, PE-5; plan § C.9). Pins the
  three behaviours the plan names together: (1) a foreground signal triggers a
  yield — a background loop calling `yield_if_foreground_waiting()` between
  steps parks at its next checkpoint when a foreground is waiting; (2) resume
  after the foreground completes — `signalResume` releases the parked loop,
  which finishes its remaining steps with the checkpoint now idle; (3) deadline
  expiry produces a truncated-step trail entry — a step that overruns its
  `StepDeadline` is force-yielded, and a small test-local step-runner
  (`_DeadlineStepRunner`) maps the `StepTruncated` onto a `step_truncated`
  (`stepTruncatedNoteCategory`) trail note carrying the breached limit plus a
  `preempted` `RunCompletion`, read back off the `RunRecorder`'s trail. The
  step-runner is a test double, not production code: wiring `StepDeadline.guard`
  into real `runProcedure` step execution and owning the
  `StepTruncated → RunCompletion(preempted) + note` mapping is the engine
  step-runner's job at C.38. 4 new tests; full suite green at 469/469.
