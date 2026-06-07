/// Procedure prototype for Tom Brain — a thin d4rt-hosted engine
/// (Phase C) plus a thin dispatcher (Phase D) combined into one
/// project per `tom_brain_definition.md` § 12.
///
/// The prototype ships exactly one hand-written sequence
/// (`answer_with_memory_v1`: recall → answer → persist) and proves the
/// *machinery* that runs it — a sandboxed d4rt host, a bridged
/// primitive API that re-exposes `tom_brain_memory` +
/// `tom_brain_substrate`, a run recorder that writes the run into
/// memory, a fallback chain, and cooperative single-foreground /
/// single-background preemption. It is **not** an authoring
/// environment and not the full bootstrap library
/// (`tom_brain_procedure_prototype_specification.md` § 0, § 2).
///
/// Hard invariant the package is built around: the bridged primitive
/// API is the only surface a procedure can touch (PE-1), and every
/// prompt the machinery issues carries the assistant-dedication anchor
/// because `llm(...)` always routes through substrate (PE-7).
///
/// At C.8 the `lib/src/` folder layout is in place but every subfolder
/// barrel is intentionally empty — the public surface lands
/// incrementally across the remaining Phase C steps:
///
/// - C.6 ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `_copilot_guidelines/`).
/// - C.7 — Runtime dependencies (`tom_brain_shared`,
///   `tom_brain_memory` interface, `tom_brain_substrate` interface,
///   `tom_basics`, `tom_core_kernel`, `tom_core_d4rt`, `tom_d4rt`,
///   `tom_d4rt_dcli`).
/// - C.8 ✅ — `lib/src/` folder layout (`d4rt_host/`, `bridges/`,
///   `primitives_native/`, `procedure_store/`, `validator/`,
///   `recorder/`, `preemption/`, `api/`, `config/`).
/// - C.11–C.15 — D4rt bridge-generator config + `MemoryBridge` /
///   `SubstrateBridge` source classes.
/// - C.16–C.18 — `D4rtDcliHost`.
/// - C.19–C.22 — engine-native primitives (`runProcedure`, `note`,
///   `yield_if_foreground_waiting`).
/// - C.23–C.26 — procedure store + loader + resolver.
/// - C.27–C.30 — validator.
/// - C.31–C.33 — run recorder.
/// - C.34–C.37 — cooperative preemption hooks.
/// - C.38–C.41 — engine API surface (`ProcedureEngine`).
/// - C.42–C.45 — configuration + observability.
///
/// See `_ai/quests/tom_brain/tom_brain_procedure_prototype_specification.md`
/// for the authoritative contract this package implements.
library;

// C.8 — module barrels. Each `src/<folder>/<folder>.dart` is currently
// an empty barrel; the export here ensures the top-level package
// surface mirrors the internal layout from day one. As later C-steps
// add public symbols inside each module, the symbols become visible
// through `package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart`
// without further changes here. Order mirrors the engine pipeline:
// host → bridges → native primitives → store → validator → recorder →
// preemption → api → config, then the Phase D dispatcher half on top.
export 'src/d4rt_host/d4rt_host.dart';
export 'src/bridges/bridges.dart';
export 'src/primitives_native/primitives_native.dart';
export 'src/procedure_store/procedure_store.dart';
export 'src/validator/validator.dart';
export 'src/recorder/recorder.dart';
export 'src/budget/budget.dart';
export 'src/preemption/preemption.dart';
export 'src/api/api.dart';
export 'src/config/config.dart';

// Extension F — the scripted LLM loop (`prototype_tools_mcp_extension_plan.md`,
// spec § 21). Step 1 lands the prompt-assembly placeholder system; step 4
// lands the tool-calling core (`BrainTool` / `ToolRegistry` / `ToolContext`);
// later steps add the MCP client, prompt-template loader, and the
// `call_llm_v1` loop through this same surface.
export 'src/prompts/prompts.dart';
export 'src/tools/tools.dart';
// Step 8 — the MCP client (`mcp.servers` / `mcp.list` / `mcp.call`, § 21.3).
export 'src/mcp/mcp.dart';

// D.6 — dispatcher half. The dispatcher consumes the engine surface
// above (`ProcedureEngine`) and adds the `accept(Access)` entry point,
// the foreground/background coordinator, fallback, and the free-time
// scheduler. Empty barrel at D.6; symbols land across D.11–D.50.
export 'src/dispatcher/dispatcher.dart';
