// `PreemptionController` — the supervising observer over the coordinator's
// two run slots (Plan step D.23;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// The `RunCoordinator` (D.18–D.21) owns the *mechanics*: it is the single
// writer of the shared `PreemptionState`, it admits and force-yields runs,
// and it drives the FIFO foreground queue. The controller never touches any
// of that — it is strictly observe-only. Its job is to maintain a small
// supervisory model of the coordinator's state (which slots are occupied;
// whether a foreground preemption is pending) and emit a typed
// [PreemptionEvent] on every *transition* of that model, so an operator (the
// Tom Forge run inspector), a trail recorder, or a test can watch the
// preemption state machine move without polling the coordinator and without
// becoming a second writer of `PreemptionState`.
//
// ── The seam (D.23 standalone; wired in D.24) ───────────────────────
//
// D.23 ships the controller as a standalone supervisor with a `record*`
// surface and an event stream; D.24 wires the coordinator to call these
// `record*` methods at each of its transition points (run start, run finish,
// preemption request, resume signal). Keeping the surface a set of plain
// `record*` callbacks — the same shape as the dispatcher entry observer
// (`dispatcher_entry.dart`) — lets the controller be observed and tested in
// isolation today, and lets D.24 connect it without changing the
// coordinator's submission signatures.
//
// ── Idempotency mirrors `PreemptionState` ───────────────────────────
//
// `PreemptionState.requestForegroundPreemption` / `signalResume` are
// idempotent: a redundant request keeps the existing resume signal, a resume
// with nothing pending is a no-op. The coordinator therefore calls them more
// than once per real transition (back-to-back foreground arrivals during one
// background run all call `requestForegroundPreemption`). The controller
// mirrors that idempotency on *its* model: it emits
// [ForegroundPreemptionRequested] only on the false→true edge and
// [BackgroundResumeSignalled] only on the true→false edge, so the event
// stream reflects true transitions, not redundant calls. This is supervision
// of the controller's own derived model — it is not a second write of
// `PreemptionState`.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show defaultNowUtc;
import 'package:tom_core_agentic/tom_core_agentic.dart' show CloseGuard;

import 'preemption_event.dart';
import 'run_coordinator.dart' show RunSlot;

/// Clock seam the controller stamps onto every emitted event's `occurredAt`.
///
/// Must return a UTC `DateTime` (`BrainEvent.toJson` asserts the invariant).
/// Injectable so a test can stamp deterministic timestamps instead of the
/// wall clock.
typedef PreemptionClock = DateTime Function();

/// The supervising observer over the coordinator's two run slots (D.23).
///
/// Construct one per coordinator. The coordinator (wired in D.24) calls the
/// `record*` methods at each transition point; consumers subscribe to
/// [events] to watch the preemption state machine. The controller holds no
/// reference to the coordinator and never mutates `PreemptionState`.
///
/// Lifecycle: the `record*` methods are legal up until [close]; after [close]
/// they throw `StateError` and [events] subscribers receive a done-stream —
/// the same lifecycle contract as `EngineEventBus` (C.44). The closed-flag and
/// use-after-close guard come from the shared [CloseGuard] mixin (E.1) so the
/// lifecycle dance is not re-hand-rolled here.
final class PreemptionController with CloseGuard {
  /// Builds a controller over an optional [clock] (default: the UTC wall
  /// clock).
  PreemptionController({PreemptionClock? clock}) : _clock = clock ?? defaultNowUtc;

  final PreemptionClock _clock;

  /// Backing broadcast controller. `sync: false` (the default, named for
  /// visibility) so a slow subscriber never stalls a coordinator transition —
  /// the same posture as `EngineEventBus`.
  final StreamController<PreemptionEvent> _controller =
      StreamController<PreemptionEvent>.broadcast(sync: false);

  bool _foregroundOccupied = false;
  bool _backgroundOccupied = false;
  bool _preemptionPending = false;

