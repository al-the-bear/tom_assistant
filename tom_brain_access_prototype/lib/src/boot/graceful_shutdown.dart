// GracefulShutdown — termination-signal handling for the running access
// process (E.42; proto spec § 11.2). Mirrors D.45's shutdown orchestration.
//
// Plan step E.42 (verbatim): "Implement graceful shutdown via `tom_basics`'
// signal handling: stop accepting new connections, drain in-flight foreground,
// close memory cleanly."
//
// ── What E.42 owns ───────────────────────────────────────────────────
//
// E.42 is the bridge between an OS termination signal (SIGINT / SIGTERM) and
// the *async* process teardown. The teardown itself already exists: phase D's
// `BootedBrain.shutdown` runs exactly the spec's sequence — stop the access
// layer (no new inbound `Access` arrives) → drain the coordinator (the
// in-flight foreground run, plus everything queued behind it, runs to its
// natural end so each `RunRecorder` closes its trail) → dispose memory
// (flush + WAL checkpoint) → close the substrate. So E.42 does not *re-implement*
// the drain; it wires a signal to it and guarantees the drain completes before
// the process exits.
//
// ── Why a purpose-built async coordinator, not `tom_basics` /
//    `TomShutdownCleanup` ──────────────────────────────────────────────
//
// The plan names "`tom_basics`' signal handling", but `tom_basics` exposes no
// signal-handling surface (it ships `tomLog`, the platform/runtime helpers,
// and the exception base — nothing that watches `ProcessSignal`). The closest
// workspace facility is `tom_core_kernel`'s `TomShutdownCleanup`, but its
// handler model is *synchronous* fire-and-forget (`void Function(ProcessSignal)`
// over `close()` / `dispose()`): it cannot *await* an async drain, so it would
// race the process exit and drop the very in-flight foreground work the spec
// requires us to drain. It also auto-watches signals from a global singleton at
// import time, which is hostile to a deterministic test. So E.42 implements a
// small async coordinator here that (a) awaits the async teardown to completion
// before terminating, (b) takes its signal streams and its process-terminator
// as injectable seams so a test drives the whole sequence with no real signal
// and no real `exit`, and (c) uses `tomLog` (the one genuine `tom_basics` touch
// point) for the lifecycle lines. This deviation is logged in the questions doc.
//
// ── Decoupling from `BootedBrain` ────────────────────────────────────
//
// This coordinator does not import `BootedBrain` (or anything from
// `tom_brain_procedure_prototype`). It takes the teardown as a
// `Future<void> Function()` ([ShutdownAction]) seam. The running process
// (E.45) passes `bootedBrain.shutdown` as that action; a test passes a probe.
// Keeping the dependency at a function boundary makes E.42 testable in
// isolation and keeps the access layer from reaching past the dispatcher.

import 'dart:async';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart';

/// The async teardown a [GracefulShutdown] runs when a termination signal
/// arrives.
///
/// In the running brain process (E.45) this is `BootedBrain.shutdown`, which
/// stops the access layer, drains the in-flight foreground run, disposes
/// memory, and closes the substrate — the spec's § 11.2 sequence. A test
/// passes a probe that records its invocation and ordering.
typedef ShutdownAction = Future<void> Function();

/// Terminates the process with [code]. Defaults to `dart:io`'s [exit]
/// (via [_ioExit]); a test injects a recorder so the process survives the
/// assertion.
typedef ProcessTerminator = void Function(int code);

/// Exit code for a clean graceful shutdown (the teardown completed without
/// throwing).
const int shutdownExitOk = 0;

/// Exit code when the teardown threw (`EX_SOFTWARE`, the conventional
/// "internal software error" code). The process still exits — a failed drain
/// must not hold the process open — but the non-zero code surfaces the failure
/// to a supervisor.
const int shutdownExitError = 70;

/// The default [ProcessTerminator]: terminate the real process.
///
/// A wrapper rather than a bare `exit` tear-off so the parameter type stays
/// the plain `void Function(int)` ([ProcessTerminator]) — `exit` is
/// `Never Function(int)`, which is assignable but reads less clearly as a
/// default.
void _ioExit(int code) => exit(code);

/// Watches OS termination signals and runs an async process teardown to
/// completion before the process exits (E.42; proto spec § 11.2).
///
/// Construct via [GracefulShutdown.install], which subscribes to the signal
/// streams immediately. The *first* signal wins: it flips [isTriggered], runs
/// [ShutdownAction] to completion (logging start and finish), and then calls
/// the [ProcessTerminator]. Any further signal that arrives while the teardown
/// is in flight is logged and ignored — a second Ctrl-C does not interrupt a
/// drain in progress. [completed] resolves with the chosen exit code once the
/// teardown has run (so a test can await the whole sequence without a real
/// `exit`).
class GracefulShutdown {
  final ShutdownAction _onShutdown;
  final ProcessTerminator _terminate;
  final List<StreamSubscription<ProcessSignal>> _subscriptions =
      <StreamSubscription<ProcessSignal>>[];
  final Completer<int> _completed = Completer<int>();
  bool _triggered = false;

