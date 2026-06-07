// ToolEngineSurface — the narrow engine capability the `procedure.*` and
// `script.run_d4rt` tools route through
// (`tom_brain_procedure_prototype_specification.md` § 21.4).
//
// These three tools overlap engine machinery that already exists, so they open
// **no new effect path** (Q-F.5) and introduce **no second interpreter**
// (PE-10): the engine binds this surface over the existing `ProcedureStore`,
// the depth-capped `runProcedure` primitive, and the engine's own sandboxed
// d4rt host at wiring time (step 15). The surface is method-only and returns
// JSON-serialisable values — a tool reaches nothing past it (PE-1).
//
// Depth is the engine's invariant, not the tool's: `runProcedure` and a nested
// `runD4rtScript` both run under the hard recursion cap (PE-3), and a breach
// raises `RecursionLimitExceeded`. The tools do **not** catch it — a depth-cap
// refusal propagates exactly like a budget refusal, ending the call.

/// The procedure-listing / procedure-running / nested-d4rt capability a
/// `procedure.*` or `script.run_d4rt` `BrainTool` may use.
///
/// Method-only and result-as-data (PE-1). Optional on a `ToolContext` — a run
/// that exposes no procedure or script tools carries none.
abstract interface class ToolEngineSurface {
  /// Lists the procedures the store can serve, each as a plain descriptor map
  /// (`{id, origin, ...}`). Read-only — routes through `ProcedureStore.list`.
  Future<List<Map<String, Object?>>> listProcedures();

  /// Runs the procedure named [id] with [inputs] (optionally pinning
  /// [version]), returning its result as a plain map (`{status, outputs}`).
  ///
  /// Routes through the depth-capped `runProcedure` primitive: a call that
  /// would push the chain past the hard cap raises `RecursionLimitExceeded`
  /// before the target runs (PE-3).
  Future<Map<String, Object?>> runProcedure(
    String id,
    Map<String, Object?> inputs, {
    int? version,
  });

  /// Evaluates [source] as a nested sandboxed d4rt script and returns its raw
  /// result (the caller checks JSON-serialisability).
  ///
  /// Reuses the engine's own host — not a second interpreter (PE-10) — under
  /// the same sandbox + budget + depth cap as any nested run; a depth breach
  /// raises `RecursionLimitExceeded`.
  Future<Object?> runD4rtScript(String source);
}
