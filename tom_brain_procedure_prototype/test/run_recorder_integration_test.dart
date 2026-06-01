// C.33 — RunRecorder ↔ stub-memory integration tests.
//
// Where C.31/C.32 drive the recorder against capture-only stubs (every
// call is appended to a flat list and asserted directly), C.33 is the
// dedicated *integration* step: it drives the recorder against a
// **stateful** in-memory memory + stacks double that actually models the
// store. Trails are real ordered entry logs read back via `readTrail`;
// stacks are real push/peek/pop/remove containers; persisted nodes are
// resolvable by id via `get`. The recorder is treated as a black box —
// the assertions read the *observable store state*, not the recorder's
// own in-memory mirror:
//
//   - trail entries appear in order      → read back via `readTrail`.
//   - `inflight` reflects the running run → `peek('inflight')` mid-run
//     resolves to a `running` marker node for this procedure.
//   - on completion the run lands in     → `peek('recent_runs')` resolves
//     `recent_runs`                         to the final node and
//                                           `inflight` is empty again.
//
// The stateful double is faithful to the real memory contract used by
// `RunRecorder`: `closeTrail` synthesises the `outcome` JSONL line in
// storage (so a `readTrail` includes it), and `remove`/`push` mutate the
// live stacks.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('C.33 RunRecorder ↔ stateful stub memory', () {
    late _InMemoryMemory memory;
    late RunRecorder recorder;
    late DateTime clock;

    DateTime now() => clock;

    setUp(() {
      memory = _InMemoryMemory();
      clock = DateTime.utc(2026, 6, 1, 12, 0, 0);
      recorder = RunRecorder(memory, now: now);
    });

    RunStart startInfo({NodeId? procedureNodeId}) => RunStart(
          procedureId: 'answer_with_memory_v1',
          version: 1,
          runId: 'r_int_1',
          arguments: const <String, Object?>{'text': 'what is the time?'},
          procedureNodeId: procedureNodeId,
        );

    Future<void> driveTypicalRun() async {
      await recorder.start(startInfo());
      await recorder.recordPrimitiveCall(
        'recall',
        const <String, Object?>{'text': 'time'},
        const <String, Object?>{'nodes': <Object?>[]},
        elapsedMs: 9,
      );
      recorder.note(
        TrailNote(category: 'progress', recordedAt: clock),
      );
      await recorder.recordPrimitiveCall(
        'llm',
        const <String, Object?>{'prompt': 'p'},
        const <String, Object?>{
          'text': 'it is noon',
          'report': <String, Object?>{'tokensIn': 40, 'tokensOut': 12},
        },
      );
    }

    test('full lifecycle round-trips against the store', () async {
      await driveTypicalRun();
      clock = clock.add(const Duration(milliseconds: 30));
      final record = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'answered from memory',
        ),
      );

      expect(record.procedureId, 'answer_with_memory_v1');
      expect(record.runId, 'r_int_1');
      expect(record.status, TrailOutcomeStatus.accepted);
      // The recorder's own view and the store agree on the final node.
      final stored = await memory.get(record.runNodeId);
      expect(stored, isNotNull);
      expect(stored!.values['status'], 'accepted');
    });

    test('trail entries appear in order when read back from the store',
        () async {
      await driveTypicalRun();
      final record = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'done',
        ),
      );

      // Read the trail straight out of the store — not the recorder's
      // in-memory mirror. The order is what was durably appended.
      final entries = await memory.readTrail(record.trailId).toList();
      expect(
        entries.map((e) => e.kind),
        <TrailEntryKind>[
          TrailEntryKind.invocation,
          TrailEntryKind.primitiveCall, // recall
          TrailEntryKind.note, // progress
          TrailEntryKind.primitiveCall, // llm
          TrailEntryKind.outcome, // synthesised by closeTrail
        ],
      );
      // The primitive calls kept their order.
      final calls = entries
          .where((e) => e.kind == TrailEntryKind.primitiveCall)
          .map((e) => e.payload['primitive'])
          .toList();
      expect(calls, <String>['recall', 'llm']);
      // The outcome line carries the run's status + summary.
      final outcome = entries.last;
      expect(outcome.payload['status'], 'accepted');
      expect(outcome.payload['summary'], 'done');
    });

    test('inflight stack reflects the running procedure mid-run', () async {
      await recorder.start(startInfo());

      // The run is open: it must be visible on `inflight` and absent
      // from `recent_runs`.
      final inflight = await memory.stacks.peek(inflightStackName);
      expect(inflight, hasLength(1));
      expect(inflight.single.nodeId, recorder.inflightMarkerId);

      final marker = await memory.get(inflight.single.nodeId);
      expect(marker, isNotNull);
      expect(marker!.values['status'], 'running');
      expect(marker.values['procedureId'], 'answer_with_memory_v1');
      expect(marker.values['runId'], 'r_int_1');

      expect(await memory.stacks.peek(recentRunsStackName), isEmpty);
    });

    test('on completion the run lands in recent_runs and leaves inflight',
        () async {
      await driveTypicalRun();
      final markerId = recorder.inflightMarkerId;
      clock = clock.add(const Duration(milliseconds: 50));
      final record = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'done',
        ),
      );

      // inflight is empty: the running marker was removed.
      final inflight = await memory.stacks.peek(inflightStackName);
      expect(inflight, isEmpty);
      // The marker node still exists by id (membership removal never
      // deletes the underlying node) — only its stack entry is gone.
      expect(await memory.get(markerId), isNotNull);

      // recent_runs now holds the authoritative final run.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, record.runNodeId);

      final finalNode = await memory.get(recent.single.nodeId);
      expect(finalNode, isNotNull);
      expect(finalNode!.values['status'], 'accepted');
      expect(finalNode.values['summary'], 'done');
      // The accumulated effort (one llm call, 40+12 tokens) reached the
      // stored node.
      final effort = finalNode.values['effort']! as Map<String, Object?>;
      expect(effort['llmCalls'], 1);
      expect(effort['inputTokens'], 40);
      expect(effort['outputTokens'], 12);
      expect(effort['memoryReads'], 1); // the recall
      // Wall clock measured from the injected clock (30+? — measured as
      // the elapsed between start and complete).
      expect(effort['wallClockMs'], 50);
    });

    test('two sequential runs each land independently in recent_runs',
        () async {
      // First run.
      await driveTypicalRun();
      final first = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'first',
        ),
      );

      // A fresh recorder for the second run (engine builds one per run).
      final recorder2 = RunRecorder(memory, now: now);
      await recorder2.start(
        RunStart(
          procedureId: 'answer_with_memory_v1',
          version: 1,
          runId: 'r_int_2',
          arguments: const <String, Object?>{'text': 'again'},
        ),
      );
      // While run 2 is open it is the only thing on inflight.
      final midInflight = await memory.stacks.peek(inflightStackName);
      expect(midInflight, hasLength(1));
      expect(midInflight.single.nodeId, recorder2.inflightMarkerId);

      final second = await recorder2.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.rejected,
          summary: 'second',
        ),
      );

      // Both runs are on recent_runs; inflight is clear.
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
      final recent = await memory.stacks.peek(recentRunsStackName);
      final recentIds = recent.map((e) => e.nodeId).toSet();
      expect(recentIds, <NodeId>{first.runNodeId, second.runNodeId});
    });

    test('derived_from edge is drawn when the procedure is a memory node',
        () async {
      final procNode = NodeId.generate();
      await recorder.start(startInfo(procedureNodeId: procNode));
      final record = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'done',
        ),
      );
      final edges = await memory.edgesOf(record.runNodeId);
      final derived =
          edges.where((e) => e.type == EdgeType.derivedFrom).toList();
      expect(derived, hasLength(1));
      expect(derived.single.to, procNode);
    });
  });
}

