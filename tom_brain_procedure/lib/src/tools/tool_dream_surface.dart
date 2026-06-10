// ToolDreamSurface — the narrow dreaming-control capability the `dream.control`
// tool routes through (`tom_brain_procedure_specification.md` § 21.4;
// `memory_specification.md` § 9.7).
//
// The dreaming cadence is owned by the run assembly's `DreamController`
// (tom_brain_run), built *after* the cognition boots over the booted
// coordinator / engine / memory. A `BrainTool` cannot reach that controller
// directly — it reaches nothing but the surfaces its `ToolContext` hands it
// (PE-1). This interface is the only dreaming capability a tool may touch: it
// exposes exactly the four operator actions and nothing else (no write path, no
// substrate, no scheduler handle).
//
// Method-only and result-as-data, mirroring [ToolEngineSurface]: the three
// mutating actions return nothing and [dreamStatus] returns a plain
// JSON-serialisable map. Holding the surface grants a tool no capability past
// these four calls.
//
// Optional on a [ToolContext]: a cognition booted without a dreaming cadence
// (the `dream:` block absent or disabled) carries no surface, and the tool
// raises `ToolSurfaceUnavailable` rather than silently degrading — the same
// shape the `web.*` / `procedure.*` tools take when their surface is absent.

/// The dreaming-control capability the `dream.control` `BrainTool` may use
/// (§ 21.4). Implemented by the run assembly's `DreamController` and bound onto
/// the engine's per-run [ToolContext] when a dreaming cadence is configured.
///
/// Method-only and result-as-data (PE-1). The verbs mirror the controller's
/// runtime mode machine: [forceFor] starts dreaming for a bounded period
/// regardless of the configured windows, [suspend] stops it until resumed,
/// [resume] returns to following the configured schedule, and [dreamStatus]
/// reports the current dreaming state.
abstract interface class ToolDreamSurface {
  /// Forces dreaming on for [period], regardless of the configured windows,
  /// then auto-reverts to the configured schedule ("start dreaming for a
  /// certain period").
  void forceFor(Duration period);

  /// Suspends dreaming until [resume] is called, even inside a configured
  /// window ("stop dreaming").
  void suspend();

  /// Returns to following the configured schedule, clearing any forced deadline
  /// or suspension ("continue dreaming if the configured schedule was
  /// interrupted").
  void resume();

  /// A JSON-serialisable snapshot of the current dreaming state ("find out if
  /// the brain is currently dreaming") — at least `{mode, active, running}`.
  Map<String, Object?> dreamStatus();
}
