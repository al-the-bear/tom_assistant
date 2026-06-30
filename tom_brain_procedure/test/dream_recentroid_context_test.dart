// A dreaming lane fired by the cadence carries no inbound prompt, so the
// scheduled fire path supplies no per-pass arguments of its own. Unlike the
// other dream agents (which declare `source`, or `nowMs` for decay),
// `dream_recentroid_v1` declares a *second* required input — `forKey`, the
// node-type family whose centroid it recomputes — and reads it
// (`inputs.get('forKey')`) before any work. Firing the lane with no `forKey`
// therefore crashes the body at that read with `no input named "forKey"` —
// exactly what was observed live (`dream_recentroid_v1 crashed: ... no input
// named "forKey"`).
//
// The fix seeds `forKey` at the single dream-fire seam
// (`FreeTimeScheduler.triggerMaintenance`), mirroring the `source` and `nowMs`
// seeds already done there. The target family is drawn from the store's own
// node-type catalogue (`memory.listNodeTypes()`) and rotated round-robin across
// successive firings, so every node-type family's centroid is recomputed over a
// full cadence cycle rather than always the same one. The seam is recentroid-
// specific (no other lane wants a `forKey`) and an explicit caller-supplied
// `forKey` (a test harness, a manual invocation) always wins.
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. The recentroid lane fired with NO arguments is `accepted` (not
//      `errored`) and receives a real node-type name from the catalogue.
//   2. Successive firings rotate through the catalogue (round-robin coverage),
//      so the seam does not pin one family forever.
//   3. An explicit `forKey` argument is never overwritten by the seam.
//   4. A non-recentroid lane is NOT seeded a `forKey` (the seam is scoped).
//
// Runs on a small in-memory `TomBrainMemoryClient` double (mirroring
// dream_clock_context_test) whose `listNodeTypes()` returns a fixed catalogue —
// no on-disk vec0 store needed.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainTime,
        BrainVersion,
        EdgeId,
        EdgeType,
        EmbeddingPolicy,
        FieldSpec,
        FieldType,
        IndexPolicy,
        MutableTestClock,
        NodeDraft,
        NodeId,
        NodeTypeDecl,
        ProcedureRunRef,
        RetentionPolicy,
        Scope,
        StackEntry,
        StackEntryId,
        TrailEntry,
        TrailId,
        TrailOutcome,
        TrailOutcomeStatus;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

const _recentroidLaneId = 'dream_recentroid_v1';
const _otherLaneId = 'dream_other_stub_v1';
const int _fixedNowMs = 1782000000000;

// A small fixed catalogue, intentionally out of sorted order, so the test can
// prove the rotation is deterministic (sorted) rather than catalogue order.
const List<String> _catalogue = <String>['Event', 'Claim', 'Concept'];
const List<String> _sortedCatalogue = <String>['Claim', 'Concept', 'Event'];

void main() {
  late _RecentroidMemory memory;

  setUp(() {
    memory = _RecentroidMemory(typeNames: _catalogue);
  });

  ProcedureEngine engineWith(LoadedProcedure procedure) => ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[procedure]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(_NoopSubstrate()),
        now: () => DateTime.utc(2026, 6, 30, 12, 0, 0),
      );

  FreeTimeScheduler schedulerWith(LoadedProcedure procedure) =>
      FreeTimeScheduler(
        coordinator: RunCoordinator(),
        memory: memory,
        workFactory: (_) => null,
        engine: engineWith(procedure),
        clock: MutableTestClock(BrainTime.fromMs(_fixedNowMs)),
      );

  test(
      'the recentroid lane fired with no forKey is accepted and seeded a real '
      'node-type from the catalogue', () async {
    final outcome = await schedulerWith(_forKeyEchoStub(_recentroidLaneId))
        .triggerMaintenance(_recentroidLaneId);

    expect(outcome.status, TrailOutcomeStatus.accepted,
        reason: 'the seam supplied the required forKey, so no crash');
    expect(outcome.result!.output<String>('forKeyReceived'),
        _sortedCatalogue.first);
  });

  test('successive firings rotate the seeded forKey across the catalogue',
      () async {
    final scheduler = schedulerWith(_forKeyEchoStub(_recentroidLaneId));
    final seen = <String>[];
    for (var i = 0; i < _sortedCatalogue.length + 1; i++) {
      final outcome = await scheduler.triggerMaintenance(_recentroidLaneId);
      expect(outcome.status, TrailOutcomeStatus.accepted);
      seen.add(outcome.result!.output<String>('forKeyReceived')!);
    }
    // Three distinct families, then it wraps back to the first.
    expect(seen, <String>[..._sortedCatalogue, _sortedCatalogue.first]);
  });

  test('an explicit forKey argument is never overwritten by the seam',
      () async {
    const explicit = 'Question';
    final outcome = await schedulerWith(_forKeyEchoStub(_recentroidLaneId))
        .triggerMaintenance(
      _recentroidLaneId,
      arguments: const <String, Object?>{'forKey': explicit},
    );

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<String>('forKeyReceived'), explicit);
  });

  test('a non-recentroid lane is not seeded a forKey', () async {
    final outcome = await schedulerWith(_forKeyProbeStub(_otherLaneId))
        .triggerMaintenance(_otherLaneId);

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<bool>('hadForKey'), isFalse,
        reason: 'the forKey seam is scoped to the recentroid lane only');
  });
}

