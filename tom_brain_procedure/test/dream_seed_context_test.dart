// A dreaming lane fired by the cadence carries no inbound prompt, so the
// scheduled fire path supplies no `source` seed. The dream agents that recall
// around a seed (`dream_extract_v1`, `dream_connect_v1`, …) declare
// `source` as a *required* input, so firing them with empty inputs crashes the
// body at its first `inputs.get('source')` with `no input named "source"`
// before any memory/LLM work — which is exactly what was observed live on
// bomber (9 of 11 lanes errored, the 2 that never read `source` survived).
//
// The fix seeds `source` at the single dream-fire seam
// (`FreeTimeScheduler.triggerMaintenance`), mirroring the `recentRuns` /
// `priorTurns` / `compactedSummary` enrichments already done there. A dream
// "dreams about what is on the brain's mind": the seed is drawn, best-effort,
// from the mind-state stacks (`interests`, then `questions_open`), falling back
// to [defaultDreamSeed] when neither yields a salient term. An explicit
// `source` (the test harness path, a manual invocation) always wins — the seam
// never clobbers a caller-supplied seed.
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. A dream lane with a required `source` fired with NO arguments is
//      `accepted` (not `errored`) and receives the top `interests` salient
//      term as its seed.
//   2. With no `interests` entry, the seed falls back to the top
//      `questions_open` term.
//   3. With neither stack populated, the seed is the stable [defaultDreamSeed]
//      constant — the lane still runs rather than crashing.
//   4. An explicit `source` argument is never overwritten by the seam.
//
// Runs on a small in-memory `TomBrainMemoryClient` double (mirroring
// recent_runs_lane_context_test) — no on-disk vec0 store needed.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, EdgeType, NodeDraft, NodeId, ProcedureRunRef, Scope, StackEntry,
        StackEntryId, TrailEntry, TrailId, TrailOutcome;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

const _laneId = 'dream_seed_stub_v1';

void main() {
  late _SeedMemory memory;

  setUp(() {
    memory = _SeedMemory();
  });

  ProcedureEngine engineWith(LoadedProcedure procedure) => ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[procedure]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(_NoopSubstrate()),
        now: () => DateTime.utc(2026, 6, 30, 12, 0, 0),
      );

  FreeTimeScheduler schedulerWith(LoadedProcedure procedure) => FreeTimeScheduler(
        coordinator: RunCoordinator(),
        memory: memory,
        workFactory: (_) => null,
        engine: engineWith(procedure),
      );

  /// Pushes a node carrying a [salient] text field onto [stackName], as the
  /// dispatcher does when it parks an interest / open question on a mind-state
  /// stack.
  Future<void> seedStack({
    required String stackName,
    required String typeName,
    required String field,
    required String salient,
  }) async {
    final id = await memory.persist(
      NodeDraft(
        typeName: typeName,
        values: <String, Object?>{field: salient},
      ),
      scope: const Scope(producer: 'test'),
    );
    await memory.stacks.push(stackName, id);
  }

  test(
      'a dream lane fired with no source is accepted and seeded from the top '
      'interests entry', () async {
    await seedStack(
      stackName: 'interests',
      typeName: 'InterestItem',
      field: 'title',
      salient: 'distributed consensus',
    );

    final outcome =
        await schedulerWith(_seedEchoStub()).triggerMaintenance(_laneId);

    expect(outcome.status, TrailOutcomeStatus.accepted,
        reason: 'the seam supplied the required source, so no crash');
    expect(outcome.result!.output<String>('seedReceived'),
        'distributed consensus');
  });

  test('with no interests, the seed falls back to the top open question',
      () async {
    await seedStack(
      stackName: 'questions_open',
      typeName: 'Question',
      field: 'statement',
      salient: 'why did the build regress',
    );

    final outcome =
        await schedulerWith(_seedEchoStub()).triggerMaintenance(_laneId);

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<String>('seedReceived'),
        'why did the build regress');
  });

  test('with no mind-state stacks, the seed is the stable default', () async {
    final outcome =
        await schedulerWith(_seedEchoStub()).triggerMaintenance(_laneId);

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<String>('seedReceived'), defaultDreamSeed);
  });

  test('an explicit source argument is never overwritten by the seam',
      () async {
    await seedStack(
      stackName: 'interests',
      typeName: 'InterestItem',
      field: 'title',
      salient: 'distributed consensus',
    );

    final outcome = await schedulerWith(_seedEchoStub()).triggerMaintenance(
      _laneId,
      arguments: const <String, Object?>{'source': 'explicit seed'},
    );

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<String>('seedReceived'), 'explicit seed');
  });
}

/// A stub dreaming lane that requires `source` (like the real recall-seeded
/// agents) and echoes it back, so the suite can assert which seed the fire seam
/// supplied. It does the same `inputs.get('source')` read whose absence crashed
/// the live lanes.
LoadedProcedure _seedEchoStub() {
  const body = r'''
Future<Object?> run(inputs) async {
  final source = inputs.get('source');
  return {'seedReceived': source};
}
''';
  final source = '''
/// @procedure
/// id: $_laneId
/// version: 1
/// summary: a stub dreaming lane that echoes the seed it was fired with
/// successCriterion: returns the source it received
/// budget: { wallClockMs: 60000 }
/// inputs:
///   - { name: source, type: String, required: true }
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$_laneId.dart'),
      source: source,
    ),
  );
}

class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A small stateful `TomBrainMemoryClient`: enough for the recorder's trail
/// writes plus the seam's mind-state read-back (`stacks.peek` + `get`).
class _SeedMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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
