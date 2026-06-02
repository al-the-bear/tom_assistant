// D.28 — `inflight` / `recent_runs` stack-state-reflects-the-runtime tests.
//
// Plan step D.28: "Tests: stack state reflects the runtime; concurrent
// foreground + background appears as two distinct entries in `inflight`."
//
// Where the D.26 / D.27 suites assert the *call history* (which `push` /
// `remove` calls the registry made, via write-capturing stubs), D.28 asserts
// the *live membership state* of the two bootstrap stacks: at any instant,
// reading `inflight` through the public `StackApi.peek` surface returns
// exactly the runs the coordinator currently has live, and `recent_runs`
// accumulates exactly the finished ones. To do that the memory double here
// models real stack membership — `push` adds, `remove` deletes by node id,
// `peek` returns the current set — and stores every persisted `ProcedureRun`
// marker so a test can read the node behind each live entry (its `status`,
// `slot`, `runId`).
//
// The headline invariant is the concurrent case: one foreground and one
// background run live at the same time appear as two *distinct* `inflight`
// entries (distinct nodes, distinct run ids, both slots present), and each
// migrates from `inflight` to `recent_runs` as its run ends — never the same
// node, since the store is append-only (overview principle 6).

import 'dart:async';

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
        RunCoordinator,
        RunRegistry,
        inflightStackName,
        procedureRunNodeType,
        recentRunsStackName;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId;
import 'package:test/test.dart';

void main() {
  group('D.28 — stack state reflects the runtime', () {
    late _MembershipMemory memory;

    setUp(() => memory = _MembershipMemory());

    /// The `ProcedureRun` nodes currently living on `inflight`, read through
    /// the public `StackApi.peek` surface (not the registry's call history).
    Future<List<NodeDraft>> inflightNodes() => _nodesOn(memory, inflightStackName);

    /// The `ProcedureRun` nodes currently living on `recent_runs`.
    Future<List<NodeDraft>> recentRunNodes() =>
        _nodesOn(memory, recentRunsStackName);

    test('both stacks are empty before any run starts', () async {
      // No coordinator activity yet: neither bootstrap stack has any members.
      expect(await inflightNodes(), isEmpty);
      expect(await recentRunNodes(), isEmpty);
    });

    test('a live foreground run is exactly one inflight entry; on end it '
        'migrates to recent_runs', () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // While the run is live: exactly one inflight entry, running, foreground.
      final live = await inflightNodes();
      expect(live, hasLength(1));
      expect(live.single.values['status'], 'running');
      expect(live.single.values['slot'], 'foreground');
      expect(await recentRunNodes(), isEmpty);

      // The node currently on inflight, for the migration check below.
      final liveEntry =
          (await memory.stacks.peek(inflightStackName)).single.nodeId;

      gate.complete(7);
      expect(await run, 7);
      await pumpEventQueue();

      // After the run ends: inflight empty, one completed entry in recent_runs.
      expect(await inflightNodes(), isEmpty);
      final recent = await recentRunNodes();
      expect(recent, hasLength(1));
      expect(recent.single.values['status'], 'completed');
      expect(recent.single.values['slot'], 'foreground');

      // The recent_runs entry is a *distinct* node from the one that was on
      // inflight — the store is append-only, so the running marker and the
      // finished marker are two events, not one mutated row.
      final recentEntry =
          (await memory.stacks.peek(recentRunsStackName)).single.nodeId;
      expect(recentEntry, isNot(liveEntry));
    });

    test('concurrent foreground + background appear as two distinct inflight '
        'entries, then both migrate to recent_runs', () async {
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

      // Two live runs ⇒ two inflight entries: distinct nodes, distinct run
      // ids, both slots present, all running.
      final liveEntries = await memory.stacks.peek(inflightStackName);
      expect(liveEntries, hasLength(2));
      expect(liveEntries.map((e) => e.nodeId).toSet(), hasLength(2));
      final liveNodes =
          liveEntries.map((e) => memory.nodeFor(e.nodeId)).toList();
      expect(
        liveNodes.map((n) => n.values['status']).toSet(),
        <String>{'running'},
      );
      expect(
        liveNodes.map((n) => n.values['slot'] as String).toSet(),
        <String>{'foreground', 'background'},
      );
      expect(
        liveNodes.map((n) => n.values['runId'] as String).toSet(),
        hasLength(2),
      );
      expect(await recentRunNodes(), isEmpty);

      fgGate.complete(1);
      bgGate.complete(2);
      await fg;
      await bg;
      await pumpEventQueue();

      // Both migrated: inflight empty, two distinct recent_runs entries, both
      // slots present.
      expect(await inflightNodes(), isEmpty);
      final recentEntries = await memory.stacks.peek(recentRunsStackName);
      expect(recentEntries, hasLength(2));
      expect(recentEntries.map((e) => e.nodeId).toSet(), hasLength(2));
      final recentNodes = await recentRunNodes();
      expect(
        recentNodes.map((n) => n.values['status']).toSet(),
        <String>{'completed'},
      );
      expect(
        recentNodes.map((n) => n.values['slot'] as String).toSet(),
        <String>{'foreground', 'background'},
      );
    });

    test('inflight membership tracks the live set as one of two concurrent '
        'runs ends', () async {
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
      expect(await inflightNodes(), hasLength(2));

      // End only the background run.
      bgGate.complete(0);
      await bg;
      await pumpEventQueue();

      // inflight now reflects exactly the still-live foreground run.
      final live = await inflightNodes();
      expect(live, hasLength(1));
      expect(live.single.values['slot'], 'foreground');
      expect(live.single.values['status'], 'running');
      // recent_runs holds exactly the finished background run.
      final recent = await recentRunNodes();
      expect(recent, hasLength(1));
      expect(recent.single.values['slot'], 'background');

      // Finish the foreground run too, so no live state lingers.
      fgGate.complete(0);
      await fg;
      await pumpEventQueue();
      expect(await inflightNodes(), isEmpty);
      expect(await recentRunNodes(), hasLength(2));
    });

    test('sequential foreground runs accumulate in recent_runs while inflight '
        'returns to empty', () async {
      final coordinator = RunCoordinator(runRegistry: RunRegistry(memory));

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();
      await coordinator.submitForeground<int>(
        () async => 2,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // After both ran to completion: inflight drained, recent_runs holds both.
      expect(await inflightNodes(), isEmpty);
      final recent = await recentRunNodes();
      expect(recent, hasLength(2));
      expect(
        recent.map((n) => n.values['status']).toSet(),
        <String>{'completed'},
      );
      expect(recent.map((n) => n.values['runId'] as String).toSet(),
          hasLength(2));
    });

    test('a failed run clears inflight and lands a failed recent_runs entry',
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

      expect(await inflightNodes(), isEmpty);
      final recent = await recentRunNodes();
      expect(recent, hasLength(1));
      expect(recent.single.values['status'], 'failed');
      expect(recent.single.values['slot'], 'foreground');
    });
  });
}

