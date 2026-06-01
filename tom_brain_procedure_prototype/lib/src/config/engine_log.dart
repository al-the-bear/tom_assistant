// EngineLog — category-tagged wrapper over `tomLog` (Plan step C.43).
//
// Plan step C.43 (verbatim):
//   "Wire `TomLogger`: categories `tom_brain.engine.host`, `…bridge`,
//    `…store`, `…recorder`, `…preemption`."
//
// `tom_brain_procedure_prototype_specification.md` § 13 names the same
// five engine categories (the dispatcher adds its own under
// `tom_brain.dispatcher.*` in Phase D; those are not this step's
// concern).
//
// What this file delivers:
//
//   - [EngineLogCategory] — the closed enumeration of the five wiring
//     categories named in the plan, each carrying its canonical
//     `tom_brain.engine.<area>` string identifier. The enum is closed:
//     adding a category is a deliberate edit here, not a stringly-typed
//     accident at a call site.
//
//   - [EngineLog] — a thin value type that pairs a category with the
//     standard log methods (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`). Each method prepends
//     `'[<category>] '` to the message and forwards to the global
//     `tomLog` instance from `tom_basics`.
//
//   - Five const instances (`EngineLog.host`, `…bridge`, `…store`,
//     `…recorder`, `…preemption`) so call sites read like
//     `EngineLog.host.info(...)` with no allocation per call.
//
// Why a wrapper and not raw `tomLog`:
//
//   `TomLogger` itself has no first-class "category" concept. Its
//   per-class/method level overrides are inferred from stack-frame
//   analysis, which filters individual classes but does not give us the
//   operational surface the plan asks for: five named groups whose
//   emissions can be inspected, filtered, or muted as a unit. Prepending
//   a stable `'[tom_brain.engine.<area>]'` tag at this layer:
//
//     * Lets operators grep for one area without depending on which
//       internal class produced the line.
//     * Lets tests assert "this lifecycle event emitted under the
//       expected category" without inspecting Dart's stack analysis.
//     * Keeps the package's public log surface deliberately small (five
//       instances) so a code reviewer can see at a glance which module
//       is logging something.
//
//   This mirrors `MemoryLog` (A.84) and `SubstrateLog` (B.37) exactly —
//   the three Tom-Brain components share one logging idiom so an operator
//   reads `[tom_brain.<component>.<area>]` uniformly across all of them.
//
// Why `EngineLog` is not a singleton service:
//
//   `tomLog` is already a singleton (the global instance). Wrapping it in
//   another singleton would add no value and would make tests harder to
//   drive. The wrapper is a `const` value type; its only state is its
//   category.
//
// Why lazy-evaluated messages are preserved:
//
//   `tomLog` honours the `() => String` pattern for expensive messages
//   (the function is only invoked when the level is enabled). Each method
//   below checks whether the supplied object is a `Function` and, if so,
//   wraps it so the category prefix is added lazily too — otherwise we
//   would defeat the lazy contract by stringifying the message eagerly to
//   attach the tag.
//
// Wiring status (Q-C.43.1):
//
//   C.43 ships the facade and exports it through the `config/` barrel.
//   The C.42 record already established that no engine / store / host /
//   recorder is yet constructed from an `EngineConfig` — those collaborators
//   take their underlying knobs directly, and the Phase D `BrainProcessBoot`
//   is the first composition root. In the same spirit, the immediate sibling
//   `SubstrateLog` (B.37) shipped facade-first with no call-site emissions,
//   leaving wiring to its consumers. C.43 follows that precedent: the surface
//   is the deliverable; call-site emissions are added as the lifecycle points
//   they describe acquire operator value (logged as Q-C.43.1).

import 'package:tom_basics/tom_basics.dart';

/// Closed enumeration of the five logging categories the
/// `tom_brain_procedure_prototype` engine emits under.
///
/// The `name` field carries the canonical string identifier used as the
/// log-line prefix. Adding a new category is a deliberate edit of this
/// enum and the matching [EngineLog] static — there is no way to
/// construct an ad-hoc category from a string.
enum EngineLogCategory {
  /// d4rt host + `ProcedureEngine`: invocation lifecycle, host boot per
  /// run, step-deadline race outcomes, run resolution / completion.
  host('tom_brain.engine.host'),

