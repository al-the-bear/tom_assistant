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
/// This barrel is intentionally empty at C.6 (the skeleton step). The
/// public surface lands incrementally:
///
/// - C.6 ✅ — Project skeleton (`lib/`, `test/`, `pubspec.yaml`,
///   `_copilot_guidelines/`).
/// - C.7 — Runtime dependencies (`tom_brain_shared`,
///   `tom_brain_memory` interface, `tom_brain_substrate` interface,
///   `tom_basics`, `tom_core_kernel`, `tom_core_d4rt`, `tom_d4rt`,
///   `tom_d4rt_dcli`).
/// - C.8 — `lib/src/` folder layout (`d4rt_host/`, `bridges/`,
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