// ── Stateful in-memory doubles ──────────────────────────────────────
//
// These model just enough of the store for the recorder's writes to be
// read back. Unimplemented members fall through to `noSuchMethod`.

class _StoredEdge {
  _StoredEdge(this.from, this.type, this.to);
  final NodeId from;
  final EdgeType type;
  final NodeId to;
}

/// In-memory `TomBrainMemoryClient` modelling nodes, trails and edges.
class _InMemoryMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};
  final List<_StoredEdge> _edges = <_StoredEdge>[];

  @override
  StackApi get stacks => _stacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('appendTrail on an unopened trail: $id');
    }
    if (_closedTrails.contains(id)) {
      throw StateError('appendTrail on a closed trail: $id');
    }
    entries.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('closeTrail on an unopened trail: $id');
    }
    // Real memory synthesises the `outcome` JSONL line at close — mirror
    // that so a `readTrail` returns the full, ordered run.
    entries.add(TrailEntry.outcome(outcome));
    _closedTrails.add(id);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final entries = _trails[id];
    if (entries == null) {
      return Stream<TrailEntry>.error(
        StateError('readTrail on an unknown trail: $id'),
      );
    }
    return Stream<TrailEntry>.fromIterable(List<TrailEntry>.of(entries));
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async => <Node>[
        for (final id in ids)
          if (_nodes[id] case final Node n) n,
      ];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    _edges.add(_StoredEdge(from, type, to));
    return EdgeId.generate();
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      <Edge>[
        for (final e in _edges)
          if (_matchesDirection(e, id, direction) &&
              (types == null || types.contains(e.type)))
            Edge(id: EdgeId.generate(), from: e.from, to: e.to, type: e.type),
      ];

  bool _matchesDirection(_StoredEdge e, NodeId id, EdgeDirection direction) {
    switch (direction) {
      case EdgeDirection.outgoing:
        return e.from == id;
      case EdgeDirection.incoming:
        return e.to == id;
      case EdgeDirection.both:
        return e.from == id || e.to == id;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// In-memory `StackApi` modelling per-stack active-entry lists.
class _InMemoryStacks implements StackApi {
  final Map<String, List<StackEntry>> _stacks = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_stacks[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _stacks[name] ?? const <StackEntry>[];
    final active = entries
        .where((e) => e.status == StackEntryStatus.active)
        .toList(growable: false);
    return active.length <= k ? active : active.sublist(0, k);
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _stacks[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _stacks[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
