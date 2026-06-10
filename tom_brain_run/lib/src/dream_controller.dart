// DreamController (items b + c) — the runtime gate over the dream cadence loop.
//
// Item b wires the dream cadence into startup with *configurable daily
// time-slots*. Item c adds an operator/tool surface to start dreaming for a
// period, stop it, resume the configured schedule, and ask whether the brain is
// dreaming. Both reduce to one decision the loop asks each heartbeat — *may
// dreaming fire right now?* — so both live here.
//
// The decision is the product of:
//
//   * the configured [DreamWindowSchedule] (the daily time-slots), and
//   * a runtime [DreamModeKind]:
//       - `scheduled`  — follow the windows (the boot default);
//       - `forced`     — dream regardless of the window until a deadline, then
//                        auto-revert to `scheduled` (the tool's "start for N
//                        minutes" / "continue an interrupted schedule" path);
//       - `suspended`  — never dream until explicitly resumed (the tool's
//                        "stop" path).
//
// The controller owns the [DreamCadenceLoop] and feeds it its [isDreamingActive]
// gate, so the heartbeat keeps ticking but only *fires* dream passes when the
// mode + window agree. It holds no write path and no substrate — gating *when*
// the cadence runs cannot affect *what* an agent writes (the no-overwrite
// invariant, hard principle 6, is the agents' property).
//
// Time source: a human configures windows in *local* wall-clock terms
// ("between 02:00 and 05:00 at night"), so the controller reads a local
// [DateTime] via the injected [now] seam (default [DateTime.now]). Tests inject
// a mutable local clock for deterministic window + deadline arithmetic. This is
// deliberately distinct from the cadence driver's UTC `Clock`, which only
// measures elapsed *intervals* — wall-clock zone is irrelevant there but
// load-bearing here.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ToolDreamSurface;

import 'dream_cadence_driver.dart' show DreamCadenceDriver;
import 'dream_cadence_wiring.dart' show DreamCadenceLoop;
import 'dream_window_schedule.dart' show DreamWindowSchedule;

/// The runtime dreaming mode the control surface drives (item c).
enum DreamModeKind {
  /// Follow the configured daily windows (the boot default).
  scheduled,

  /// Dream regardless of the window until a deadline, then revert to
  /// [scheduled].
  forced,

  /// Never dream until explicitly resumed.
  suspended,
}

/// A snapshot of the controller's dreaming state, returned by
/// [DreamController.status] (the tool's `status` action, item c).
final class DreamStatus {
  /// Builds an immutable status snapshot.
  const DreamStatus({
    required this.mode,
    required this.active,
    required this.running,
    required this.alwaysActive,
    this.forcedUntil,
  });

  /// The current runtime mode.
  final DreamModeKind mode;

  /// Whether dreaming may fire *right now* (mode + window agree).
  final bool active;

  /// Whether the heartbeat loop is currently running.
  final bool running;

  /// Whether the schedule imposes no window restriction (empty windows).
  final bool alwaysActive;

  /// When a [DreamModeKind.forced] period ends, or `null` outside forced mode.
  final DateTime? forcedUntil;

  /// The wire shape the `dream.control` tool returns to a procedure (the
  /// [ToolDreamSurface.dreamStatus] contract). [forcedUntil] is emitted as an
  /// ISO-8601 string so the map carries only JSON-native scalars.
  Map<String, Object?> toMap() => <String, Object?>{
        'mode': mode.name,
        'active': active,
        'running': running,
        'alwaysActive': alwaysActive,
        'forcedUntil': forcedUntil?.toIso8601String(),
      };
}

