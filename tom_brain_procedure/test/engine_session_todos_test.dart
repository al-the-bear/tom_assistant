// Session-scoped todo persistence (umbrella Hard principle 6 — "nothing is
// ever lost" — applied to the brain's working todo list).
//
// A `TodoStore` is loop scratch (never persisted to memory), but the user's
// working todo list must survive from one prompt to the next *within the same
// conversation*: it is session scratch, not run scratch. The engine builds a
// fresh `ToolContext` per run, so if every context defaulted to a fresh store
// the list would reset on every prompt. The engine therefore holds a
// process-lifetime [SessionTodoStores] registry and binds each run's
// `ToolContext.todos` to the store of the run's `ProcedureInvocation.sessionId`
// — so every run of one session shares one list, different sessions stay
// isolated, and a turn-less / internal run (no session id) keeps the old
// run-scoped behaviour (a fresh store per run).

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        Node,
        NodeId,
        Scope,
        StackEntry,
        StackEntryId,
        StackEntryStatus,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  late _TrailOnlyMemory memory;
  late _StubSubstrate substrate;

  setUp(() {
    memory = _TrailOnlyMemory();
    substrate = _StubSubstrate();
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 11, 12, 0, 0),
      );

  // Appends one todo, then returns how many the run-visible list now holds.
  // Run repeatedly under one session id the count climbs (the list persists);
  // under a fresh session (or no session) it stays 1 (a fresh list per run).
  LoadedProcedure addAndCountProcedure() => _procedure('todo_add_count_v1', '''
import '${BridgeLibraries.toolLibrary}';

Future<Object?> run(inputs) async {
  await tool.invoke('todo.add', {'text': 'item'});
  final listed = await tool.invoke('todo.list', {});
  final todos = (listed['result'] as Map)['todos'] as List;
  return {'count': todos.length};
}
''');

  Future<int?> runCount(ProcedureEngine engine, {String? sessionId}) async {
    final outcome = await engine
        .invoke(
          ProcedureInvocation(
            procedureId: 'todo_add_count_v1',
            sessionId: sessionId,
          ),
        )
        .outcome;
    expect(outcome.status, TrailOutcomeStatus.accepted);
    return outcome.result?.output<int>('count');
  }

  group('engine session-scoped todos', () {
    test('two runs of one session share the todo list', () async {
      final engine = engineFor(<LoadedProcedure>[addAndCountProcedure()]);

      expect(await runCount(engine, sessionId: 'session-a'), 1);
      expect(
        await runCount(engine, sessionId: 'session-a'),
        2,
        reason: 'the second run of the same session sees the first todo',
      );
      expect(await runCount(engine, sessionId: 'session-a'), 3);
    });

    test('different sessions keep separate todo lists', () async {
      final engine = engineFor(<LoadedProcedure>[addAndCountProcedure()]);

      expect(await runCount(engine, sessionId: 'session-a'), 1);
      expect(
        await runCount(engine, sessionId: 'session-b'),
        1,
        reason: 'session-b starts empty — it does not see session-a todos',
      );
      expect(
        await runCount(engine, sessionId: 'session-a'),
        2,
        reason: 'session-a still has its own list',
      );
    });

    test(
      'a session-less (internal / dream) run gets a fresh list each run',
      () async {
        final engine = engineFor(<LoadedProcedure>[addAndCountProcedure()]);

        expect(await runCount(engine), 1);
        expect(
          await runCount(engine),
          1,
          reason: 'no session id ⇒ run-scoped, ephemeral store as before',
        );
      },
    );

    test('the engine exposes its process-lifetime session registry', () async {
      final engine = engineFor(<LoadedProcedure>[addAndCountProcedure()]);

      await runCount(engine, sessionId: 'session-a');
      final store = engine.sessionTodoStores.peek('session-a');
      expect(
        store,
        isNotNull,
        reason: 'the session store is readable for the inspector seam',
      );
      expect(store!.list(), hasLength(1));

      expect(engine.sessionTodoStores.peek('never-seen'), isNull);
    });

    test('clearing a session empties its list for the next run', () async {
      final engine = engineFor(<LoadedProcedure>[addAndCountProcedure()]);

      expect(await runCount(engine, sessionId: 'session-a'), 1);
      expect(await runCount(engine, sessionId: 'session-a'), 2);

      expect(engine.sessionTodoStores.clearSession('session-a'), isTrue);
      expect(
        await runCount(engine, sessionId: 'session-a'),
        1,
        reason: 'after a clear the list starts fresh',
      );
      expect(engine.sessionTodoStores.clearSession('never-seen'), isFalse);
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

/// A substrate client whose `llm` completes with a tiny answer; this suite
/// issues no `sub.llm`, so it is only a structural collaborator.
class _StubSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmEvent> completeStream(LlmCall call) =>
      Stream<LlmEvent>.fromIterable(<LlmEvent>[
        const LlmTextDelta('ok'),
        LlmRunCompleted(
          callId: 'c',
          wire: CapturedWirePrompt(
            body: 'ANCHOR',
            anchorHash: 'sha256:anchor',
            roleId: call.roleId,
          ),
          report: const LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'sha256:anchor',
            promptHash: 'pr',
            tokensIn: 1,
            tokensOut: 1,
            retries: 0,
            wallClockMs: 1,
          ),
        ),
      ]);

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

/// A minimal `TomBrainMemoryClient` that backs only the run recorder's trail +
/// run-node writes — enough for the engine to record a run. This suite uses no
/// `recall` / memory tools, so the rest is left to `noSuchMethod`.
class _TrailOnlyMemory implements TomBrainMemoryClient {
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