/// A stub dreaming lane that requires `forKey` (like `dream_recentroid_v1`) and
/// echoes it back, so the suite can assert which family the fire seam supplied.
/// It does the same `inputs.get('forKey')` read whose absence crashed the live
/// recentroid lane.
LoadedProcedure _forKeyEchoStub(String id) {
  const body = r'''
Future<Object?> run(inputs) async {
  final forKey = inputs.get('forKey');
  return {'forKeyReceived': forKey};
}
''';
  return _load(
    id: id,
    inputs: '''
/// inputs:
///   - { name: forKey, type: String, required: true }
''',
    body: body,
  );
}

/// A stub for a *non*-recentroid lane: it reads `forKey` defensively
/// (`getOrNull`) and reports whether one was present, proving the seam did not
/// seed it.
LoadedProcedure _forKeyProbeStub(String id) {
  const body = r'''
Future<Object?> run(inputs) async {
  return {'hadForKey': inputs.has('forKey')};
}
''';
  return _load(id: id, inputs: '', body: body);
}

LoadedProcedure _load({
  required String id,
  required String inputs,
  required String body,
}) {
  final source = '''
/// @procedure
/// id: $id
/// version: 1
/// summary: a stub dreaming lane used to prove the forKey fire seam
/// successCriterion: echoes what it was fired with
/// budget: { wallClockMs: 60000 }
$inputs$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$id.dart'),
      source: source,
    ),
  );
}

class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A small stateful `TomBrainMemoryClient` whose `listNodeTypes()` returns a
/// fixed catalogue — enough for the recorder's trail writes and the recentroid
/// fire seam's node-type lookup.
class _RecentroidMemory implements TomBrainMemoryClient {
  _RecentroidMemory({required List<String> typeNames})
      : _typeNames = List<String>.of(typeNames);

  final List<String> _typeNames;
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  @override
  StackApi get stacks => _stacks;

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async => <NodeTypeDecl>[
        for (final name in _typeNames) _decl(name),
      ];

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

/// A minimal `NodeTypeDecl` — only `typeName` matters to the fire seam.
NodeTypeDecl _decl(String typeName) => NodeTypeDecl(
      typeName: typeName,
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'statement': const FieldSpec(
          name: 'statement',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'test-model@v1',
        dimensions: 768,
        sourceFields: <String>['statement'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'statement'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: null,
        reinforcementResetsHorizon: true,
        demoteFromIndexes: true,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.mentions},
      allowedIncoming: const <EdgeType>{EdgeType.mentions},
    );

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
