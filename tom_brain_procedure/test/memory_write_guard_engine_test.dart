// § 5.4 — the per-run NON-FATAL write guard, driven end-to-end through the
// engine (the counterpart to the unit-level `memory_write_guard_test.dart` and
// the bridge-level `memory_bridge_test.dart` skip group).
//
// Unlike the fatal `BudgetLedger` (`c51_budget_enforcement_test.dart`), reaching
// a write cap is **not** an error: the offending write is skipped (its side
// effect never runs), a `memory_write_skipped` note lands on the run trail, and
// the run continues — closing `accepted`, with its result intact. This is the
// behaviour the "who are you" bug needed: a runaway memory-write loop must never
// silence an answer the procedure already produced.
//
// These tests pin three promises:
//
//   1. a write past the process write cap is skipped, the run still closes
//      `accepted`, and a `memory_write_skipped` note records the skip;
//   2. the skip note carries the offending primitive + outcome so an operator
//      can see "the memory budget was reached" without the run failing;
//   3. with the default (virtually-unlimited) limits, a realistic write count
//      runs unaffected — no skip, no note.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _StatefulMemory memory;
  late _EmbeddingSubstrate substrate;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _EmbeddingSubstrate();
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    MemoryWriteLimits limits = MemoryWriteLimits.standard,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        memoryWriteLimits: limits,
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  // A procedure that writes twice and always returns a result — modelling the
  // answer-then-persist shape where the answer is independent of the writes.
  LoadedProcedure twoWrites() => _procedure(
        'two_writes_v1',
        '''
import '${BrainBridges.memoryLibrary}';

Future<Object?> run(inputs) async {
  await mem.persist('Event', {'summary': 'first'}, producer: 'p');
  await mem.persist('Conclusion', {'statement': 'second'}, producer: 'p');
  return {'done': true};
}
''',
        budget: '{ wallClockMs: 60000 }',
      );

  group('§5.4-1 a write past the cap is skipped, run still accepted', () {
    test('a second persist past maxWritesPerRun:1 is skipped, not fatal',
        () async {
      final engine = engineFor(
        <LoadedProcedure>[twoWrites()],
        limits: const MemoryWriteLimits(maxWritesPerRun: 1),
      );

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'two_writes_v1'))
          .outcome;

      // NON-FATAL: the run completes with its result despite the skipped write.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('done'), isTrue);

      // Only the first persist reached the store.
      expect(memory.persistCalls, 1);

      // The run is durably recorded — never lost.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
    });
  });

  group('§5.4-2 the skip is reported on the trail', () {
    test('a memory_write_skipped note records the offending primitive',
        () async {
      final engine = engineFor(
        <LoadedProcedure>[twoWrites()],
        limits: const MemoryWriteLimits(maxWritesPerRun: 1),
      );

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'two_writes_v1'))
          .outcome;

      final notes = outcome.entries
          .where((e) =>
              e.kind == TrailEntryKind.note &&
              e.payload['category'] == 'memory_write_skipped')
          .toList();
      expect(notes, hasLength(1));

      final payload = notes.single.payload['payload']! as Map<String, Object?>;
      expect(payload['primitive'], 'persist');
      expect(payload['outcome'], MemoryWriteOutcome.skipWriteCap.name);
    });
  });

  group('§5.4-3 default limits leave a realistic write count unaffected', () {
    test('two writes under the standard caps produce no skip and no note',
        () async {
      final engine = engineFor(<LoadedProcedure>[twoWrites()]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'two_writes_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(memory.persistCalls, 2);
      final notes = outcome.entries.where((e) =>
          e.kind == TrailEntryKind.note &&
          e.payload['category'] == 'memory_write_skipped');
      expect(notes, isEmpty);
    });
  });
}

/// Builds a [LoadedProcedure] from [body] with a configurable [budget] block.
LoadedProcedure _procedure(
  String id,
  String body, {
  required String budget,
  int version = 1,
}) {
  final source = '''
/// @procedure
/// id: $id
/// version: $version
/// summary: a test procedure
/// successCriterion: returns a value
/// budget: $budget
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$id.dart'),
      source: source,
    ),
  );
}

// ── A substrate whose only live primitive is embed ──────────────────
class _EmbeddingSubstrate implements TomBrainSubstrateClient {
  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'm',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read back,
// and counts the *procedure-authored* `persist` calls so a test can prove a
// skipped write never reached the store. The recorder's own run-record writes
// (the run-start marker + run-close record, both `procedureRunNodeType`) bypass
// the per-run write guard, so they are excluded from `persistCalls`.
// Mirrors the double in `c51_budget_enforcement_test.dart`.
class _StatefulMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  int persistCalls = 0;

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
    // The recorder's own run-record writes bypass the guard; only count
    // procedure-authored persists so a skipped write is observable here.
    if (draft.typeName != procedureRunNodeType) persistCalls++;
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
