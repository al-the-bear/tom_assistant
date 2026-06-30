// When a procedure body throws, the run closes `errored` — but for a long time
// the *cause* lived only in a separate `error` trail entry, never on the
// terminal outcome. So the operator's grep-friendly close-line
// (`sqlite_trail_store` A.84) and the `recent_runs` summary both showed a bare
// `outcome=errored` with no reason. Live, "most dream lanes are showing errors"
// with no visible cause was exactly this gap: the failure was recorded but not
// surfaced.
//
// The fix threads the thrown error's text + type (and a stack into the trail's
// `error` entry) into the errored `RunCompletion.summary` / `.details`, which
// `RunRecorder._completionOutcome` mirrors onto the closed `TrailOutcome`. The
// close-line then appends that summary for any non-`accepted` close, so the
// cause is visible in one line.
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. A body that THROWS closes `errored` and the closed `TrailOutcome`
//      summary carries the thrown error's text (not a bare "crashed").
//   2. The outcome `details` carry the structured `errorKind` / `errorType` /
//      `error`, so a machine reader (Observatory) can classify the failure.
//
// (A d4rt body cannot construct a `ProcedureResult` — `procedure_result_bridge`
// exposes only its read surface, and a body returns a plain `Map` the engine
// coerces to *success* — so the dream lanes fail exclusively by THROWING, which
// is the crash path exercised here. The engine's parallel `!result.isSuccess`
// errored close is defensive for non-d4rt return paths and is not reachable
// from a sandboxed body, so it has no d4rt-level test.)
//
// Runs on the same small in-memory `TomBrainMemoryClient` double the other
// engine unit suites use (no on-disk vec0 store needed); the double captures
// the `closeTrail` outcome so the assertions read what the operator would see.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        EdgeType,
        NodeDraft,
        NodeId,
        ProcedureRunRef,
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

const _crashLaneId = 'crash_stub_v1';
const _crashMarker = 'boom-diagnostic-marker';

void main() {
  late _CapturingMemory memory;

  setUp(() {
    memory = _CapturingMemory();
  });

  ProcedureEngine engineWith(LoadedProcedure procedure) => ProcedureEngine(
        resolver: ProcedureResolver(<LoadedProcedure>[procedure]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(_NoopSubstrate()),
        now: () => DateTime.utc(2026, 6, 30, 12, 0, 0),
      );

  test(
      'a crashing body closes errored with the thrown error text in the '
      'outcome summary and structured details', () async {
    final outcome = await engineWith(_crashStub())
        .invoke(ProcedureInvocation(procedureId: _crashLaneId))
        .outcome;

    expect(outcome.status, TrailOutcomeStatus.errored);

    final closed = memory.lastClosedOutcome!;
    expect(closed.status, TrailOutcomeStatus.errored);
    expect(closed.summary, contains(_crashMarker),
        reason: 'the thrown error text must reach the close-line summary');
    expect(closed.summary, contains('crashed'));
    expect(closed.details['errorKind'], isNotNull);
    expect(closed.details['errorType'], isNotNull);
    expect('${closed.details['error']}', contains(_crashMarker));
  });
}

/// A stub procedure whose body throws — the same shape that crashed the live
/// dream lanes (an uncaught error mid-execution), with a recognisable marker.
LoadedProcedure _crashStub() => _load(
      id: _crashLaneId,
      body: r'''
Future<Object?> run(inputs) async {
  throw Exception('boom-diagnostic-marker');
}
''',
    );

LoadedProcedure _load({required String id, required String body}) {
  final source = '''
/// @procedure
/// id: $id
/// version: 1
/// summary: a stub procedure used to prove error diagnostics surface the cause
/// successCriterion: closes with a diagnosable outcome
/// budget: { wallClockMs: 60000 }
$body
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

/// A small stateful `TomBrainMemoryClient` that captures the last `closeTrail`
/// outcome so the suite can assert what the operator's close-line would show.
class _CapturingMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// The outcome of the most recently closed trail.
  TrailOutcome? lastClosedOutcome;

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
    lastClosedOutcome = outcome;
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
