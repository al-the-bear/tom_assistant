// Turn-correlation thread-through at the engine (logging-spec §3 / §9; step
// #10.2 of `tom_brain_logging.md`).
//
// `ProcedureEngine.invoke` builds one [TurnContext] per turn from the
// invocation's `turnId` and threads it into every (possibly nested) run's
// substrate bridge. Every `sub.send(...)` the turn issues is therefore stamped
// with the turn's `turnId` and a `callSeq` that increments across the whole
// turn — including across sub-procedures, since the one counter is shared.
//
// A turn without a `turnId` (an internal / free-time / dream invocation) builds
// no context, so its LLM calls stay unstamped.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, TurnId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _StatefulMemory memory;
  late _RecordingSubstrate substrate;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _RecordingSubstrate();
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(
          substrate,
          // Every script here completes through `sub.send`, which selects a
          // route by name (§ 7.4) and so needs a resolver bound.
          routeChainOf: (_) => const <RouteEntry>[
            RouteEntry(providerId: 'p', model: 'm'),
          ],
        ),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  group('ProcedureInvocation.turnId', () {
    test('defaults to null and carries the supplied id', () {
      expect(ProcedureInvocation(procedureId: 'p_v1').turnId, isNull);
      final turnId = TurnId.generate();
      expect(
        ProcedureInvocation(procedureId: 'p_v1', turnId: turnId).turnId,
        same(turnId),
      );
    });
  });

  group('engine threads the turn onto substrate calls', () {
    test(
      'a turn stamps turnId + an incrementing callSeq on each llm call',
      () async {
        final engine = engineFor(<LoadedProcedure>[
          _procedure('two_calls_v1', '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.send('first', llmRoute: 'fast');
  await sub.send('second', llmRoute: 'fast');
  return 1;
}
'''),
        ]);

        final turnId = TurnId.generate();
        final outcome = await engine
            .invoke(
              ProcedureInvocation(procedureId: 'two_calls_v1', turnId: turnId),
            )
            .outcome;

        expect(outcome.status, TrailOutcomeStatus.accepted);
        expect(substrate.calls, hasLength(2));
        expect(substrate.calls[0].turnId, equals(turnId));
        expect(substrate.calls[0].callSeq, equals(1));
        expect(substrate.calls[1].turnId, equals(turnId));
        expect(substrate.calls[1].callSeq, equals(2));
      },
    );

    test(
      'the callSeq counter spans a nested runProcedure within one turn',
      () async {
        final engine = engineFor(<LoadedProcedure>[
          _procedure('parent_v1', '''
import '${BridgeLibraries.substrateLibrary}';
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  await sub.send('parent call', llmRoute: 'fast');
  return await runProcedure('child_v1', inputs);
}
'''),
          _procedure('child_v1', '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.send('child call', llmRoute: 'fast');
  return {'v': 1};
}
'''),
        ]);

        final turnId = TurnId.generate();
        final outcome = await engine
            .invoke(
              ProcedureInvocation(procedureId: 'parent_v1', turnId: turnId),
            )
            .outcome;

        expect(outcome.status, TrailOutcomeStatus.accepted);
        expect(substrate.calls, hasLength(2));
        // Both the parent's and the nested child's call share the turn id …
        expect(substrate.calls[0].turnId, equals(turnId));
        expect(substrate.calls[1].turnId, equals(turnId));
        // … and the one counter advanced across the run boundary.
        expect(substrate.calls[0].callSeq, equals(1));
        expect(substrate.calls[1].callSeq, equals(2));
      },
    );

    test('a turn-less invocation leaves the llm calls unstamped', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('internal_v1', '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.send('internal', llmRoute: 'fast');
  return 1;
}
'''),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'internal_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(substrate.calls.single.turnId, isNull);
      expect(substrate.calls.single.callSeq, isNull);
    });
  });
}

LoadedProcedure _procedure(String id, String body, {int version = 1}) {
  final source =
      '''
/// @procedure
/// id: $id
/// version: $version
/// summary: a test procedure
/// successCriterion: returns a value
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

/// A `TomBrainSubstrateClient` that records every [LlmCall] and returns a
/// trivial one-chunk completed stream so each `sub.send(...)` resolves.
class _RecordingSubstrate implements TomBrainSubstrateClient {
  final List<LlmCall> calls = <LlmCall>[];

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    calls.add(call);
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      const LlmTextDelta('ok'),
      const LlmRunCompleted(
        callId: 'c',
        report: LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'a',
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ]);
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
    vec: Vec.zero(1),
    modelIdentity: const EmbeddingModelIdentity(
      providerId: 'p',
      modelId: 'm',
      dims: 1,
      normalized: true,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── A stateful in-memory `TomBrainMemoryClient` (copied from the engine
//    acceptance suite — just enough for the recorder's writes). ──────────
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
  }) async => EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
