// Foreground / background run coordinator (Plan steps D.18, D.19;
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
// D.18 delivers the coordinator core — the single-foreground /
// single-background *invariant* and the submission surface:
//
//   - At most one foreground run at a time (foreground = an inbound user
//     prompt being served).
//   - At most one background run at a time (background = scheduler-driven
//     free-time work).
//   - The shared [PreemptionState] the engine yields against, owned here so
//     the coordinator and the engine reference one object.
//
// ── What D.19 adds ──────────────────────────────────────────────────
//
// D.19 fills the FIFO foreground queue *behind* the same
// [submitForeground] signature. When the foreground slot is busy a
// submission no longer fails loudly — it is enqueued (configurable depth,
// default 4) and started, in submission order, as soon as the running
// foreground frees the slot. Only when the queue is *also* at capacity does
// a foreground submission fail, and then with [ForegroundQueueFull] (an
// overflow / backpressure signal), not [RunSlotBusy]. Per the
// no-backwards-compatibility principle the old busy-foreground rejection is
// swapped wholesale, not kept as a fallback.
//
// The background slot stays single — there is no background queue, so a
// second concurrent background submission still fails loudly with
// [RunSlotBusy].
//
// ── What the coordinator does NOT own yet (deferred) ────────────────
//
// The remaining D.5 substeps plug into this core without changing its
// submission signatures:
//
//   - D.20 — cooperative preemption: driving [PreemptionState] (setting the
//     foreground-waiting flag when a foreground arrives during a live
//     background run, signalling resume when the foreground finishes). The
//     coordinator *exposes* the state but does not yet drive it; the
//     engine-native `yield_if_foreground_waiting()` checkpoint already reads
//     it.
//   - D.21 — the hard step deadline cross-check (the engine owns the
//     mechanism in `preemption/step_deadline.dart`; the coordinator-level
//     enforcement lands here later).
//   - D.23–D.25 — the supervising `PreemptionController` + its
//     `PreemptionEvent` stream.

import 'dart:async';
import 'dart:collection';

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

/// Raised when a run is submitted into a slot that already holds a live run
/// *and* that slot has no queue to absorb it.
///
/// Since D.19 this applies to the **background** slot only: there is no
/// background queue, so a second concurrent background submission fails
/// loudly rather than running two background runs at once. The foreground
/// slot no longer raises this — a busy foreground slot enqueues the
/// submission (and signals [ForegroundQueueFull] only on overflow).
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

/// Raised when a foreground submission arrives while the foreground slot is
/// busy *and* the FIFO foreground queue is already at capacity (D.19).
///
/// This is the queue's backpressure / overflow signal: the running
/// foreground run plus [depth] queued runs are the most the coordinator will
/// hold. A caller that hits this should shed load (reject the inbound, ask
/// the user to retry) rather than grow the queue unbounded. The background
/// slot has no queue and so signals [RunSlotBusy] instead, never this.
final class ForegroundQueueFull implements Exception {
  /// Records the foreground queue [depth] that was already full when the
  /// rejected submission arrived.
  const ForegroundQueueFull(this.depth);

  /// The configured foreground queue depth (max waiting runs) at the time
  /// of rejection.
  final int depth;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the foreground queue is full (depth $depth); the running foreground '
      'run plus $depth queued runs are the most the coordinator holds';

  @override
  String toString() => 'ForegroundQueueFull: $message';
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
  /// [PreemptionState]) with a FIFO foreground queue of
  /// [foregroundQueueDepth] waiting runs (default 4).
  ///
  /// The preemption state is injectable so the engine and the coordinator can
  /// be handed the *same* object — the coordinator drives the write side
  /// (from D.20), the engine's `yield_if_foreground_waiting()` checkpoint
  /// reads it.
  ///
  /// [foregroundQueueDepth] is the maximum number of foreground runs that may
  /// *wait* behind the running one; it excludes the run currently occupying
  /// the slot. A depth of 0 disables queueing entirely (a busy foreground
  /// slot then overflows immediately). Throws [ArgumentError] if negative.
  RunCoordinator({PreemptionState? preemption, this.foregroundQueueDepth = 4})
      : preemption = preemption ?? PreemptionState() {
    if (foregroundQueueDepth < 0) {
      throw ArgumentError.value(
        foregroundQueueDepth,
        'foregroundQueueDepth',
        'must be zero or greater',
      );
    }
  }

