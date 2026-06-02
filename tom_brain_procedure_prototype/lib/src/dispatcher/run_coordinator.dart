// Foreground / background run coordinator (Plan step D.18;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// The fourth stage of the dispatcher's `accept → classify → select →
// schedule` pipeline: the *schedule* stage. Selection (D.16) resolves a
// procedure id; the coordinator owns *which* runs are allowed to be live at
// once and *when* a submitted run actually executes.
//
// ── What D.18 owns ──────────────────────────────────────────────────
//
// D.18 delivers the coordinator core only — the single-foreground /
// single-background *invariant* and the submission surface:
//
//   - At most one foreground run at a time (foreground = an inbound user
//     prompt being served).
//   - At most one background run at a time (background = scheduler-driven
//     free-time work).
//   - The shared [PreemptionState] the engine yields against, owned here so
//     the coordinator and the engine reference one object.
//
// ── What D.18 does NOT own (deferred, per the build order) ───────────
//
// The remaining D.5 substeps plug into this core without changing its
// submission signatures:
//
//   - D.19 — the FIFO foreground queue (configurable depth, default 4).
//     Until it lands, a second concurrent foreground submission is rejected
//     loudly with [RunSlotBusy] rather than silently dropped or run
//     concurrently (mirroring how D.16 rejects an unsupported kind loudly
//     before its capability exists). D.19 replaces that rejection with
//     enqueueing — per the no-backwards-compatibility principle, the busy
//     path is swapped wholesale, not kept as a fallback.
//   - D.20 — cooperative preemption: driving [PreemptionState] (setting the
//     foreground-waiting flag when a foreground arrives during a live
//     background run, signalling resume when the foreground finishes). D.18
//     *exposes* the state but does not yet drive it; the engine-native
//     `yield_if_foreground_waiting()` checkpoint already reads it.
//   - D.21 — the hard step deadline cross-check (the engine owns the
//     mechanism in `preemption/step_deadline.dart`; the coordinator-level
//     enforcement lands here later).
//   - D.23–D.25 — the supervising `PreemptionController` + its
//     `PreemptionEvent` stream.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

/// The two run slots the coordinator tracks (PE-5).
///
/// Exactly one run may occupy each slot at a time. `foreground` serves an
/// inbound user prompt; `background` serves scheduler-driven free-time work.
enum RunSlot {
  /// An inbound user prompt being served. At most one is live at a time.
  foreground,

  /// Scheduler-driven free-time work (dreaming, research, triage,
  /// authoring). At most one is live at a time.
  background,
}

/// The unit of work the coordinator schedules into a slot.
///
/// A run body is a thunk that, when invoked, performs the run and completes
/// with its result. The coordinator owns *when* the body runs and clearing
/// the slot when it finishes; the body owns *what* the run does (in
/// production, driving the [procedure engine]). Generic in the result type
/// so a caller awaits the run's own value, not an erased one.
typedef RunBody<T> = Future<T> Function();

/// Raised when a run is submitted into a slot that already holds a live run.
///
/// This is the D.18 enforcement of the single-foreground / single-background
/// invariant *before* the D.19 foreground queue exists: a second concurrent
/// submission fails loudly rather than running two runs in one slot or being
/// silently dropped. Once D.19 lands, foreground submissions queue instead
/// of raising this; a background double-submission stays an error (there is
/// no background queue).
final class RunSlotBusy implements Exception {
  /// Records which [slot] was already occupied when a run was submitted.
  const RunSlotBusy(this.slot);

  /// The slot that already held a live run.
  final RunSlot slot;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the ${slot.name} slot already holds a live run; '
      'the coordinator allows at most one ${slot.name} run at a time';

  @override
  String toString() => 'RunSlotBusy: $message';
}

/// The dispatcher's foreground / background run coordinator (Plan D.18;
/// spec § 10.3, PE-5).
///
/// Tracks at most one foreground and one background run, exposes
/// [submitForeground] / [submitBackground], and owns the shared
/// [preemption] state the engine yields against. A submitted run occupies
/// its slot from submission until its body completes (success *or* error);
/// the slot is cleared before the returned future resolves, so a caller that
/// awaits a submission observes the slot already free.
final class RunCoordinator {
  /// Builds a coordinator over a [preemption] state (default: a fresh
  /// [PreemptionState]).
  ///
  /// The state is injectable so the engine and the coordinator can be handed
  /// the *same* object — the coordinator drives the write side (from D.20),
  /// the engine's `yield_if_foreground_waiting()` checkpoint reads it.
  RunCoordinator({PreemptionState? preemption})
      : preemption = preemption ?? PreemptionState();

  /// The shared cooperative-preemption state the engine yields against.
  ///
  /// D.18 exposes it; D.20 begins driving it (setting the foreground-waiting
  /// flag on a foreground arrival during a live background run, signalling
  /// resume when the foreground finishes).
  final PreemptionState preemption;

  Future<void>? _foreground;
  Future<void>? _background;

  /// Whether a foreground run is currently live.
  bool get hasForegroundRun => _foreground != null;

  /// Whether a background run is currently live.
  bool get hasBackgroundRun => _background != null;

  /// Submits [body] as the foreground run.
  ///
  /// Throws [RunSlotBusy] synchronously if a foreground run is already live
  /// (until D.19's queue lands). Otherwise the body starts immediately, the
  /// foreground slot is marked occupied until the body completes, and the
  /// returned future carries the body's own result (or error).
  Future<T> submitForeground<T>(RunBody<T> body) =>
      _submit(RunSlot.foreground, body);

  /// Submits [body] as the background run.
  ///
  /// Throws [RunSlotBusy] synchronously if a background run is already live.
  /// Otherwise the body starts immediately, the background slot is marked
  /// occupied until the body completes, and the returned future carries the
  /// body's own result (or error).
  Future<T> submitBackground<T>(RunBody<T> body) =>
      _submit(RunSlot.background, body);

  Future<T> _submit<T>(RunSlot slot, RunBody<T> body) {
    if (_isOccupied(slot)) {
      throw RunSlotBusy(slot);
    }
    final completer = Completer<T>();
    // Mark the slot occupied *before* invoking the body, so a re-entrant
    // submission from inside the body sees the slot busy rather than racing.
    _occupy(slot, completer.future);
    Future<T>.sync(body).then(
      (value) {
        _release(slot);
        completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _release(slot);
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  bool _isOccupied(RunSlot slot) => switch (slot) {
        RunSlot.foreground => _foreground != null,
        RunSlot.background => _background != null,
      };

  void _occupy(RunSlot slot, Future<void> run) {
    switch (slot) {
      case RunSlot.foreground:
        _foreground = run;
      case RunSlot.background:
        _background = run;
    }
  }

  void _release(RunSlot slot) {
    switch (slot) {
      case RunSlot.foreground:
        _foreground = null;
      case RunSlot.background:
        _background = null;
    }
  }
}
