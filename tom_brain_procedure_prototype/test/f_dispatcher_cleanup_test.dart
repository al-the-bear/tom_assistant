// Section F dispatcher-cleanup behavioural tests
// (`_ai/quests/tom_brain/prototype_review_result.md` § F).
//
// Section F is the post-implementation review of the Phase D dispatcher half.
// Most F findings were structural refactors that the existing D-suite already
// covers behaviourally (e.g. the D.18 / D.23 / D.45 suites still pass after the
// `_runInSlot`, `CloseGuard`, and derived-constant changes). This file adds the
// tests for the F findings that introduced *new* observable behaviour the
// D-suite did not pin:
//
//   - F.3.1 — `RunCoordinator.reserveBackground` / `BackgroundReservation`: the
//     atomic background-slot hold that closes the free-time scheduler's
//     time-of-check/time-of-use race. Reserve must mark the slot busy
//     synchronously, `submit` must run in the held slot, `cancel` must release
//     it, and a reservation must be settled exactly once.
//   - F.3.2 — `RunCoordinator.close`: closes the *owned* `PreemptionController`
//     (so its subscribers see the done-stream) but leaves an *injected* one
//     open (its lifecycle is the consumer's).
//   - F.3.3 — `SustainedFallbackMonitor` latch reset: a failed idea-push leaves
//     the fire latch clear, so the next edge in the still-sustained window
//     re-attempts rather than silently swallowing the alert and latching the
//     episode as already-sent.
//   - F.5.2 — `defaultShutdownDrainTimeout` derived from
//     `defaultCoordinatorHardStepDeadline`: the drain must outlast the
//     coordinator hard step deadline so the normal bound on a run is the
//     force-yield, not the drain.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        StackApi,
        StackEntry,
        TomBrainMemoryClient,
        TrailEntry,
        TrailOutcome;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        FallbackTrigger,
        PreemptionController,
        PreemptionEvent,
        ProcedureFallback,
        RunCoordinator,
        RunSlot,
        RunSlotBusy,
        SustainedFallbackMonitor,
        automationIdeasStackName,
        defaultCoordinatorDeadlineGrace,
        defaultCoordinatorHardStepDeadline,
        defaultShutdownDrainTimeout,
        defaultStepDeadline;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;

