// Barrel for the `bridges/` module (Plan step C.8).
//
// Owns the d4rt bridge surface that re-exposes `tom_brain_memory` and
// `tom_brain_substrate` to procedure scripts
// (`tom_brain_procedure_specification.md` § 3, Plan steps
// C.11–C.15):
//
//   - `MemoryBridge` — plain Dart source class exposing the memory
//     primitive set (`recall`, `persist`, `edge`, `propose_node_type`,
//     `stack.list`, `stack.create`, `stack.push`, `stack.peek`,
//     `stack.pop`, `stack.update`, `stack.remove`). No annotation —
//     selection is `build.yaml`-driven (C.11). ✅ C.12.
//   - `SubstrateBridge` — plain Dart source class exposing
//     `llm(prompt, role, budget)`, `embed(text)`,
//     `search(query, provider, k)`, `fetch(url, budget)`. ✅ C.13.
//   - The `tom_d4rt_generator`-produced `*.b.dart` companions
//     (`brain_bridges.b.dart` → `AllBridge`,
//     `package_tom_brain_procedure_bridges.b.dart`,
//     `d4rt_bridges.b.dart` barrel, `relaxers.b.dart`,
//     `dartscript.b.dart` → `BrainBridges`). ✅ C.14.
//   - `BrainBridges.register(d4rt)` — the generator-produced registration
//     entrypoint over `AllBridge` (`dartscript.b.dart`; `generateDartscript`
//     is ON since `tom_d4rt_generator 1.9.1` fixed the dartscript template —
//     plan-2 item #13a). ✅ C.14.
//   - `BridgeLibraries.*Library` — the host-owned canonical `package:` URIs
//     each bridge is registered/injected under (`bridge_libraries.dart`);
//     injection wiring shared by the host, validator, and tests.
//
// Hard invariant (PE-7): every prompt the machinery issues carries the
// assistant-dedication anchor because `SubstrateBridge.llm(...)` always
// routes through the substrate client.
//
// Wiring across later Phase C steps:
//
//   - C.11 — `build.yaml` generator config targeting this folder. ✅
//   - C.12 — `MemoryBridge` source class. ✅
//   - C.13 — `SubstrateBridge` source class. ✅
//   - C.14 — `dart run build_runner build` output + generated
//     `BrainBridges` registration; generated bridges compile and register. ✅
//   - C.15 — generator-output round-trip tests against in-memory
//     test doubles.

export 'bridge_libraries.dart' show BridgeLibraries;
// The generator-produced registration entrypoint (`generateDartscript:true`,
// plan-2 item #13a). Registers every bridge under each `BridgeLibraries` URI.
export 'dartscript.b.dart' show BrainBridges;
export 'bridge_call_recorder.dart' show BridgeCallRecorder;
// §10 step #4 — the bridge-layer raw-LLM-trail observation and its sink type.
export 'llm_call_observation.dart' show LlmCallObservation, LlmTrailObserver;
export 'memory_bridge.dart';
export 'substrate_bridge.dart';
// Extension F step 6 — the `tool.list` / `tool.invoke` bridged primitive
// pair over the tool-calling core (`src/tools/`).
export 'tool_bridge.dart';
// Extension F step 8 — the `mcp.servers` / `mcp.list` / `mcp.call` bridged
// primitive trio over the MCP client (`src/mcp/`).
export 'mcp_bridge.dart';
// Extension F step 14 — the `vscode.call` bridged primitive (§ 21.9) and its
// narrow `VsCodeScriptingSurface` port (the prototype stays decoupled from
// `tom_vscode_scripting_api`, PE-10).
export 'vscode_scripting_bridge.dart' show VsCodeScriptingBridge;
export 'vscode_scripting_surface.dart'
    show
        VsCodeScriptingFailure,
        VsCodeScriptingSurface,
        vsCodeScriptingFailureCode;