  /// Bridged effect surfaces (`MemoryBridge`, `SubstrateBridge`):
  /// bridge registration, primitive dispatch, client roundtrips.
  bridge('tom_brain.engine.bridge'),

  /// Procedure store + loader + resolver: disk / memory backend reads,
  /// header parsing, version-fallback selection.
  store('tom_brain.engine.store'),

  /// Run recorder: trail open / append / close, run-node persistence,
  /// effort accounting, `recent_runs` / `inflight` stack updates.
  recorder('tom_brain.engine.recorder'),

  /// Cooperative preemption: foreground-waiting yields, resume signals,
  /// hard step-deadline truncation.
  preemption('tom_brain.engine.preemption');

  const EngineLogCategory(this.name);

  /// Canonical string identifier for this category, used as the log
  /// prefix and as the operator-facing name (e.g. in filter rules).
  final String name;
}

/// A thin, category-tagged facade over the global [tomLog] instance.
///
/// Construct via the five const statics ([host], [bridge], [store],
/// [recorder], [preemption]) — those are the only legal categories. Each
/// method prepends `'[<category>] '` to the message before forwarding to
/// the matching `tomLog` method, preserving the lazy `() => String`
/// contract.
class EngineLog {
  /// The category this logger emits under. Read-only and final.
  final EngineLogCategory category;

  /// Internal: constructs a logger for [category]. Not exposed; the five
  /// static instances below are the public surface.
  const EngineLog._(this.category);

  /// Host + engine logger. See [EngineLogCategory.host].
  static const EngineLog host = EngineLog._(EngineLogCategory.host);

  /// Bridge logger. See [EngineLogCategory.bridge].
  static const EngineLog bridge = EngineLog._(EngineLogCategory.bridge);

  /// Procedure-store logger. See [EngineLogCategory.store].
  static const EngineLog store = EngineLog._(EngineLogCategory.store);

  /// Run-recorder logger. See [EngineLogCategory.recorder].
  static const EngineLog recorder = EngineLog._(EngineLogCategory.recorder);

  /// Preemption logger. See [EngineLogCategory.preemption].
  static const EngineLog preemption =
      EngineLog._(EngineLogCategory.preemption);

  /// All five loggers in the order they appear on
  /// [EngineLogCategory.values]. Convenience for tests and for
  /// operator-facing tools that want to enumerate the surface.
  static const List<EngineLog> all = <EngineLog>[
    host,
    bridge,
    store,
    recorder,
    preemption,
  ];

  /// Most-verbose level. Use for entering / leaving inner methods and
  /// for argument dumps that would be too noisy at `debug`.
  void trace(Object message) => tomLog.trace(_tag(message));

  /// Detailed debugging information. Filtered out at production level.
  void debug(Object message) => tomLog.debug(_tag(message));

  /// Network / data-flow logging.
  void traffic(Object message) => tomLog.traffic(_tag(message));

  /// General runtime information.
  void info(Object message) => tomLog.info(_tag(message));

  /// Potentially problematic situation that did not prevent operation
  /// (e.g. fell back to default policy, missing optional script dir).
  void warn(Object message) => tomLog.warn(_tag(message));

  /// Important lifecycle event — engine boot, run completed, deadline
  /// truncated, etc. Visible even under the `silent` level filter.
  void status(Object message) => tomLog.status(_tag(message));

  /// Error condition (recoverable). Use for failed-but-handled paths.
  void error(Object message) => tomLog.error(_tag(message));

  /// Serious error that may require attention. Use for invariant
  /// violations the caller will need to act on.
  void severe(Object message) => tomLog.severe(_tag(message));

  /// Unrecoverable error. Use for paths that immediately precede an exit
  /// or a process-level failure.
  void fatal(Object message) => tomLog.fatal(_tag(message));

  /// Prepends the category prefix to [message], preserving the
  /// `() => String` lazy-evaluation contract that `tomLog` supports.
  Object _tag(Object message) {
    if (message is String Function()) {
      return () => '[${category.name}] ${message()}';
    }
    if (message is Object Function()) {
      return () => '[${category.name}] ${message()}';
    }
    return '[${category.name}] $message';
  }

  @override
  String toString() => 'EngineLog(${category.name})';
}
