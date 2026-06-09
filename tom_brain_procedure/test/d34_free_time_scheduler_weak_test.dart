// D.34 — free-time scheduler is intentionally weak; it still exercises the
// background slot end-to-end.
//
// Plan step D.34: "For the prototype the scheduler is intentionally weak — no
// dream cycles yet. It still exercises the background slot so we can prove
// preemption end-to-end."
//
// D.34 makes two contract claims about the D.33 stub explicit and provable.
// D.33's unit tests pin the per-`tick` *decision policy* (which stack is hot,
// when a tick is a no-op); D.34 proves the *stance* on top of that policy:
//
//   1. No dream cycles yet. The § 5.3 `else` branch (round-robin dreaming) is
//      deliberately absent. When nothing schedulable is hot the scheduler
//      stays idle across as many cycles as you drive it — it never synthesises
//      a dream run, never invokes the work factory, and never occupies the
//      background slot. A hot *non-schedulable* stack (e.g. `inflight`) does
//      not coax it into inventing work either.
//
//   2. The background slot is genuinely exercised, and preemption works
//      end-to-end. A scheduled background run drives the *same* `RunCoordinator`
//      and the *same* shared `PreemptionState` the inbound foreground path
//      uses, so a background body that yields at its cooperative checkpoint
//      parks for a foreground arrival and resumes only once the whole
//      foreground chain drains — proven here against the real coordinator with
//      a faithful `yield_if_foreground_waiting`-shaped body, not a flag check.
//      Successive ticks then keep refilling the freed slot, so the weak
//      scheduler still keeps the background slot busy whenever the brain has
//      anything on its mind.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        StackApi,
        StackEntry,
        StackSummary,
        TomBrainMemoryClient,
        TrailEntry,
        TrailOutcome;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        BackgroundWorkFactory,
        FreeTimeDecision,
        FreeTimeScheduler,
        RunCoordinator,
        ScheduledBackgroundWork,
        ScheduledPick;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.34 — intentionally weak scheduler, exercised background slot', () {
    late _SchedulerMemory memory;
    late RunCoordinator coordinator;

    setUp(() {
      memory = _SchedulerMemory();
      coordinator = RunCoordinator();
    });

    FreeTimeScheduler schedulerWith(BackgroundWorkFactory factory) =>
        FreeTimeScheduler(
          coordinator: coordinator,
          memory: memory,
          workFactory: factory,
        );

    /// A factory that records every pick it is handed, so a test can assert it
    /// was never invoked when the scheduler stayed idle (no dream synthesis).
    BackgroundWorkFactory recordingFactory(List<ScheduledPick> seen) => (pick) {
          seen.add(pick);
          return ScheduledBackgroundWork(
            body: () async {},
            procedureId: 'free_time_scheduler_v1',
          );
        };

    group('claim 1 — no dream cycles yet (the § 5.3 else branch is absent)',
        () {
      test('repeated idle ticks never synthesise a dream run', () async {
        // Nothing on any schedulable stack: every cycle must be a clean no-op.
        final seen = <ScheduledPick>[];
        final scheduler = schedulerWith(recordingFactory(seen));

        for (var i = 0; i < 5; i++) {
          final tick = await scheduler.tick();
          expect(
            tick.decision,
            FreeTimeDecision.idle,
            reason: 'cycle $i should be idle, not a synthesised dream run',
          );
          expect(tick.didSchedule, isFalse);
          expect(coordinator.hasBackgroundRun, isFalse);
        }
        // The work factory is the only route to a background run; an idle
        // scheduler never touches it — there is no round-robin dreaming branch.
        expect(seen, isEmpty);
      });

      test('a hot non-schedulable stack does not coax a dream run out of an '
          'otherwise idle scheduler', () async {
        // `inflight` is hot (high priority, non-empty) but is a runtime-tracking
        // stack the scheduler must never harvest. With no schedulable stack hot,
        // the weak scheduler stays idle rather than falling through to dreaming.
        memory.seed('inflight', priority: 99);
        memory.seed('recent_runs', priority: 50);

        final seen = <ScheduledPick>[];
        final tick = await schedulerWith(recordingFactory(seen)).tick();

        expect(tick.decision, FreeTimeDecision.idle);
        expect(seen, isEmpty, reason: 'no schedulable stack ⇒ no work routed');
        expect(coordinator.hasBackgroundRun, isFalse);
        // The runtime-tracking stacks are untouched.
        expect(await memory.size('inflight'), 1);
        expect(await memory.size('recent_runs'), 1);
      });
    });

    group('claim 2 — the background slot is exercised and preempts end-to-end',
        () {
      test('a scheduled background run cooperatively yields to a foreground '
          'arrival and resumes once the foreground drains, then the freed slot '
          'is refilled by the next tick', () async {
        // Two entries on one hot stack: one drives the preemption proof, the
        // second proves the freed slot is refilled by a later tick.
        final first = memory.seed('questions_open', priority: 5);
        final second = memory.seed('questions_open', priority: 1);

        // A faithful cooperative background body: it does phase-1 work
        // (gated so the test controls timing), reaches a
        // `yield_if_foreground_waiting`-shaped checkpoint, parks on the shared
        // resume signal if a foreground is waiting, then finishes.
        final phaseOneRelease = Completer<void>();
        final reachedCheckpoint = Completer<void>();
        Future<void> cooperativeBody() async {
          await phaseOneRelease.future;
          reachedCheckpoint.complete();
          // The engine's `yield_if_foreground_waiting()`: park iff a foreground
          // is waiting (resumeSignal is non-null exactly then).
          final resume = coordinator.preemption.resumeSignal;
          if (resume != null) {
            await resume;
          }
        }

        // The first (preemption-proof) entry gets the cooperative body; any
        // later entry gets a trivial body — its one-shot completers must not
        // fire twice.
        final scheduler = schedulerWith(
          (pick) => ScheduledBackgroundWork(
            body: pick.entry.nodeId == first
                ? cooperativeBody
                : () async {},
            procedureId: 'free_time_scheduler_v1',
          ),
        );

        // Tick 1 schedules the first (highest-priority) entry as background.
        final tick1 = await scheduler.tick();
        expect(tick1.decision, FreeTimeDecision.scheduled);
        expect(tick1.pick!.entry.nodeId, first);
        expect(coordinator.hasBackgroundRun, isTrue);
        expect(coordinator.preemption.isForegroundWaiting, isFalse);

        // A foreground arrival while the background is still in phase 1 requests
        // preemption — but the background does not stop mid-step.
        final fgGate = Completer<int>();
        final fg = coordinator.submitForeground<int>(() => fgGate.future);
        expect(coordinator.preemption.isForegroundWaiting, isTrue);
        expect(coordinator.hasBackgroundRun, isTrue,
            reason: 'cooperative: the background runs until its next checkpoint');

        // Let the background reach its checkpoint. A foreground is waiting, so
        // it must park there rather than finish.
        phaseOneRelease.complete();
        await reachedCheckpoint.future;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isTrue,
            reason: 'the background parked at its yield checkpoint');
        expect(coordinator.preemption.isForegroundWaiting, isTrue);

        // The foreground finishes; the coordinator signals resume, releasing the
        // parked background, which then completes and frees the slot.
        fgGate.complete(0);
        await fg;
        await tick1.runFuture;
        await pumpEventQueue();
        expect(coordinator.hasForegroundRun, isFalse);
        expect(coordinator.hasBackgroundRun, isFalse);
        expect(coordinator.preemption.isForegroundWaiting, isFalse);

        // The slot is free again, so the next tick refills it with the second
        // entry — the weak scheduler keeps the background slot busy whenever
        // work remains.
        final tick2 = await scheduler.tick();
        expect(tick2.decision, FreeTimeDecision.scheduled);
        expect(tick2.pick!.entry.nodeId, second);
        expect(coordinator.hasBackgroundRun, isTrue);
        expect(await memory.size('questions_open'), 0,
            reason: 'both entries have now been harvested across two ticks');

        await tick2.runFuture;
      });
    });
  });
}

