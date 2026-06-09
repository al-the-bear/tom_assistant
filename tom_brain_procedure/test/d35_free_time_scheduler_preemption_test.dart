// D.35 — the free-time scheduler's dedicated proof suite: it invokes
// background work, and that work preempts cleanly under foreground load.
//
// Plan step D.35: "Tests: scheduler invokes background work; preempts cleanly
// under foreground load."
//
// D.33 pins the per-`tick` *decision policy* (which stack is hot, when a tick
// is a no-op). D.34 proves the weak-scheduler *stance* (no dream synthesis;
// the slot is exercised end-to-end). D.35 is the focused proof of the two
// claims the Plan step words verbatim, driven against the *real*
// `RunCoordinator` and the *real* shared `PreemptionState`:
//
//   1. The scheduler invokes background work. A hot stack makes a `tick`
//      schedule a *real* background run: the body genuinely executes (a side
//      effect it sets is observed), it occupies the background slot while live,
//      and it completes through the coordinator — not a synchronous no-op
//      masquerading as a run.
//
//   2. It preempts cleanly under foreground load. The emphasis here, distinct
//      from D.34's single-foreground checkpoint proof, is *load*:
//        - The scheduler refuses to add background load while a foreground is
//          live *or* queued — a tick under foreground load is `foregroundPending`,
//          never a second concurrent run.
//        - A scheduled background run parked by a foreground arrival resumes
//          only after the *whole* foreground chain drains (a running run plus
//          several FIFO-queued successors), not after merely the first.
//        - "Cleanly" means the parked background resumes and *completes
//          successfully* — it is not force-yielded, does not error, and its
//          work is neither lost nor double-run.

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
        ScheduledBackgroundWork;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.35 — scheduler invokes background work; preempts under load', () {
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

    /// A factory that hands every popped entry the same [body] under the
    /// `free_time_scheduler_v1` identity.
    BackgroundWorkFactory bodyFactory(Future<void> Function() body) =>
        (pick) => ScheduledBackgroundWork(
              body: body,
              procedureId: 'free_time_scheduler_v1',
            );

    /// A cooperative background body shaped like the engine's
    /// `yield_if_foreground_waiting()`: it does phase-1 work (gated so the test
    /// controls timing), records that it reached its checkpoint, parks on the
    /// shared resume signal iff a foreground is waiting, then does phase-2 work
    /// and finishes — recording completion exactly once.
    ({
      Future<void> Function() body,
      Completer<void> releasePhaseOne,
      Completer<void> reachedCheckpoint,
      List<String> log,
    }) cooperativeBody() {
      final releasePhaseOne = Completer<void>();
      final reachedCheckpoint = Completer<void>();
      final log = <String>[];
      Future<void> body() async {
        log.add('phase1');
        await releasePhaseOne.future;
        reachedCheckpoint.complete();
        final resume = coordinator.preemption.resumeSignal;
        if (resume != null) {
          log.add('parked');
          await resume;
        }
        log.add('phase2');
        log.add('done');
      }

      return (
        body: body,
        releasePhaseOne: releasePhaseOne,
        reachedCheckpoint: reachedCheckpoint,
        log: log,
      );
    }

    group('claim 1 — the scheduler invokes background work', () {
      test('a hot stack makes a tick run a real background body to completion',
          () async {
        final picked = memory.seed('questions_open', priority: 3);
        var bodyRan = false;
        final scheduler = schedulerWith(
          bodyFactory(() async {
            bodyRan = true;
          }),
        );

        final tick = await scheduler.tick();

        // The tick scheduled the hot entry as a real background run...
        expect(tick.decision, FreeTimeDecision.scheduled);
        expect(tick.didSchedule, isTrue);
        expect(tick.pick!.stackName, 'questions_open');
        expect(tick.pick!.entry.nodeId, picked);
        expect(tick.runFuture, isNotNull);

        // ...and that run's body genuinely executes (not a synthetic no-op).
        await tick.runFuture;
        expect(bodyRan, isTrue, reason: 'the scheduled background body ran');
        // The slot is freed once the run completes.
        expect(coordinator.hasBackgroundRun, isFalse);
        // The entry was harvested from the stack.
        expect(await memory.size('questions_open'), 0);
      });

      test('the scheduled background run genuinely occupies the slot while live',
          () async {
        memory.seed('interests', priority: 2);
        final gate = Completer<void>();
        final scheduler = schedulerWith(bodyFactory(() => gate.future));

        final tick = await scheduler.tick();
        expect(tick.decision, FreeTimeDecision.scheduled);
        // While the gated body runs, the background slot is occupied — proof the
        // scheduler started a real, still-running run rather than completing it
        // synchronously.
        expect(coordinator.hasBackgroundRun, isTrue);

        gate.complete();
        await tick.runFuture;
        expect(coordinator.hasBackgroundRun, isFalse);
      });
    });

    group('claim 2 — preempts cleanly under foreground load', () {
      test('a tick refuses to add background load while a foreground is live',
          () async {
        memory.seed('questions_open', priority: 5);
        final fgGate = Completer<void>();
        final fg = coordinator.submitForeground<void>(() => fgGate.future);
        expect(coordinator.hasForegroundRun, isTrue);

        // Under foreground load the scheduler does not start background work.
        final tick = await schedulerWith(bodyFactory(() async {})).tick();
        expect(tick.decision, FreeTimeDecision.foregroundPending);
        expect(coordinator.hasBackgroundRun, isFalse);
        // The hot entry is left untouched for a later idle cycle.
        expect(await memory.size('questions_open'), 1);

        fgGate.complete();
        await fg;
      });

      test('a tick refuses to add background load while a foreground waits in '
          'the FIFO queue', () async {
        memory.seed('questions_open', priority: 5);
        // One running + one queued foreground: the foreground workload is busy
        // even though only one run is "live".
        final runningGate = Completer<void>();
        final queuedGate = Completer<void>();
        final running =
            coordinator.submitForeground<void>(() => runningGate.future);
        final queued =
            coordinator.submitForeground<void>(() => queuedGate.future);
        expect(coordinator.foregroundQueueLength, 1);

        final tick = await schedulerWith(bodyFactory(() async {})).tick();
        expect(tick.decision, FreeTimeDecision.foregroundPending,
            reason: 'a queued foreground is still pending load');
        expect(coordinator.hasBackgroundRun, isFalse);
        expect(await memory.size('questions_open'), 1);

        runningGate.complete();
        await running;
        queuedGate.complete();
        await queued;
      });

      test('a scheduled background parks under a foreground arrival and resumes '
          'only after the WHOLE foreground chain drains, completing cleanly',
          () async {
        memory.seed('questions_open', priority: 7);
        final coop = cooperativeBody();
        final scheduler = schedulerWith(bodyFactory(coop.body));

        // Tick schedules the background run; it starts phase 1.
        final tick = await scheduler.tick();
        expect(tick.decision, FreeTimeDecision.scheduled);
        expect(coordinator.hasBackgroundRun, isTrue);
        await pumpEventQueue();
        expect(coop.log, contains('phase1'));

        // Sustained foreground LOAD: one running plus two FIFO-queued
        // foregrounds, each gated so the test drains them one at a time.
        final gate1 = Completer<int>();
        final gate2 = Completer<int>();
        final gate3 = Completer<int>();
        final fg1 = coordinator.submitForeground<int>(() => gate1.future);
        final fg2 = coordinator.submitForeground<int>(() => gate2.future);
        final fg3 = coordinator.submitForeground<int>(() => gate3.future);
        expect(coordinator.foregroundQueueLength, 2);
        expect(coordinator.preemption.isForegroundWaiting, isTrue);

        // Let the background reach its checkpoint: a foreground is waiting, so
        // it parks rather than finishing.
        coop.releasePhaseOne.complete();
        await coop.reachedCheckpoint.future;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isTrue,
            reason: 'parked at the yield checkpoint');
        expect(coop.log, contains('parked'));
        expect(coop.log, isNot(contains('phase2')));

        // Drain the chain one run at a time. After each of the first two
        // foregrounds the queue is still non-empty / the slot still busy, so the
        // background must stay parked — resume fires only when the WHOLE chain
        // has drained.
        gate1.complete(1);
        await fg1;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isTrue,
            reason: 'fg2 still pending: background stays parked');
        expect(coordinator.preemption.isForegroundWaiting, isTrue);
        expect(coop.log, isNot(contains('phase2')));

        gate2.complete(2);
        await fg2;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isTrue,
            reason: 'fg3 still pending: background stays parked');
        expect(coordinator.preemption.isForegroundWaiting, isTrue);
        expect(coop.log, isNot(contains('phase2')));

        // The last foreground drains: the chain is empty, resume fires, and the
        // background completes cleanly (phase 2 runs, the run returns normally).
        gate3.complete(3);
        await fg3;
        await tick.runFuture;
        await pumpEventQueue();
        expect(coordinator.hasForegroundRun, isFalse);
        expect(coordinator.hasBackgroundRun, isFalse);
        expect(coordinator.preemption.isForegroundWaiting, isFalse);
        expect(coop.log, <String>['phase1', 'parked', 'phase2', 'done'],
            reason: 'parked once, resumed once, completed once — no work lost '
                'and none double-run');
      });

      test('the preempted background run resumes successfully — it is neither '
          'force-yielded nor errored', () async {
        memory.seed('questions_open', priority: 4);
        final coop = cooperativeBody();
        var runValueDelivered = false;
        final scheduler = schedulerWith(
          (pick) => ScheduledBackgroundWork(
            body: () async {
              await coop.body();
              runValueDelivered = true;
            },
            procedureId: 'free_time_scheduler_v1',
          ),
        );

        final tick = await scheduler.tick();
        expect(tick.decision, FreeTimeDecision.scheduled);

        final fgGate = Completer<int>();
        final fg = coordinator.submitForeground<int>(() => fgGate.future);
        coop.releasePhaseOne.complete();
        await coop.reachedCheckpoint.future;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isTrue);

        fgGate.complete(0);
        await fg;

        // The run future resolves without error — a clean resume, not a
        // force-yield (`RunDeadlineExceeded`) or a thrown body.
        await expectLater(tick.runFuture, completes);
        expect(runValueDelivered, isTrue,
            reason: 'the body finished its work after resuming');
        expect(coordinator.hasBackgroundRun, isFalse);
      });

      test('after a clean preemption the freed slot is refilled by the next '
          'tick — the scheduler keeps working under recurring load', () async {
        final first = memory.seed('questions_open', priority: 9);
        final second = memory.seed('questions_open', priority: 1);
        final coop = cooperativeBody();
        // Only the first (preemption-proof) entry gets the cooperative body;
        // the second gets a trivial body so the one-shot completers fire once.
        final scheduler = schedulerWith(
          (pick) => ScheduledBackgroundWork(
            body: pick.entry.nodeId == first ? coop.body : () async {},
            procedureId: 'free_time_scheduler_v1',
          ),
        );

        final tick1 = await scheduler.tick();
        expect(tick1.pick!.entry.nodeId, first);

        final fgGate = Completer<int>();
        final fg = coordinator.submitForeground<int>(() => fgGate.future);
        coop.releasePhaseOne.complete();
        await coop.reachedCheckpoint.future;
        await pumpEventQueue();

        fgGate.complete(0);
        await fg;
        await tick1.runFuture;
        await pumpEventQueue();
        expect(coordinator.hasBackgroundRun, isFalse);

        // The slot is free again: the next tick refills it with the remaining
        // entry, proving the scheduler keeps harvesting work after preemption.
        final tick2 = await scheduler.tick();
        expect(tick2.decision, FreeTimeDecision.scheduled);
        expect(tick2.pick!.entry.nodeId, second);
        await tick2.runFuture;
        expect(await memory.size('questions_open'), 0);
      });
    });
  });
}

/// A `TomBrainMemoryClient` double exposing a membership-modeling stack API so
/// the scheduler can `list` / `pop` real entries. Only the surface the D.35
/// proof exercises is implemented; the rest routes through `noSuchMethod`.
///
/// Duplicated from the D.33 / D.34 scheduler suites — Dart test files are
/// separate compilation units and cannot share private classes.
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
/// removes and returns the highest-priority entry. Only the surface the D.35
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
