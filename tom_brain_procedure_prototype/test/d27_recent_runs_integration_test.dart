// D.27 — `recent_runs` integration (dispatcher half) tests.
//
// Plan step D.27: "On run end (success or fail), pop from `inflight` and push
// to `recent_runs`." Two layers are covered:
//
//   1. `RunRegistry.recordEnd` in isolation — it removes the running marker
//      from `inflight` (by node id) and pushes a terminal `ProcedureRun`
//      marker (`status: completed` / `failed` / `force_yielded`, with an
//      injected `endedAt`) onto `recent_runs`, returning the finished marker
//      id, with the right node shape and attributing scope.
//   2. `RunCoordinator` wiring — a coordinator handed a registry, on every run
//      end (success, failure, or a hard-step-deadline force-yield), removes the
//      run's `inflight` marker and pushes the matching terminal marker onto
//      `recent_runs`. An opaque body (no procedure id) or a coordinator with no
//      registry does neither. Concurrent foreground + background both clear
//      `inflight` and land two distinct `recent_runs` entries.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        StackApi,
        TomBrainMemoryClient,
        TrailEntry,
        TrailOutcome;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        RunCoordinator,
        RunOutcome,
        RunRegistration,
        RunRegistry,
        RunSlot,
        inflightStackName,
        procedureRunNodeType,
        recentRunsStackName;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.27 — RunRegistry.recordEnd', () {
    late _StubStacks stacks;
    late _StubMemory memory;
    final frozenStart = DateTime.utc(2026, 6, 2, 9, 30);
    final frozenEnd = DateTime.utc(2026, 6, 2, 9, 31);

    setUp(() {
      stacks = _StubStacks();
      memory = _StubMemory(stacks);
    });

    /// A registry whose clock advances from [frozenStart] (first call) to
    /// [frozenEnd] (every subsequent call), so a start-then-end pair stamps
    /// distinct `startedAt` / `endedAt` timestamps.
    RunRegistry buildRegistry() {
      var firstCall = true;
      return RunRegistry(
        memory,
        now: () {
          if (firstCall) {
            firstCall = false;
            return frozenStart;
          }
          return frozenEnd;
        },
      );
    }

    test('removes the running marker from inflight and pushes a completed '
        'marker onto recent_runs', () async {
      final registry = buildRegistry();
      const registration = RunRegistration(
        runId: 'r_1',
        procedureId: 'answer_with_memory_v1',
        slot: RunSlot.foreground,
      );

      final markerId = await registry.recordStart(registration);
      final finishedId = await registry.recordEnd(
        registration,
        markerId: markerId,
        outcome: RunOutcome.completed,
      );

      // The running marker was removed from inflight by node id.
      expect(stacks.removes, hasLength(1));
      expect(stacks.removes.single.stackName, inflightStackName);
      expect(stacks.removes.single.nodeId, markerId);

      // A distinct finished marker was persisted and pushed to recent_runs.
      expect(finishedId, isNot(markerId));
      expect(memory.persisted, hasLength(2));
      final finished = memory.persisted[1];
      expect(finished.typeName, procedureRunNodeType);
      expect(finished.values['status'], 'completed');
      expect(finished.values['procedureId'], 'answer_with_memory_v1');
      expect(finished.values['runId'], 'r_1');
      expect(finished.values['slot'], 'foreground');
      expect(finished.values['endedAt'], frozenEnd.toIso8601String());
      // The finished marker carries no startedAt; the running one carried no
      // endedAt.
      expect(finished.values.containsKey('startedAt'), isFalse);
      expect(memory.persisted[0].values.containsKey('endedAt'), isFalse);

      // The recent_runs push is the second push (inflight push was the first).
      expect(stacks.pushes, hasLength(2));
      final recentPush = stacks.pushes[1];
      expect(recentPush.stackName, recentRunsStackName);
      expect(recentPush.nodeId, finishedId);
      expect(recentPush.scope!.producer, 'dispatcher:answer_with_memory_v1:r_1');
      expect(recentPush.scope!.runId, 'r_1');
    });

    test('a failed outcome lands status: failed on recent_runs', () async {
      final registry = buildRegistry();
      const registration = RunRegistration(
        runId: 'r_2',
        procedureId: 'p',
        slot: RunSlot.background,
      );

      final markerId = await registry.recordStart(registration);
      await registry.recordEnd(
        registration,
        markerId: markerId,
        outcome: RunOutcome.failed,
      );

      expect(memory.persisted[1].values['status'], 'failed');
      expect(memory.persisted[1].values['slot'], 'background');
    });

    test('a force-yielded outcome lands status: force_yielded', () async {
      final registry = buildRegistry();
      const registration = RunRegistration(
        runId: 'r_3',
        procedureId: 'p',
        slot: RunSlot.foreground,
      );

      final markerId = await registry.recordStart(registration);
      await registry.recordEnd(
        registration,
        markerId: markerId,
        outcome: RunOutcome.forceYielded,
      );

      expect(memory.persisted[1].values['status'], 'force_yielded');
    });

    test('carries the parent run id onto the finished marker', () async {
      final registry = buildRegistry();
      const registration = RunRegistration(
        runId: 'child',
        procedureId: 'p',
        slot: RunSlot.foreground,
        parentRunId: 'parent',
      );

      final markerId = await registry.recordStart(registration);
      await registry.recordEnd(
        registration,
        markerId: markerId,
        outcome: RunOutcome.completed,
      );

      expect(memory.persisted[1].values['parentRunId'], 'parent');
    });

    test('omits parentRunId for a top-level finished marker', () async {
      final registry = buildRegistry();
      const registration = RunRegistration(
        runId: 'top',
        procedureId: 'p',
        slot: RunSlot.foreground,
      );

      final markerId = await registry.recordStart(registration);
      await registry.recordEnd(
        registration,
        markerId: markerId,
        outcome: RunOutcome.completed,
      );

      expect(memory.persisted[1].values.containsKey('parentRunId'), isFalse);
    });

    test('RunOutcome.status maps each terminal outcome to its wire string', () {
      expect(RunOutcome.completed.status, 'completed');
      expect(RunOutcome.failed.status, 'failed');
      expect(RunOutcome.forceYielded.status, 'force_yielded');
    });
  });

  group('D.27 — RunCoordinator wiring', () {
    late _StubStacks stacks;
    late _StubMemory memory;

    setUp(() {
      stacks = _StubStacks();
      memory = _StubMemory(stacks);
    });

    test('a foreground run that completes clears inflight and pushes a '
        'completed recent_runs marker', () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Started marker removed from inflight…
      expect(stacks.removes, hasLength(1));
      expect(stacks.removes.single.stackName, inflightStackName);
      expect(stacks.removes.single.nodeId, memory.persistedIds.first);
      // …and a completed marker pushed to recent_runs.
      final recentPushes =
          stacks.pushes.where((p) => p.stackName == recentRunsStackName);
      expect(recentPushes, hasLength(1));
      expect(memory.persisted.last.values['status'], 'completed');
      expect(memory.persisted.last.values['slot'], 'foreground');
    });

    test('a background run that completes pushes a background completed marker',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitBackground<int>(
        () async => 1,
        procedureId: 'free_time_scheduler_v1',
      );
      await pumpEventQueue();

      expect(stacks.removes, hasLength(1));
      expect(memory.persisted.last.values['status'], 'completed');
      expect(memory.persisted.last.values['slot'], 'background');
    });

    test('a foreground run that throws still pushes a failed recent_runs marker',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await expectLater(
        coordinator.submitForeground<int>(
          () async => throw StateError('boom'),
          procedureId: 'answer_with_memory_v1',
        ),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      expect(stacks.removes, hasLength(1));
      final recentPush = stacks.pushes
          .singleWhere((p) => p.stackName == recentRunsStackName);
      expect(recentPush.nodeId, memory.persistedIds.last);
      expect(memory.persisted.last.values['status'], 'failed');
    });

    test('no registry wired ⇒ no remove and no recent_runs push at run end',
        () async {
      final coordinator = RunCoordinator();

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      expect(stacks.removes, isEmpty);
      expect(stacks.pushes, isEmpty);
      expect(memory.persisted, isEmpty);
    });

    test('an opaque body (no procedure id) does nothing at run end', () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(stacks.removes, isEmpty);
      expect(stacks.pushes, isEmpty);
      expect(memory.persisted, isEmpty);
    });

    test('concurrent foreground + background both clear inflight and land two '
        'distinct recent_runs entries', () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Both live on inflight, none removed yet.
      expect(stacks.removes, isEmpty);
      expect(
        stacks.pushes.where((p) => p.stackName == inflightStackName),
        hasLength(2),
      );

      fgGate.complete(0);
      bgGate.complete(0);
      await fg;
      await bg;
      await pumpEventQueue();

      // Both inflight markers removed.
      expect(stacks.removes, hasLength(2));
      expect(
        stacks.removes.every((r) => r.stackName == inflightStackName),
        isTrue,
      );
      // Two distinct recent_runs entries, both slots present.
      final recentPushes = stacks.pushes
          .where((p) => p.stackName == recentRunsStackName)
          .toList();
      expect(recentPushes, hasLength(2));
      expect(recentPushes.map((p) => p.nodeId).toSet(), hasLength(2));
      final finishedSlots = memory.persisted
          .where((d) => d.values['status'] == 'completed')
          .map((d) => d.values['slot'] as String)
          .toSet();
      expect(finishedSlots, <String>{'foreground', 'background'});
    });

    test('the removed inflight node id matches the started marker id',
        () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'p',
      );
      await pumpEventQueue();

      // The running marker is the first persisted node; recordEnd removes it
      // by exactly that id.
      expect(stacks.removes.single.nodeId, memory.persistedIds.first);
    });
  });
}

