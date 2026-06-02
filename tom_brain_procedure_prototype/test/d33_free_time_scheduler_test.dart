// D.33 — free-time scheduler stub tests.
//
// Plan step D.33: "Implement a minimal `free_time_scheduler_v1.dart` stub
// that, when no foreground work is pending, picks one entry from a hot stack
// and submits it as background. Hot-stack policy from definition § 5.3."
//
// These tests pin the kernel's decision policy: a `tick` is a no-op while
// foreground work is pending or the background slot is busy; otherwise it
// picks the highest-priority *hot* stack (§ 5.3), pops its top entry, and
// submits it as a background run via the same `RunCoordinator` the inbound
// path uses. The hot-stack selection (size OR priority threshold, restricted
// to the § 5.1 work stacks, highest-priority winner with deterministic
// tie-breaking) and the background-submission integration (the run actually
// occupies the coordinator's background slot, and a foreground arrival drives
// preemption against it) are both covered here.

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
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
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
  group('D.33 — free-time scheduler', () {
    late _SchedulerMemory memory;
    late RunCoordinator coordinator;

    setUp(() {
      memory = _SchedulerMemory();
      coordinator = RunCoordinator();
    });

    /// A factory that builds a gated background run for any pick, recording the
    /// picks it saw so a test can assert what was routed. The body completes
    /// only when [gate] does, so the background run can be held live.
    BackgroundWorkFactory gatedFactory(
      Completer<void> gate,
      List<ScheduledPick> seen,
    ) =>
        (pick) {
          seen.add(pick);
          return ScheduledBackgroundWork(
            body: () => gate.future,
            procedureId: 'free_time_scheduler_v1',
          );
        };

    FreeTimeScheduler schedulerWith(BackgroundWorkFactory factory) =>
        FreeTimeScheduler(
          coordinator: coordinator,
          memory: memory,
          workFactory: factory,
        );

    test('a foreground run pending makes the tick a no-op', () async {
      memory.seed('questions_open', priority: 1);
      // Hold a foreground run live.
      final fgGate = Completer<int>();
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      await pumpEventQueue();

      final seen = <ScheduledPick>[];
      final scheduler = schedulerWith(gatedFactory(Completer<void>(), seen));
      final tick = await scheduler.tick();

      expect(tick.decision, FreeTimeDecision.foregroundPending);
      expect(tick.didSchedule, isFalse);
      expect(seen, isEmpty, reason: 'no stack should be popped');
      // The hot entry is untouched.
      expect(await memory.size('questions_open'), 1);
      expect(coordinator.hasBackgroundRun, isFalse);

      fgGate.complete(0);
      await fg;
    });

    test('a queued foreground submission also blocks the tick', () async {
      memory.seed('interests', priority: 1);
      // One running + one queued foreground run: the queue is non-empty.
      final running = Completer<int>();
      final r = coordinator.submitForeground<int>(() => running.future);
      final queued = Completer<int>();
      final q = coordinator.submitForeground<int>(() => queued.future);
      await pumpEventQueue();
      expect(coordinator.foregroundQueueLength, 1);

      final tick = await schedulerWith(
        gatedFactory(Completer<void>(), <ScheduledPick>[]),
      ).tick();
      expect(tick.decision, FreeTimeDecision.foregroundPending);

      running.complete(0);
      await r;
      queued.complete(0);
      await q;
    });

    test('a live background run makes the tick a no-op', () async {
      memory.seed('questions_open', priority: 1);
      // Occupy the background slot directly.
      final bgGate = Completer<int>();
      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      await pumpEventQueue();
      expect(coordinator.hasBackgroundRun, isTrue);

      final seen = <ScheduledPick>[];
      final tick =
          await schedulerWith(gatedFactory(Completer<void>(), seen)).tick();

      expect(tick.decision, FreeTimeDecision.backgroundBusy);
      expect(seen, isEmpty);
      expect(await memory.size('questions_open'), 1);

      bgGate.complete(0);
      await bg;
    });

    test('no hot stack makes the tick idle', () async {
      // All schedulable stacks empty: nothing is hot.
      final tick = await schedulerWith(
        gatedFactory(Completer<void>(), <ScheduledPick>[]),
      ).tick();

      expect(tick.decision, FreeTimeDecision.idle);
      expect(tick.didSchedule, isFalse);
      expect(coordinator.hasBackgroundRun, isFalse);
    });

    test('a hot stack is popped and submitted as a background run', () async {
      final node = memory.seed('questions_open', priority: 2);

      final gate = Completer<void>();
      final seen = <ScheduledPick>[];
      final tick = await schedulerWith(gatedFactory(gate, seen)).tick();

      // Scheduled: the top entry was popped and submitted.
      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(tick.didSchedule, isTrue);
      expect(tick.pick!.stackName, 'questions_open');
      expect(tick.pick!.entry.nodeId, node);
      expect(seen.single.entry.nodeId, node);
      // The entry is gone from the stack and a background run is live.
      expect(await memory.size('questions_open'), 0);
      expect(coordinator.hasBackgroundRun, isTrue);

      // The submitted run completes when its gate does.
      gate.complete();
      await tick.runFuture;
      await pumpEventQueue();
      expect(coordinator.hasBackgroundRun, isFalse);
    });

    test('the highest-priority hot stack is picked among several', () async {
      memory.seed('questions_open', priority: 1);
      final hot = memory.seed('automation_ideas', priority: 9);
      memory.seed('interests', priority: 5);

      final seen = <ScheduledPick>[];
      final tick =
          await schedulerWith(gatedFactory(Completer<void>(), seen)).tick();

      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(tick.pick!.stackName, 'automation_ideas');
      expect(tick.pick!.entry.nodeId, hot);
      // Only the winning stack was popped.
      expect(await memory.size('automation_ideas'), 0);
      expect(await memory.size('questions_open'), 1);
      expect(await memory.size('interests'), 1);
    });

    test('a non-schedulable stack is never picked even when hot', () async {
      // `inflight` is a runtime-tracking stack, not a work stack — it must be
      // ignored even though it is the highest priority.
      memory.seed('inflight', priority: 99);
      final work = memory.seed('interests', priority: 1);

      final tick = await schedulerWith(
        gatedFactory(Completer<void>(), <ScheduledPick>[]),
      ).tick();

      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(tick.pick!.stackName, 'interests');
      expect(tick.pick!.entry.nodeId, work);
      expect(await memory.size('inflight'), 1, reason: 'inflight untouched');
    });

    test('a high-priority top entry is hot even when the size clause fails',
        () async {
      // size 1 with a strict size threshold of 5 ⇒ not size-hot; but the top
      // priority (4) ≥ priority threshold (3) ⇒ priority-hot.
      final node = memory.seed('interests', priority: 4);
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: gatedFactory(Completer<void>(), <ScheduledPick>[]),
        hotSizeThreshold: 5,
        hotPriorityThreshold: 3,
      );

      final tick = await scheduler.tick();
      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(tick.pick!.entry.nodeId, node);
    });

    test('a low-priority small stack is not hot under raised thresholds',
        () async {
      // size 1 (≤ size threshold 5) and priority 1 (< priority threshold 3):
      // neither clause holds ⇒ not hot.
      memory.seed('interests', priority: 1);
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: gatedFactory(Completer<void>(), <ScheduledPick>[]),
        hotSizeThreshold: 5,
        hotPriorityThreshold: 3,
      );

      final tick = await scheduler.tick();
      expect(tick.decision, FreeTimeDecision.idle);
      expect(await memory.size('interests'), 1);
    });

    test('equal top priority breaks the tie on the larger stack', () async {
      // Both stacks top out at priority 2; automation_ideas is larger.
      memory.seed('questions_open', priority: 2);
      memory.seed('automation_ideas', priority: 2);
      memory.seed('automation_ideas', priority: 1);

      final tick = await schedulerWith(
        gatedFactory(Completer<void>(), <ScheduledPick>[]),
      ).tick();
      expect(tick.pick!.stackName, 'automation_ideas');
    });

    test('a factory that declines the pick yields an idle cycle', () async {
      memory.seed('questions_open', priority: 1);
      final scheduler = FreeTimeScheduler(
        coordinator: coordinator,
        memory: memory,
        workFactory: (_) => null, // decline every pick
      );

      final tick = await scheduler.tick();
      expect(tick.decision, FreeTimeDecision.idle);
      expect(tick.didSchedule, isFalse);
      expect(coordinator.hasBackgroundRun, isFalse);
      // Per § 5.3 the entry is popped before routing, so a declined pick
      // drains it (the stub does not re-push).
      expect(await memory.size('questions_open'), 0);
    });

    test('the scheduled background run cooperatively yields to a foreground '
        'arrival', () async {
      memory.seed('questions_open', priority: 1);
      final bgGate = Completer<void>();
      final tick =
          await schedulerWith(gatedFactory(bgGate, <ScheduledPick>[])).tick();
      expect(tick.decision, FreeTimeDecision.scheduled);
      expect(coordinator.hasBackgroundRun, isTrue);
      // No foreground waiting yet.
      expect(coordinator.preemption.isForegroundWaiting, isFalse);

      // A foreground arrival while the background is live requests preemption.
      final fgGate = Completer<int>();
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(coordinator.preemption.isForegroundWaiting, isTrue);

      // Drain both: the background finishes, then the foreground.
      bgGate.complete();
      await tick.runFuture;
      fgGate.complete(0);
      await fg;
      await pumpEventQueue();
      expect(coordinator.preemption.isForegroundWaiting, isFalse);
    });

    test('successive ticks each schedule one entry when the slot frees',
        () async {
      memory.seed('questions_open', priority: 2);
      memory.seed('questions_open', priority: 1);

      final gate1 = Completer<void>();
      final t1 = await schedulerWith(gatedFactory(gate1, <ScheduledPick>[]))
          .tick();
      expect(t1.decision, FreeTimeDecision.scheduled);

      // A second tick while the first background run is live is a no-op.
      final t2 = await schedulerWith(
        gatedFactory(Completer<void>(), <ScheduledPick>[]),
      ).tick();
      expect(t2.decision, FreeTimeDecision.backgroundBusy);
      expect(await memory.size('questions_open'), 1);

      // Free the slot, then a third tick schedules the remaining entry.
      gate1.complete();
      await t1.runFuture;
      await pumpEventQueue();
      final gate3 = Completer<void>();
      final t3 = await schedulerWith(gatedFactory(gate3, <ScheduledPick>[]))
          .tick();
      expect(t3.decision, FreeTimeDecision.scheduled);
      expect(await memory.size('questions_open'), 0);
      gate3.complete();
      await t3.runFuture;
    });
  });
}

/// A `TomBrainMemoryClient` double exposing a membership-modeling stack API so
/// the scheduler can `list` / `pop` real entries. Only the surface D.33
/// exercises is implemented; the rest routes through `noSuchMethod`.
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
/// removes and returns the highest-priority entry. Only the surface D.33 needs
/// is implemented.
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