  /// The shared cooperative-preemption state the engine yields against.
  ///
  /// D.18 exposes it; D.20 begins driving it (setting the foreground-waiting
  /// flag on a foreground arrival during a live background run, signalling
  /// resume when the foreground finishes).
  final PreemptionState preemption;

  /// The maximum number of foreground runs that may wait behind the running
  /// one in the FIFO queue (excludes the run occupying the slot, D.19).
  final int foregroundQueueDepth;

  /// FIFO queue of foreground starters waiting for the slot to free up. Each
  /// starter, when invoked, re-occupies the foreground slot and runs its body
  /// (completing the original caller's future). Bounded by
  /// [foregroundQueueDepth]; overflow raises [ForegroundQueueFull].
  final Queue<void Function()> _foregroundQueue = Queue<void Function()>();

  Future<void>? _foreground;
  Future<void>? _background;

  /// Whether a foreground run is currently live (occupying the slot).
  bool get hasForegroundRun => _foreground != null;

  /// Whether a background run is currently live.
  bool get hasBackgroundRun => _background != null;

  /// The number of foreground runs currently waiting in the FIFO queue
  /// (excludes the run occupying the slot, D.19).
  int get foregroundQueueLength => _foregroundQueue.length;

  /// Submits [body] as a foreground run (D.18 surface, D.19 queue).
  ///
  /// If the foreground slot is free the body starts immediately. If it is
  /// busy the submission is enqueued FIFO and started, in submission order,
  /// as soon as the running foreground frees the slot. Throws
  /// [ForegroundQueueFull] synchronously only when the slot is busy *and* the
  /// queue is already at [foregroundQueueDepth]. The returned future carries
  /// the body's own result (or error) whenever the run eventually executes.
  Future<T> submitForeground<T>(RunBody<T> body) {
    final completer = Completer<T>();
    void start() => _runInForegroundSlot(body, completer);

    if (_foreground == null) {
      // Slot free: start immediately.
      start();
    } else if (_foregroundQueue.length >= foregroundQueueDepth) {
      // Slot busy and the queue is full: overflow.
      throw ForegroundQueueFull(foregroundQueueDepth);
    } else {
      // Slot busy with queue capacity: wait FIFO behind the running run.
      _foregroundQueue.add(start);
    }
    return completer.future;
  }

  /// Submits [body] as the background run.
  ///
  /// Throws [RunSlotBusy] synchronously if a background run is already live —
  /// there is no background queue. Otherwise the body starts immediately, the
  /// background slot is marked occupied until the body completes, and the
  /// returned future carries the body's own result (or error).
  Future<T> submitBackground<T>(RunBody<T> body) {
    if (_background != null) {
      throw const RunSlotBusy(RunSlot.background);
    }
    final completer = Completer<T>();
    final marker = Completer<void>();
    // Mark the slot occupied *before* invoking the body, so a re-entrant
    // submission from inside the body sees the slot busy rather than racing.
    _background = marker.future;
    Future<T>.sync(body).then(
      (value) {
        _background = null;
        marker.complete();
        completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _background = null;
        marker.complete();
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  /// Occupies the foreground slot with [body], completing [completer] with
  /// the body's result, then pumps the next queued foreground run (if any).
  void _runInForegroundSlot<T>(RunBody<T> body, Completer<T> completer) {
    final marker = Completer<void>();
    _foreground = marker.future;
    Future<T>.sync(body).then(
      (value) {
        _foreground = null;
        marker.complete();
        completer.complete(value);
        _pumpForegroundQueue();
      },
      onError: (Object error, StackTrace stackTrace) {
        _foreground = null;
        marker.complete();
        completer.completeError(error, stackTrace);
        _pumpForegroundQueue();
      },
    );
  }

  /// Starts the next waiting foreground run, re-occupying the freed slot.
  ///
  /// Runs synchronously on the just-freed slot, so the slot moves directly
  /// from the finished run to the next queued one within a single event-loop
  /// turn — a queued run never observes a gap where the slot is free but a
  /// successor is waiting.
  void _pumpForegroundQueue() {
    if (_foreground != null || _foregroundQueue.isEmpty) {
      return;
    }
    _foregroundQueue.removeFirst()();
  }
}