/// Reads the `ProcedureRun` nodes currently living on [stackName], through the
/// public `StackApi.peek` surface, asserting each entry is a `ProcedureRun`.
Future<List<NodeDraft>> _nodesOn(_MembershipMemory memory, String stackName) async {
  final entries = await memory.stacks.peek(stackName, k: 1000);
  return entries.map((e) {
    final node = memory.nodeFor(e.nodeId);
    expect(node.typeName, procedureRunNodeType);
    return node;
  }).toList();
}

/// A `TomBrainMemoryClient` double that stores every persisted node by id and
/// delegates stack operations to a membership-modeling [_MembershipStacks], so
/// a test can read the live state of `inflight` / `recent_runs` and look up the
/// node behind each entry. Only the surface D.28 exercises is implemented; the
/// rest routes through `noSuchMethod`.
class _MembershipMemory implements TomBrainMemoryClient {
  _MembershipMemory() : _stacks = _MembershipStacks();

  final _MembershipStacks _stacks;
  final Map<NodeId, NodeDraft> _nodes = <NodeId, NodeDraft>{};

  /// The persisted node behind [id]. Fails the test loudly if the stack holds
  /// an id that was never persisted.
  NodeDraft nodeFor(NodeId id) {
    final node = _nodes[id];
    expect(node, isNotNull, reason: 'no persisted node for $id');
    return node!;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = draft;
    return id;
  }

  @override
  StackApi get stacks => _stacks;

  // Unused by D.28 but part of the interface — kept explicit so a signature
  // drift fails loudly rather than silently routing to noSuchMethod.
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

/// A `StackApi` double that models real membership: [push] appends an entry,
/// [remove] deletes the first entry with a matching node id, [peek] returns
/// the current entries (insertion order) — so the test reads the live state of
/// a stack rather than the registry's call history.
class _MembershipStacks implements StackApi {
  final Map<String, List<StackEntry>> _entries = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_entries[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    final list = _entries[name];
    if (list == null) {
      return;
    }
    final index = list.indexWhere((e) => e.nodeId == entry);
    if (index >= 0) {
      list.removeAt(index);
    }
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final list = _entries[name] ?? const <StackEntry>[];
    return list.take(k).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
