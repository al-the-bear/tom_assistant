// Barrel for the `bridges/` module (Plan step C.8).
//
// Owns the d4rt bridge surface that re-exposes `tom_brain_memory` and
// `tom_brain_substrate` to procedure scripts
// (`tom_brain_procedure_prototype_specification.md` § 3, Plan steps
// C.11–C.15):
//
//   - `MemoryBridge` — `@D4rtBridged` source class exposing the memory
//     primitive set (`recall`, `persist`, `edge`, `propose_node_type`,
//     `stack.list`, `stack.create`, `stack.push`, `stack.peek`,
//     `stack.pop`, `stack.update`, `stack.remove`).
//   - `SubstrateBridge` — `@D4rtBridged` source class exposing
//     `llm(prompt, role, budget)`, `embed(text)`,
//     `search(query, provider, k)`, `fetch(url, budget)`.
//   - The `tom_d4rt_generator`-produced `*.b.dart` companions.
//
// Hard invariant (PE-7): every prompt the machinery issues carries the
// assistant-dedication anchor because `SubstrateBridge.llm(...)` always
// routes through the substrate client.
//
// Wiring across later Phase C steps:
//
//   - C.11 — `build.yaml` generator config targeting this folder.
//   - C.12 — `MemoryBridge` source class.
//   - C.13 — `SubstrateBridge` source class.
//   - C.14 — `dart run build_runner build` output.
//   - C.15 — generator-output round-trip tests against in-memory
//     test doubles.
//
// At C.8 this folder is intentionally empty. No exports yet.