void main() {
  group('F.3.1 RunCoordinator.reserveBackground — atomic slot hold', () {
    test('a reservation marks the background slot busy synchronously', () {
      final coordinator = RunCoordinator();

      expect(coordinator.hasBackgroundRun, isFalse);
      final reservation = coordinator.reserveBackground();

      expect(reservation, isNotNull);
      // The slot is occupied the instant the reservation is taken — before any
      // body is built — so a concurrent admission attempt sees it busy.
      expect(coordinator.hasBackgroundRun, isTrue);
      reservation!.cancel();
    });

    test('a concurrent background submission during a reservation is rejected',
        () {
      final coordinator = RunCoordinator();
      final reservation = coordinator.reserveBackground();
      addTearDown(() => reservation?.cancel());

      // This is the race the reservation closes: between the scheduler checking
      // "is the slot free?" and submitting, a direct submitBackground must not
      // double-admit.
      expect(
        () => coordinator.submitBackground<int>(() async => 1),
        throwsA(isA<RunSlotBusy>()
            .having((e) => e.slot, 'slot', RunSlot.background)),
      );
    });

    test('a second reserveBackground during a live reservation returns null',
        () {
      final coordinator = RunCoordinator();
      final first = coordinator.reserveBackground();
      addTearDown(() => first?.cancel());

      expect(first, isNotNull);
      // A near-simultaneous tick must observe the slot busy and back off.
      expect(coordinator.reserveBackground(), isNull);
    });

    test('cancel releases the slot so a later run is admitted', () async {
      final coordinator = RunCoordinator();
      final reservation = coordinator.reserveBackground();

      reservation!.cancel();
      expect(coordinator.hasBackgroundRun, isFalse);

      // The slot is free again: a fresh submission runs.
      final value = await coordinator.submitBackground<int>(() async => 7);
      expect(value, 7);
    });

    test('submit runs the body in the held slot and frees it on completion',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      final reservation = coordinator.reserveBackground();

      final run = reservation!.submit<int>(() => gate.future);
      // The body is now running in the reserved slot — still busy.
      expect(coordinator.hasBackgroundRun, isTrue);

      gate.complete(11);
      expect(await run, 11);
      // The slot the reservation held is freed when the body completes — no leak.
      expect(coordinator.hasBackgroundRun, isFalse);
    });

    test('submit frees the held slot even when the body fails', () async {
      final coordinator = RunCoordinator();
      final failure = StateError('reserved boom');
      final reservation = coordinator.reserveBackground();

      final run = reservation!.submit<void>(() => Future.error(failure));
      await expectLater(run, throwsA(same(failure)));
      expect(coordinator.hasBackgroundRun, isFalse);
    });

    test('reserveBackground returns null while the coordinator is draining',
        () async {
      final coordinator = RunCoordinator();
      await coordinator.drain();

      expect(coordinator.reserveBackground(), isNull);
    });

    test('settling a reservation twice throws StateError', () {
      final coordinator = RunCoordinator();

      final cancelled = coordinator.reserveBackground()!;
      cancelled.cancel();
      expect(cancelled.cancel, throwsStateError);

      final submitted = coordinator.reserveBackground()!;
      // First settle via submit, then a second settle (cancel) must throw.
      submitted.submit<int>(() async => 1);
      expect(submitted.cancel, throwsStateError);
    });
  });

  group('F.3.2 RunCoordinator.close — owned vs injected controller', () {
    test('close closes the owned controller and its stream ends', () async {
      final coordinator = RunCoordinator();
      final collected = _collect(coordinator.preemptionEvents());

      // Let the run finish before closing — close() follows drain() in a real
      // shutdown, so no transition records after the stream closes.
      await coordinator.submitBackground<int>(() async => 1);
      await coordinator.close();

      // The owned controller is closed: its stream is done and a record after
      // close would throw — the coordinator's default-constructed controller
      // does not outlive the coordinator.
      expect(coordinator.preemptionController.isClosed, isTrue);
      // The done-stream terminates the collector (it would hang if still open).
      await collected.timeout(const Duration(seconds: 5));
    });

    test('close leaves an injected controller open', () async {
      final injected = PreemptionController();
      addTearDown(injected.close);
      final coordinator =
          RunCoordinator(preemptionController: injected);

      await coordinator.close();

      // The injected controller's lifecycle belongs to the consumer that
      // supplied it (the constructor contract) — close must not touch it.
      expect(injected.isClosed, isFalse);
    });

    test('close is idempotent', () async {
      final coordinator = RunCoordinator();
      await coordinator.close();
      await coordinator.close();
      expect(coordinator.preemptionController.isClosed, isTrue);
    });

    test('a run abandoned across close completes without driving the closed '
        'controller', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      // Submit a run that is still in-flight (gate closed) — this models the
      // hung body a bounded drain leaves behind. recordRunStarted fired on
      // submit, before close.
      final run = coordinator.submitBackground<int>(() => gate.future);

      // Close while the run is still parked: the owned controller is closed and
      // further records are suppressed.
      await coordinator.close();
      expect(coordinator.preemptionController.isClosed, isTrue);

      // The abandoned body now completes. Its slot-exit record must be dropped
      // (routed to a no-op) rather than thrown at the closed controller — the
      // run resolves cleanly and no async StateError escapes.
      gate.complete(5);
      expect(await run, 5);
      expect(coordinator.hasBackgroundRun, isFalse);
    });
  });

  group('F.3.3 SustainedFallbackMonitor — latch resets on a failed push', () {
    late DateTime t0;

    setUp(() => t0 = DateTime.utc(2026, 6, 2, 9));

    ProcedureFallback fallback(DateTime at) => ProcedureFallback(
          occurredAt: at,
          procedureId: 'proc_a',
          fromVersion: 1,
          toVersion: null,
          trigger: FallbackTrigger.runtimeCrash,
        );

    test('a failed idea-push rethrows and leaves the episode able to retry',
        () async {
      final memory = _FlakyMemory(failNextPersist: true);
      final monitor = SustainedFallbackMonitor(memory);

      // Below threshold: no push attempt.
      expect(await monitor.record(fallback(t0)), isNull);
      expect(
        await monitor.record(fallback(t0.add(const Duration(hours: 1)))),
        isNull,
      );

      // The 3rd edge crosses the threshold and attempts the push — which fails.
      // The error must surface (not be swallowed) and the latch must stay clear.
      await expectLater(
        monitor.record(fallback(t0.add(const Duration(hours: 2)))),
        throwsA(isA<StateError>()),
      );
      expect(memory.pushedStacks, isEmpty,
          reason: 'the failed push wrote nothing to the stack');

      // The next edge in the still-sustained window re-attempts. The latch was
      // left clear by the failure, so this retry fires the idea instead of
      // silently treating the episode as already-sent.
      final retried =
          await monitor.record(fallback(t0.add(const Duration(hours: 3))));
      expect(retried, isNotNull);
      expect(memory.pushedStacks, <String>[automationIdeasStackName]);
    });
  });

  group('F.5.2 shutdown drain timeout — derived from the hard step deadline',
      () {
    test('the coordinator hard step deadline is the engine deadline plus grace',
        () {
      expect(
        defaultCoordinatorHardStepDeadline,
        defaultStepDeadline + defaultCoordinatorDeadlineGrace,
      );
    });

    test('the shutdown drain timeout outlasts the coordinator hard deadline',
        () {
      // The drain must wait longer than a run's hard bound, so the normal end of
      // a run under shutdown is the coordinator force-yield (D.21), not the drain
      // giving up early.
      expect(
        defaultShutdownDrainTimeout,
        greaterThan(defaultCoordinatorHardStepDeadline),
      );
    });
  });
}

/// Drains [stream] into a list that resolves when the stream is done — used to
/// prove a closed controller terminates its subscribers.
Future<List<PreemptionEvent>> _collect(Stream<PreemptionEvent> stream) =>
    stream.toList();

/// A `TomBrainMemoryClient` double whose first `persist` throws (F.3.3), so a
/// test can drive the monitor's failed-write path. After the seeded failure it
/// behaves like a normal recording double: subsequent `persist`/`push` succeed
/// and `pushedStacks` records the targets.
class _FlakyMemory implements TomBrainMemoryClient {
  _FlakyMemory({required bool failNextPersist})
      : _failNextPersist = failNextPersist,
        _stacks = _MembershipStacks();

  bool _failNextPersist;
  final _MembershipStacks _stacks;

  List<String> get pushedStacks => _stacks.pushedStacks;

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    if (_failNextPersist) {
      _failNextPersist = false;
      throw StateError('seeded persist failure');
    }
    return NodeId.generate();
  }

  @override
  StackApi get stacks => _stacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async => TrailId.generate();

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async =>
      EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A `StackApi` double recording every `push` target (mirrors the D.31 double).
class _MembershipStacks implements StackApi {
  final List<String> pushedStacks = <String>[];

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    pushedStacks.add(name);
    return StackEntryId.generate();
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async =>
      const <StackEntry>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
