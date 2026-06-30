// A dreaming lane fired by the cadence carries no inbound prompt, so the
// scheduled fire path supplies no per-pass clock. `dream_decay_v1` declares
// `nowMs` (the pass clock as epoch milliseconds) as a *required* input and
// reads it (`inputs.get<int>('nowMs')`) to compute coldness ages — the body
// has no access to a wall clock inside the d4rt sandbox, so the caller must
// stamp the instant the verdict is measured against. Firing the lane with
// empty inputs therefore crashes the body at that read with `no input named
// "nowMs"` — exactly what was observed live (most decay lanes errored).
//
// The fix seeds `nowMs` at the single dream-fire seam
// (`FreeTimeScheduler.triggerMaintenance`), mirroring the `source` seed and the
// `recentRuns` / `priorTurns` / `compactedSummary` enrichments already done
// there. The instant comes from the scheduler's injected [Clock] — the same
// no-global-clock injection rule the rest of the brain follows. An explicit
// `nowMs` (a test harness, a deep-lane driver replaying a fixed instant) always
// wins — the seam never clobbers a caller-supplied stamp.
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. A dream lane with a required `nowMs` fired with NO arguments is
//      `accepted` (not `errored`) and receives the injected clock's `nowMs()`.
//   2. An explicit `nowMs` argument is never overwritten by the seam.
//
// Runs on a small in-memory `TomBrainMemoryClient` double (mirroring
// dream_seed_context_test) — no on-disk vec0 store needed.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainTime,
        EdgeId,
        EdgeType,
        MutableTestClock,
        NodeDraft,
        NodeId,
        ProcedureRunRef,
        Scope,
        StackEntry,
        StackEntryId,
        TrailEntry,
        TrailId,
        TrailOutcome;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

const _laneId = 'dream_clock_stub_v1';
const int _fixedNowMs = 1782000000000; // a stable, recognizable instant

void main() {
  late _ClockMemory memory;

  setUp(() {
    memory = _ClockMemory();
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
      'a dream lane fired with no nowMs is accepted and seeded from the '
      'injected clock', () async {
    final outcome =
        await schedulerWith(_clockEchoStub()).triggerMaintenance(_laneId);

    expect(outcome.status, TrailOutcomeStatus.accepted,
        reason: 'the seam supplied the required nowMs, so no crash');
    expect(outcome.result!.output<int>('nowReceived'), _fixedNowMs);
  });

  test('an explicit nowMs argument is never overwritten by the seam', () async {
    const explicit = 999000000000;
    final outcome = await schedulerWith(_clockEchoStub()).triggerMaintenance(
      _laneId,
      arguments: const <String, Object?>{'nowMs': explicit},
    );

    expect(outcome.status, TrailOutcomeStatus.accepted);
    expect(outcome.result!.output<int>('nowReceived'), explicit);
  });
}

/// A stub dreaming lane that requires `nowMs` (like `dream_decay_v1`) and echoes
/// it back, so the suite can assert which stamp the fire seam supplied. It does
/// the same `inputs.get<int>('nowMs')` read whose absence crashed the live
/// decay lanes.
LoadedProcedure _clockEchoStub() {
  const body = r'''
Future<Object?> run(inputs) async {
  final nowMs = inputs.get('nowMs');
  return {'nowReceived': nowMs};
}
''';
  final source = '''
/// @procedure
/// id: $_laneId
/// version: 1
/// summary: a stub dreaming lane that echoes the nowMs it was fired with
/// successCriterion: returns the nowMs it received
/// budget: { wallClockMs: 60000 }
/// inputs:
///   - { name: nowMs, type: int, required: true }
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
/// writes (the seam reads no stacks for the clock seed).
class _ClockMemory implements TomBrainMemoryClient {
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
