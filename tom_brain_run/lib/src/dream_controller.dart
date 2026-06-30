// DreamController (items b + c) — the runtime gate over the dream cadence loop.
//
// Item b wires the dream cadence into startup with *configurable daily
// time-slots*. Item c adds an operator/tool surface to start dreaming, stop it,
// open an immediate manual dreaming window, and ask whether the brain is
// dreaming. All reduce to one decision the loop asks each heartbeat — *may
// dreaming fire right now?* — so all live here.
//
// The decision is the product of two layers:
//
//   * a persistent **base mode** ([DreamModeKind]):
//       - `scheduled`  — follow the configured windows (the boot default and the
//                        `/dream_start` state);
//       - `suspended`  — never dream on the schedule (the `/dream_stop` state);
//   * a transient **manual window** — a `/dream_now N` burst opens a window of N
//     minutes during which dreaming is active regardless of the base mode, and
//     immediately fires one out-of-band all-lanes pass. The manual window is an
//     *overlay*: it never changes the base mode (it "must not imply a start")
//     and its immediate pass never counts toward the scheduled-repeat cap.
//
// The controller owns the [DreamCadenceLoop] and feeds it its [isDreamingActive]
// gate, so the heartbeat keeps ticking but only *fires* dream passes when the
// base mode or an open manual window admits it. It holds no write path and no
// substrate — gating *when* the cadence runs cannot affect *what* an agent
// writes (the no-overwrite invariant, hard principle 6, is the agents'
// property).
//
// Time source: a human configures windows in *local* wall-clock terms
// ("between 02:00 and 05:00 at night"), so the controller reads a local
// [DateTime] via the injected [now] seam (default [DateTime.now]). Tests inject
// a mutable local clock for deterministic window + deadline arithmetic. This is
// deliberately distinct from the cadence driver's UTC `Clock`, which only
// measures elapsed *intervals* — wall-clock zone is irrelevant there but
// load-bearing here.

import 'dart:async';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ToolDreamSurface;

import 'dream_cadence_driver.dart' show CadenceSchedule, DreamCadenceDriver;
import 'dream_cadence_wiring.dart' show DreamCadenceLoop;
import 'dream_window_schedule.dart' show DreamWindowSchedule;

/// The persistent base dreaming mode the control surface drives (item c).
///
/// A transient manual window ([DreamController.dreamNow]) overlays this base
/// without changing it — the overlay is reported separately as
/// [DreamStatus.manualUntil], never as a mode.
enum DreamModeKind {
  /// Follow the configured daily windows (the boot default; `/dream_start`).
  scheduled,

  /// Never dream on the schedule until `/dream_start` (`/dream_stop`).
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
    this.manualUntil,
    this.maxRepeatCount,
    this.laneRunCounts = const <String, int>{},
  });

  /// The current persistent base mode.
  final DreamModeKind mode;

  /// Whether dreaming may fire *right now* (base mode or a manual window
  /// admits it).
  final bool active;

  /// Whether the heartbeat loop is currently running.
  final bool running;

  /// Whether the schedule imposes no window restriction (empty windows).
  final bool alwaysActive;

  /// When an open manual (`/dream_now`) window ends, or `null` when no manual
  /// window is open.
  final DateTime? manualUntil;

  /// The global scheduled-repeat cap, or `null` when scheduled repeats are
  /// unlimited.
  final int? maxRepeatCount;

  /// Per-lane count of scheduled passes completed (lane id → count). Manual
  /// bursts never increment these.
  final Map<String, int> laneRunCounts;

  /// The wire shape the `dream.control` tool returns to a procedure (the
  /// [ToolDreamSurface.dreamStatus] contract). [manualUntil] is emitted as an
  /// ISO-8601 string so the map carries only JSON-native scalars.
  Map<String, Object?> toMap() => <String, Object?>{
        'mode': mode.name,
        'active': active,
        'running': running,
        'alwaysActive': alwaysActive,
        'manualUntil': manualUntil?.toIso8601String(),
        'maxRepeatCount': maxRepeatCount,
        'laneRunCounts': laneRunCounts,
      };
}

/// Owns the [DreamCadenceLoop] and gates it by the configured windows, the
/// persistent base mode, and any open manual window (items b + c).
///
/// It is the live implementation of [ToolDreamSurface]: the `dream.control`
/// tool drives `forceFor` (→ [dreamNow]) / `suspend` (→ [stopNormal]) /
/// `resume` (→ [startNormal]) / `dreamStatus` straight onto the running
/// controller (reached through the run assembly's late-bound holder).
final class DreamController implements ToolDreamSurface {
  /// Builds a controller over the already-assembled cadence [driver] and the
  /// configured [schedule].
  ///
  /// [now] is the local wall-clock source the windows + manual deadlines are
  /// evaluated against (default [DateTime.now]); tests inject a mutable clock.
  /// [heartbeat] and [onTickError] are forwarded to the loop the controller
  /// constructs (and gates with [isDreamingActive]).
  DreamController({
    required DreamCadenceDriver driver,
    required DreamWindowSchedule schedule,
    DateTime Function() now = DateTime.now,
    Duration heartbeat = const Duration(minutes: 1),
    void Function(Object error, StackTrace stack)? onTickError,
  })  : _driver = driver,
        _schedule = schedule,
        _now = now {
    _loop = DreamCadenceLoop(
      driver: driver,
      heartbeat: heartbeat,
      shouldTick: () => isDreamingActive(),
      onTickError: onTickError,
    );
  }

