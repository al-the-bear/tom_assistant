// Production wiring for the scheduled dream cadence driver (Todo 10, G-M3).
//
// `dream_cadence_driver.dart` holds the *pure* timing driver — it reads a
// `Clock`, decides which lanes are due, and calls a [MaintenanceFire] seam. It
// carries no procedure / coordinator dependency on purpose (that is what keeps
// the G-S2 "no new embedding call site" argument clean and the driver trivially
// testable).
//
// This file lands the two pieces that bind that pure driver to the real running
// process:
//
//   * [fireThroughScheduler] — the [MaintenanceFire] that submits each agent on
//     the background slot via `FreeTimeScheduler.triggerMaintenance`, mapping a
//     busy slot (`RunSlotBusy`) to `FireOutcome.deferred` so the lane retries
//     next tick instead of erroring.
//   * [DreamCadenceLoop] — the wall-clock heartbeat that pumps `driver.tick()`
//     on a `Timer.periodic`, with a re-entrancy guard so a slow tick never
//     overlaps the next beat, and a `stop()` for graceful teardown.

import 'dart:async';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show FreeTimeScheduler, RunSlotBusy;
import 'package:tom_brain_shared/tom_brain_shared.dart' show Clock, SystemClock;

import 'dream_cadence_driver.dart';
import 'dream_throttle.dart';

/// Builds a [MaintenanceFire] that fires each agent through [scheduler]'s
/// background slot.
///
/// `FreeTimeScheduler.triggerMaintenance` submits one engine-backed run on the
/// background slot and throws [RunSlotBusy] when a background run is already
/// live (at most one at a time, PE-5). This adapter maps that to
/// [FireOutcome.deferred] — the cadence driver reads it as "not run this tick"
/// and retries on the next heartbeat without losing the elapsed interval.
MaintenanceFire fireThroughScheduler(FreeTimeScheduler scheduler) {
  return (String procedureId) async {
    try {
      await scheduler.triggerMaintenance(procedureId);
      return FireOutcome.fired;
    } on RunSlotBusy {
      return FireOutcome.deferred;
    }
  };
}

/// Builds a production [DreamCadenceDriver] over [scheduler] (`memory_specifi`
/// `cation.md` § 9.7).
///
/// The driver fires the existing dream agent scripts on their cadence through
/// [scheduler]; [clock] defaults to the wall clock and [schedule] to the § 9.7
/// default lanes.
DreamCadenceDriver dreamCadenceDriverOverScheduler(
  FreeTimeScheduler scheduler, {
  Clock clock = const SystemClock(),
  CadenceSchedule? schedule,
  DreamThrottle? throttle,
}) =>
    DreamCadenceDriver(
      clock: clock,
      fire: fireThroughScheduler(scheduler),
      schedule: schedule,
      throttle: throttle,
    );

/// The wall-clock heartbeat that drives a [DreamCadenceDriver]
/// (`memory_specification.md` § 9.7).
///
/// The driver decides *which* lanes are due; this loop decides *how often* it is
/// asked. Each beat calls [DreamCadenceDriver.tick]; a [heartbeat] finer than
/// the fastest lane's interval just means a due lane fires on the first beat
/// after its interval elapses (the driver never double-fires within an
/// interval). The loop is idempotent on [start] / [stop] and guards against a
/// slow tick overlapping the next beat.
final class DreamCadenceLoop {
  /// Builds a loop that pumps [driver] every [heartbeat] (default one minute —
  /// finer than the fast lane's 5-minute default so a due fast pass fires
  /// within a heartbeat of becoming due).
  ///
  /// [shouldTick] is the per-beat gate (item b): when supplied and it returns
  /// `false`, the beat skips `driver.tick()` entirely — the heartbeat keeps
  /// running but no lane is even *considered* due. The [DreamController] passes
  /// its window/mode test here so dreaming only fires inside a configured
  /// time-slot. A `null` gate (the default) means "always tick", the behaviour
  /// before item b.
  DreamCadenceLoop({
    required this.driver,
    this.heartbeat = const Duration(minutes: 1),
    bool Function()? shouldTick,
    void Function(Object error, StackTrace stack)? onTickError,
  })  : _shouldTick = shouldTick,
        _onTickError = onTickError;

  /// The cadence driver this loop pumps.
  final DreamCadenceDriver driver;

  /// How often [DreamCadenceDriver.tick] is called.
  final Duration heartbeat;

  final bool Function()? _shouldTick;

  final void Function(Object error, StackTrace stack)? _onTickError;

  Timer? _timer;
  bool _ticking = false;

  /// Whether the loop is currently running.
  bool get isRunning => _timer != null;

  /// Starts pumping. Idempotent — a second call while running is a no-op.
  void start() {
    _timer ??= Timer.periodic(heartbeat, (_) => unawaited(_pump()));
  }

  /// Stops pumping. Idempotent. Any in-flight tick runs to completion; no new
  /// tick starts after this returns.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  /// One heartbeat: pump the driver unless a previous tick is still running
  /// (a slow background pass must never let two ticks overlap) or the [_shouldTick]
  /// gate closes this beat (item b — outside a configured dream window).
  Future<void> _pump() async {
    if (_ticking) {
      return;
    }
    if (_shouldTick != null && !_shouldTick()) {
      return;
    }
    _ticking = true;
    try {
      await driver.tick();
    } catch (error, stack) {
      // A dream pass failing must not kill the heartbeat — log via the seam (or
      // swallow) and let the next beat try again. The agents' own trails carry
      // the failure detail; the loop only needs to stay alive.
      _onTickError?.call(error, stack);
    } finally {
      _ticking = false;
    }
  }
}