/// Stub `TomBrainMemoryClient` capturing persists; delegates stacks to a
/// [_StubStacks]. Only the surface D.27 touches is implemented; the rest goes
/// through `noSuchMethod`.
class _StubMemory implements TomBrainMemoryClient {
  _StubMemory(this._stacks);

  final _StubStacks _stacks;

  final List<NodeDraft> persisted = <NodeDraft>[];
  final List<NodeId> persistedIds = <NodeId>[];

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persisted.add(draft);
    final id = NodeId.generate();
    persistedIds.add(id);
    return id;
  }

  @override
  StackApi get stacks => _stacks;

  // Unused by D.27 but part of the interface — keep them explicit so a
  // signature drift fails loudly rather than silently routing to noSuchMethod.
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

/// Stub `StackApi` capturing pushes and removes.
class _StubStacks implements StackApi {
  final List<_Push> pushes = <_Push>[];
  final List<_Remove> removes = <_Remove>[];

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    pushes.add(_Push(name, entry, scope));
    return StackEntryId.generate();
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    removes.add(_Remove(name, entry));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Push {
  _Push(this.stackName, this.nodeId, this.scope);

  final String stackName;
  final NodeId nodeId;
  final Scope? scope;
}

class _Remove {
  _Remove(this.stackName, this.nodeId);

  final String stackName;
  final NodeId nodeId;
}