  final DreamCadenceDriver _driver;
  final DreamWindowSchedule _schedule;
  final DateTime Function() _now;

  late final DreamCadenceLoop _loop;

  DreamModeKind _baseMode = DreamModeKind.scheduled;
  DateTime? _manualUntil;

  /// Whether the heartbeat loop is currently running.
  bool get isRunning => _loop.isRunning;

  /// The configured cadence lanes (read-only), for the `/dream_status` surface
  /// to render each lane's interval and agents even before any run.
  CadenceSchedule get cadenceSchedule => _driver.schedule;

  /// The configured daily dream windows (read-only), for the `/dream_status`
  /// surface to render the allowed time-slots.
  DreamWindowSchedule get windowSchedule => _schedule;

  /// Starts the gated heartbeat. Idempotent.
  void start() => _loop.start();

  /// Stops the heartbeat. Idempotent. Any in-flight tick runs to completion.
  Future<void> stop() => _loop.stop();

  /// Whether dreaming may fire as of [at] (default: the current local time).
  ///
  /// An open manual window admits dreaming regardless of the base mode; once it
  /// lapses the decision falls back to the base mode:
  ///   * `suspended` → never;
  ///   * `scheduled` → whether [at] falls in any configured window.
  bool isDreamingActive([DateTime? at]) {
    final instant = at ?? _now();
    final manual = _manualUntil;
    if (manual != null) {
      if (instant.isBefore(manual)) {
        return true;
      }
      // The manual window lapsed: drop it and fall back to the base mode.
      _manualUntil = null;
    }
    switch (_baseMode) {
      case DreamModeKind.suspended:
        return false;
      case DreamModeKind.scheduled:
        return _schedule.isActiveAt(instant);
    }
  }

  /// Opens a manual dreaming window for [period] and fires one immediate
  /// out-of-band all-lanes pass (item c — `/dream_now`).
  ///
  /// The window admits dreaming regardless of the base mode for [period]; the
  /// immediate pass is fired through [DreamCadenceDriver.tickManual], so it
  /// neither counts toward the scheduled-repeat cap nor changes the base mode
  /// (it "must not imply a start").
  Future<void> dreamNow(Duration period) async {
    _manualUntil = _now().add(period);
    await _driver.tickManual();
  }

  /// Resumes normal scheduled dreaming and re-arms the schedule
  /// (item c — `/dream_start`): the base mode returns to [DreamModeKind.scheduled]
  /// and the scheduled-repeat tally is cleared and re-baselined, so a cadence
  /// that had reached [DreamCadenceDriver.maxRepeatCount] fires afresh.
  void startNormal() {
    _baseMode = DreamModeKind.scheduled;
    _driver.resetScheduledRunCounts();
    _driver.rebaseline();
  }

  /// Stops normal scheduled dreaming (item c — `/dream_stop`): the base mode
  /// becomes [DreamModeKind.suspended] and any open manual window is closed.
  void stopNormal() {
    _baseMode = DreamModeKind.suspended;
    _manualUntil = null;
  }

  /// [ToolDreamSurface] — "start dreaming for a period" maps onto a manual
  /// [dreamNow] window. Fired-and-forgotten because the tool surface is `void`;
  /// the immediate pass runs on its own microtask.
  @override
  void forceFor(Duration period) {
    unawaited(dreamNow(period));
  }

  /// [ToolDreamSurface] — "stop" maps onto [stopNormal].
  @override
  void suspend() => stopNormal();

  /// [ToolDreamSurface] — "resume" maps onto [startNormal].
  @override
  void resume() => startNormal();

  /// A snapshot of the current dreaming state (item c — "find out if the brain
  /// is currently dreaming"), enriched with the scheduled-repeat cap and the
  /// per-lane scheduled-run tally for the `/dream_status` surface.
  DreamStatus status() => DreamStatus(
        mode: _baseMode,
        active: isDreamingActive(),
        running: isRunning,
        alwaysActive: _schedule.isAlwaysActive,
        manualUntil: _manualUntil,
        maxRepeatCount: _driver.maxRepeatCount,
        laneRunCounts: _laneRunCounts(),
      );

  /// The current per-lane scheduled-run tally, keyed by lane id.
  Map<String, int> _laneRunCounts() {
    final counts = <String, int>{};
    for (final lane in _driver.schedule.lanes) {
      counts[lane.id] = _driver.scheduledRunCount(lane.id);
    }
    return counts;
  }

  /// The [ToolDreamSurface] read the `dream.control` tool returns for every
  /// action — the [status] snapshot as a JSON-native map.
  @override
  Map<String, Object?> dreamStatus() => status().toMap();
}