/// Owns the [DreamCadenceLoop] and gates it by the configured windows and the
/// runtime mode (items b + c).
///
/// It is the live implementation of [ToolDreamSurface]: the `dream.control`
/// tool drives `forceFor` / `suspend` / `resume` / `dreamStatus` straight onto
/// the running controller (reached through the run assembly's late-bound
/// holder).
final class DreamController implements ToolDreamSurface {
  /// Builds a controller over the already-assembled cadence [driver] and the
  /// configured [schedule].
  ///
  /// [now] is the local wall-clock source the windows + forced deadlines are
  /// evaluated against (default [DateTime.now]); tests inject a mutable clock.
  /// [heartbeat] and [onTickError] are forwarded to the loop the controller
  /// constructs (and gates with [isDreamingActive]).
  DreamController({
    required DreamCadenceDriver driver,
    required DreamWindowSchedule schedule,
    DateTime Function() now = DateTime.now,
    Duration heartbeat = const Duration(minutes: 1),
    void Function(Object error, StackTrace stack)? onTickError,
  })  : _schedule = schedule,
        _now = now {
    _loop = DreamCadenceLoop(
      driver: driver,
      heartbeat: heartbeat,
      shouldTick: () => isDreamingActive(),
      onTickError: onTickError,
    );
  }

  final DreamWindowSchedule _schedule;
  final DateTime Function() _now;

  late final DreamCadenceLoop _loop;

  DreamModeKind _mode = DreamModeKind.scheduled;
  DateTime? _forcedUntil;

  /// Whether the heartbeat loop is currently running.
  bool get isRunning => _loop.isRunning;

  /// Starts the gated heartbeat. Idempotent.
  void start() => _loop.start();

  /// Stops the heartbeat. Idempotent. Any in-flight tick runs to completion.
  Future<void> stop() => _loop.stop();

  /// Whether dreaming may fire as of [at] (default: the current local time).
  ///
  /// Resolves the mode against the window:
  ///   * `suspended` → never;
  ///   * `forced` → until the deadline, then auto-revert to `scheduled` and
  ///     re-evaluate the window (so a forced period that lapses outside a window
  ///     correctly goes idle);
  ///   * `scheduled` → whether [at] falls in any configured window.
  bool isDreamingActive([DateTime? at]) {
    final instant = at ?? _now();
    switch (_mode) {
      case DreamModeKind.suspended:
        return false;
      case DreamModeKind.forced:
        final deadline = _forcedUntil;
        if (deadline != null && instant.isBefore(deadline)) {
          return true;
        }
        // The forced period lapsed: fall back to the schedule from here on.
        _mode = DreamModeKind.scheduled;
        _forcedUntil = null;
        return _schedule.isActiveAt(instant);
      case DreamModeKind.scheduled:
        return _schedule.isActiveAt(instant);
    }
  }

  /// Forces dreaming on for [period], regardless of the configured windows
  /// (item c — "start dreaming for a certain period"). After the period the
  /// controller reverts to [DreamModeKind.scheduled].
  @override
  void forceFor(Duration period) {
    _mode = DreamModeKind.forced;
    _forcedUntil = _now().add(period);
  }

  /// Suspends dreaming until [resume] is called, even inside a configured window
  /// (item c — "stop dreaming").
  @override
  void suspend() {
    _mode = DreamModeKind.suspended;
    _forcedUntil = null;
  }

  /// Returns to following the configured schedule (item c — "continue dreaming
  /// if the configured schedule was interrupted"). Clears any forced deadline or
  /// suspension.
  @override
  void resume() {
    _mode = DreamModeKind.scheduled;
    _forcedUntil = null;
  }

  /// A snapshot of the current dreaming state (item c — "find out if the brain
  /// is currently dreaming").
  DreamStatus status() => DreamStatus(
        mode: _mode,
        active: isDreamingActive(),
        running: isRunning,
        alwaysActive: _schedule.isAlwaysActive,
        forcedUntil: _forcedUntil,
      );

  /// The [ToolDreamSurface] read the `dream.control` tool returns for every
  /// action — the [status] snapshot as a JSON-native map.
  @override
  Map<String, Object?> dreamStatus() => status().toMap();
}