  /// Whether the controller currently models the foreground slot as occupied.
  bool get isForegroundOccupied => _foregroundOccupied;

  /// Whether the controller currently models the background slot as occupied.
  bool get isBackgroundOccupied => _backgroundOccupied;

  /// Whether the controller currently models a foreground preemption as
  /// pending (a foreground arrival has asked the background to yield and no
  /// resume has been signalled yet).
  bool get isPreemptionPending => _preemptionPending;

  /// The typed event stream. Broadcast — multiple subscribers see every
  /// event; missed events stay missed (observability, not a durable queue).
  Stream<PreemptionEvent> events() => _controller.stream;

  /// Records that a run began occupying [slot]; emits [RunSlotEntered].
  ///
  /// Called by the coordinator the moment it starts a body in a slot — never
  /// for a rejected or still-queued submission.
  void recordRunStarted(RunSlot slot, {String? runId, String? causedBy}) {
    ensureOpen('PreemptionController.recordRunStarted');
    _setOccupied(slot, true);
    _emit(RunSlotEntered(
      occurredAt: _clock(),
      runId: runId,
      causedBy: causedBy,
      slot: slot,
    ));
  }

  /// Records that the run in [slot] finished with [outcome], freeing the slot;
  /// emits [RunSlotExited].
  ///
  /// Called by the coordinator at every completion point — a clean return
  /// ([RunSlotOutcome.completed]), a thrown error
  /// ([RunSlotOutcome.failed]), or a hard-deadline force-yield
  /// ([RunSlotOutcome.forceYielded]).
  void recordRunFinished(
    RunSlot slot,
    RunSlotOutcome outcome, {
    String? runId,
    String? causedBy,
  }) {
    ensureOpen('PreemptionController.recordRunFinished');
    _setOccupied(slot, false);
    _emit(RunSlotExited(
      occurredAt: _clock(),
      runId: runId,
      causedBy: causedBy,
      slot: slot,
      outcome: outcome,
    ));
  }

  /// Records that a foreground arrival asked the live background run to yield.
  ///
  /// Idempotent (mirrors `PreemptionState`): emits
  /// [ForegroundPreemptionRequested] only on the transition into the waiting
  /// state. A redundant call while a preemption is already pending is a no-op
  /// and emits nothing.
  void recordForegroundPreemptionRequested({String? runId, String? causedBy}) {
    ensureOpen('PreemptionController.recordForegroundPreemptionRequested');
    if (_preemptionPending) {
      return;
    }
    _preemptionPending = true;
    _emit(ForegroundPreemptionRequested(
      occurredAt: _clock(),
      runId: runId,
      causedBy: causedBy,
    ));
  }

  /// Records that the foreground workload drained and the parked background
  /// run was released.
  ///
  /// Idempotent (mirrors `PreemptionState`): emits [BackgroundResumeSignalled]
  /// only on the transition out of the waiting state. A call with no
  /// preemption pending is a no-op and emits nothing.
  void recordBackgroundResumeSignalled({String? runId, String? causedBy}) {
    ensureOpen('PreemptionController.recordBackgroundResumeSignalled');
    if (!_preemptionPending) {
      return;
    }
    _preemptionPending = false;
    _emit(BackgroundResumeSignalled(
      occurredAt: _clock(),
      runId: runId,
      causedBy: causedBy,
    ));
  }

  /// Closes the controller.
  ///
  /// Subsequent `record*` calls throw `StateError`; live subscribers receive a
  /// done event and any `await for` over [events] terminates. Idempotent (the
  /// [CloseGuard.markClosed] transition short-circuits a second call).
  Future<void> close() async {
    if (!markClosed()) {
      return;
    }
    await _controller.close();
  }

  void _setOccupied(RunSlot slot, bool occupied) {
    switch (slot) {
      case RunSlot.foreground:
        _foregroundOccupied = occupied;
      case RunSlot.background:
        _backgroundOccupied = occupied;
    }
  }

  void _emit(PreemptionEvent event) => _controller.add(event);
}