  GracefulShutdown._(this._onShutdown, this._terminate);

  /// Whether a signal has already begun the shutdown sequence. Once `true`,
  /// further signals are ignored.
  bool get isTriggered => _triggered;

  /// Resolves with the exit code once the teardown has run (after the first
  /// signal). [shutdownExitOk] on a clean teardown, [shutdownExitError] if the
  /// [ShutdownAction] threw. Never resolves if no signal ever arrives.
  ///
  /// In the running process the [ProcessTerminator] is the real [exit], so
  /// nothing observes this future; a test injects a no-op / recording
  /// terminator and awaits this to assert the sequence ran.
  Future<int> get completed => _completed.future;

  /// The default termination signals for the running process: `SIGINT`
  /// (Ctrl-C / `kill -INT`) and `SIGTERM` (`kill`, container stop, systemd
  /// stop). A test injects its own `StreamController` streams instead.
  static List<Stream<ProcessSignal>> defaultSignals() => <Stream<ProcessSignal>>[
        ProcessSignal.sigint.watch(),
        ProcessSignal.sigterm.watch(),
      ];

  /// Installs a graceful-shutdown coordinator and starts listening for
  /// termination signals.
  ///
  /// [onShutdown] is the async teardown run on the first signal (the running
  /// process passes `bootedBrain.shutdown`). [signals] defaults to
  /// [defaultSignals] (`SIGINT` + `SIGTERM`); a test injects controllers it
  /// drives. [terminate] defaults to the real [exit]; a test injects a
  /// recorder so the process survives.
  static GracefulShutdown install({
    required ShutdownAction onShutdown,
    List<Stream<ProcessSignal>>? signals,
    ProcessTerminator terminate = _ioExit,
  }) {
    final GracefulShutdown coordinator =
        GracefulShutdown._(onShutdown, terminate);
    final List<Stream<ProcessSignal>> streams = signals ?? defaultSignals();
    for (final Stream<ProcessSignal> stream in streams) {
      coordinator._subscriptions.add(stream.listen(coordinator._onSignal));
    }
    return coordinator;
  }

  /// First signal wins: begin the async teardown. A signal that arrives while
  /// the teardown is already in flight is logged and ignored.
  void _onSignal(ProcessSignal signal) {
    if (_triggered) {
      tomLog.status(
        '[tom_brain.access.shutdown] $signal received while already '
        'shutting down — ignored',
      );
      return;
    }
    _triggered = true;
    // Fire-and-forget the async teardown; `_runShutdown` owns its own errors
    // and resolves `completed`. The handler itself must stay synchronous so a
    // burst of signals all hit the `_triggered` guard.
    unawaited(_runShutdown(signal));
  }

  /// Runs the teardown to completion, then terminates. Stops listening for
  /// further signals first (so a late signal cannot re-enter), awaits
  /// [_onShutdown], resolves [completed] with the exit code, and calls the
  /// [ProcessTerminator] last.
  Future<void> _runShutdown(ProcessSignal signal) async {
    tomLog.status(
      '[tom_brain.access.shutdown] $signal received — stop accepting '
      'connections, draining in-flight foreground, closing memory',
    );
    await _cancelSubscriptions();
    int code = shutdownExitOk;
    try {
      await _onShutdown();
      tomLog.status('[tom_brain.access.shutdown] graceful shutdown complete');
    } catch (error, stackTrace) {
      code = shutdownExitError;
      tomLog.severe(
        '[tom_brain.access.shutdown] shutdown action failed: $error\n'
        '$stackTrace',
      );
    }
    if (!_completed.isCompleted) {
      _completed.complete(code);
    }
    _terminate(code);
  }

  /// Cancels and clears the signal subscriptions. Idempotent.
  Future<void> _cancelSubscriptions() async {
    final List<StreamSubscription<ProcessSignal>> subscriptions =
        List<StreamSubscription<ProcessSignal>>.of(_subscriptions);
    _subscriptions.clear();
    for (final StreamSubscription<ProcessSignal> subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Stops listening for signals without triggering a shutdown. For a test
  /// teardown or for an embedding context that manages its own lifecycle.
  /// Idempotent and safe in a `finally`.
  Future<void> dispose() => _cancelSubscriptions();
}