/// A `TomBrainMemoryClient` double exposing a membership-modeling stack API so
/// the scheduler can `list` / `pop` real entries. Only the surface the D.34
/// proof exercises is implemented; the rest routes through `noSuchMethod`.
class _SchedulerMemory implements TomBrainMemoryClient {
  final _SchedulerStacks _stacks = _SchedulerStacks();

  /// Seeds one entry of [priority] onto [stackName], returning its node id.
  NodeId seed(String stackName, {double priority = 0.0}) {
    final id = NodeId.generate();
    _stacks.seed(stackName, id, priority);
    return id;
  }

  /// Current member count of [stackName].
  Future<int> size(String stackName) async =>
      (await _stacks.peek(stackName, k: 1 << 20)).length;

  @override
  StackApi get stacks => _stacks;

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async =>
      NodeId.generate();

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

/// A `StackApi` double that models a priority stack: `list` reports size + top
/// priority per stack, `peek` returns entries highest-priority first, and `pop`
/// removes and returns the highest-priority entry. Only the surface the D.34
/// proof needs is implemented.
class _SchedulerStacks implements StackApi {
  final Map<String, List<StackEntry>> _entries = <String, List<StackEntry>>{};

  /// Test seam: appends an entry without going through the budget-charged push.
  void seed(String name, NodeId node, double priority) {
    (_entries[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: StackEntryId.generate(),
        stackName: name,
        nodeId: node,
        priority: priority,
        pushedAt: DateTime.now(),
      ),
    );
  }

  /// Entries of [name] ordered highest-priority first (insertion order breaks
  /// ties), the order a priority `peek` / `pop` honours.
  List<StackEntry> _ordered(String name) {
    final list = List<StackEntry>.of(_entries[name] ?? const <StackEntry>[]);
    list.sort((a, b) => b.priority.compareTo(a.priority));
    return list;
  }

  @override
  Future<List<StackSummary>> list() async => <StackSummary>[
        for (final entry in _entries.entries)
          StackSummary(
            name: entry.key,
            size: entry.value.length,
            topPriority: entry.value.isEmpty
                ? 0.0
                : _ordered(entry.key).first.priority,
            bootstrap: false,
          ),
      ];

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async =>
      _ordered(name).take(k).toList();

  @override
  Future<StackEntry?> pop(String name) async {
    final list = _entries[name];
    if (list == null || list.isEmpty) {
      return null;
    }
    final top = _ordered(name).first;
    list.removeWhere((e) => e.id == top.id);
    return top;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
