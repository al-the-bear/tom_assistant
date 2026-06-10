// Q-C.51.1 — procedure-budget enforcement end-to-end (PE-8).
//
// Before this step the header `budget` block was parsed and validated but
// only its `wallClockMs` was enforced (by the `StepDeadline`); the
// token / tool-call / memory-write caps were dead data. PE-8 requires a
// bridged call that would exceed an applicable budget to be refused with a
// typed `procedure.budget.exceeded` the procedure can catch and adapt to.
//
// These tests drive the engine the way the dispatcher does — `invoke`, read
// `run.outcome` — and pin three promises:
//
//   1. an uncaught budget refusal closes the run `budgetExceeded`, carrying
//      the typed error and a `procedure.budget.exceeded` error entry, and the
//      run is still durably recorded (no run is ever lost);
//   2. a procedure that catches the refusal continues and resolves normally;
//   3. a procedure whose budget enforces nothing extra runs unaffected.

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

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  group('Q-C.51.1-1 an uncaught budget refusal closes budgetExceeded', () {
    test('a second tool call past a toolCalls:1 budget is refused', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'greedy_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.embed('first');   // within budget
  await sub.embed('second');  // refused — exceeds toolCalls:1
  return 1;
}
''',
          budget: '{ wallClockMs: 60000, toolCalls: 1 }',
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'greedy_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.budgetExceeded);
      expect(outcome.result, isNull);
      expect(outcome.error, isA<ProcedureBudgetExceeded>());
      final refusal = outcome.error! as ProcedureBudgetExceeded;
      expect(refusal.dimension, BudgetDimension.toolCalls);
      expect(refusal.limit, 1);

      // The refusal is recorded under the typed error kind.
      final errors =
          outcome.entries.where((e) => e.kind == TrailEntryKind.error).toList();
      expect(errors, hasLength(1));
      expect(errors.single.payload['errorKind'], 'procedure.budget.exceeded');

      // The first (allowed) embed landed as a primitiveCall; the refused one
      // never executed, so it is not on the trail as a successful call.
      final calls = outcome.entries
          .where((e) => e.kind == TrailEntryKind.primitiveCall)
          .toList();
      expect(calls, hasLength(1));

      // The run is still durably recorded — a budget abort is not a lost run.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, outcome.record.runNodeId);
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
    });
  });

  group('Q-C.51.1-2 a procedure can catch the refusal and adapt', () {
    test('catching procedure.budget.exceeded lets the run resolve accepted',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'adaptive_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.embed('first');
  try {
    await sub.embed('second'); // refused
    return {'adapted': false};
  } catch (e) {
    return {'adapted': true};   // caught the refusal, carried on
  }
}
''',
          budget: '{ wallClockMs: 60000, toolCalls: 1 }',
        ),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'adaptive_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<bool>('adapted'), isTrue);
    });
  });

  group('Q-C.51.1-3 a budget with no extra caps runs unaffected', () {
    test('a wall-clock-only budget never refuses a tool call', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'free_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.embed('a');
  await sub.embed('b');
  await sub.embed('c');
  return 1;
}
''',
          budget: '{ wallClockMs: 60000 }',
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'free_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.record.effort.toolCalls, 3);
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
// Models just enough of the store for the recorder's writes to be read back.
// Mirrors the double in `procedure_engine_test.dart`.
class _StatefulMemory implements TomBrainMemoryClient {
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
