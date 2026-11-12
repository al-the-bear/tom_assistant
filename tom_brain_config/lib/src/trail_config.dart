// TrailConfig — the typed `trail:` section of the whole-process config, plus
// the two operating modes it selects (`tom_brain_logging.md` §4.1 / §8;
// §10 build-order step #1).
//
// The trail directory is a configuration value. §4.1 defines two modes:
//
//   * Full trailing  — a `trail:` block whose `root` is configured: the whole
//     tree under `trail.root` is written.
//   * Unconfigured   — no `trail:` block at all: only `brain.log` +
//     `components/*.log` in the CWD; every other surface disabled.
//
// §8 lists the block's overgrowth caps and the `capture` sub-block, with the
// defaults reproduced below. The mode is carried as `TrailConfig?` on the
// whole-process `BrainRunConfig`: `null` ⇒ unconfigured, a value ⇒ full. This
// value type is read-only — it is parsed once at boot by `TrailConfigLoader`
// and never re-serialised.

/// Which trail surfaces the process writes (`tom_brain_logging.md` §4.1).
enum TrailMode {
  /// No `trail:` block was configured: only `brain.log` + `components/*.log`
  /// are written, to the current working directory. Every other surface
  /// (`llm/`, `incoming/`, `procedures/`, `memory/`, `sessions/`, `summary/`)
  /// is disabled.
  unconfigured,

  /// A `trail.root` was configured: the whole tree under the root is written.
  full,
}

/// Thrown when a `trail:` block is structurally invalid (missing `root`, a
/// non-positive cap, an unknown key, an undefined `${ENV}` token, …).
///
/// Messages carry the dotted key path (e.g. `trail.compactLogCap`) so the
/// offending field is obvious — the same located-error discipline the sibling
/// section loaders use.
class TrailConfigException implements Exception {
  /// Builds the exception with a [message].
  const TrailConfigException(this.message);

  /// Human-readable, located explanation.
  final String message;

  @override
  String toString() => 'TrailConfigException: $message';
}

/// The parsed `trail:` section (`tom_brain_logging.md` §8).
///
/// Present ⇒ full trailing mode; its absence (a `null` on `BrainRunConfig`)
/// ⇒ unconfigured mode. Caps and the `capture` flags default to the §8 values
/// when omitted; [root] is always required when the block is present (the
/// loader never synthesises a default root — see `TrailConfigLoader`).
final class TrailConfig {
  /// Assembles a trail config. Only [root] is required; every cap / capture
  /// flag defaults to its §8 value.
  const TrailConfig({
    required this.root,
    this.compactLogCap = 1000,
    this.liveTrailTurns = 20,
    this.llmPerRoleCap = 300,
    this.incomingPerChannelCap = 300,
    this.proceduresPerKindCap = 300,
    this.rawAggregateSizeMb = 1024,
    this.captureWireBody = true,
    this.captureInternalRoles = true,
  });

  /// The trail tree root (`_ai/tom_brain_trail/<machine>` in the shipped
  /// config). `${ENV}` tokens are expanded by the loader before construction.
  final String root;

  /// Max turns/prompts per compact/summary log before oldest blocks drop.
  final int compactLogCap;

  /// The per-session `live-trail.md` rolling window (turns kept).
  final int liveTrailTurns;

  /// Raw-dump count cap per `llm/<role>/` folder.
  final int llmPerRoleCap;

  /// Raw-dump count cap per `incoming/<channel>/` folder.
  final int incomingPerChannelCap;

  /// Combined-run count cap per `procedures/<proc>/` folder.
  final int proceduresPerKindCap;

  /// Aggregate size ceiling (MB) across `llm/` + `incoming/` + `procedures/`.
  final int rawAggregateSizeMb;

  /// Whether LLM raw dumps capture the full anchor-scaffold wire body.
  final bool captureWireBody;

  /// Whether internal (non-user-facing) LLM calls are trailed too.
  final bool captureInternalRoles;
}
