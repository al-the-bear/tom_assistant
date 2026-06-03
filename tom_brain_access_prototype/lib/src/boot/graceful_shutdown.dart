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

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';

// The generic signal → awaited-teardown → terminate machinery now lives in
// `tom_core_agentic`'s `AsyncShutdownCoordinator` (the Section-G consolidation:
// it is the same coordinator any running agentic process needs, not anything
// brain-specific). `GracefulShutdown` is the thin, brain-shaped wrapper around
// it — it pins the trigger type to `ProcessSignal`, supplies the `SIGINT` /
// `SIGTERM` default signal set and the real-process `exit` terminator, and
// tags the lifecycle log lines with the access layer's label. The teardown
// (`ShutdownAction`) is still the spec's § 11.2 sequence the caller injects
// (`BootedBrain.shutdown` in the running process; a probe in a test).
//
// `ShutdownAction`, `ProcessTerminator`, `shutdownExitOk`, and
// `shutdownExitError` are re-exported from `tom_core_agentic` so this file
// remains the single import for boot's barrel (`boot.dart`) and the E.42
// tests — the names and meanings are unchanged, only their home moved.

export 'package:tom_core_agentic/tom_core_agentic.dart'
    show ProcessTerminator, ShutdownAction, shutdownExitError, shutdownExitOk;

/// The label the access layer's graceful-shutdown lifecycle log lines carry.
const String _shutdownLabel = 'tom_brain.access.shutdown';

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
/// A `ProcessSignal`-shaped wrapper over the generic
/// [AsyncShutdownCoordinator]: it supplies the `SIGINT` / `SIGTERM` default
/// signal set, the real-process `exit` terminator, and the access layer's log
/// label, and otherwise delegates the first-signal-wins gating, the awaited
/// teardown, and the terminate to the shared coordinator.
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
  final AsyncShutdownCoordinator<ProcessSignal> _coordinator;

  GracefulShutdown._(this._coordinator);

  /// Whether a signal has already begun the shutdown sequence. Once `true`,
  /// further signals are ignored.
  bool get isTriggered => _coordinator.isTriggered;

  /// Resolves with the exit code once the teardown has run (after the first
  /// signal). [shutdownExitOk] on a clean teardown, [shutdownExitError] if the
  /// [ShutdownAction] threw. Never resolves if no signal ever arrives.
  ///
  /// In the running process the [ProcessTerminator] is the real [exit], so
  /// nothing observes this future; a test injects a no-op / recording
  /// terminator and awaits this to assert the sequence ran.
  Future<int> get completed => _coordinator.completed;

  /// The default termination signals for the running process: `SIGINT`
  /// (Ctrl-C / `kill -INT`) and `SIGTERM` (`kill`, container stop, systemd
  /// stop). A test injects its own `StreamController` streams instead.
  static List<Stream<ProcessSignal>> defaultSignals() =>
      <Stream<ProcessSignal>>[
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
    return GracefulShutdown._(
      AsyncShutdownCoordinator.install<ProcessSignal>(
        label: _shutdownLabel,
        onShutdown: onShutdown,
        signals: signals ?? defaultSignals(),
        terminate: terminate,
      ),
    );
  }

  /// Stops listening for signals without triggering a shutdown. For a test
  /// teardown or for an embedding context that manages its own lifecycle.
  /// Idempotent and safe in a `finally`.
  Future<void> dispose() => _coordinator.dispose();
}
