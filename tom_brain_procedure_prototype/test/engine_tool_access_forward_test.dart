// Engine-level tool-access forwarding (the trail half of the user's request:
// "tool calls … must be in the trails files, especially the live-trail").
//
// Every bridged tool call a run issues (`tool.list` / `tool.invoke`) is
// dispatched through the per-run [ToolBridge], which already emits a typed
// [ToolEvent] on each outcome. But that event carries no run identity — the
// `ToolContext` holds the budget / memory / surfaces, not the run's `runId`,
// the live `trailId`, or the turn it serves. The engine is the only place that
// knows that correlation, so — exactly as it does for the memory bridge (§5.6)
// — it wraps each emitted [ToolEvent] into a [ToolAccessRecord] carrying the
// run facts and hands it to the bound `toolAccessSink`.
//
// With no sink bound the engine wires no `onEvent` onto the run's tool bridge,
// so nothing is emitted and the run completes unchanged.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        FusionStrategy,
        DiversityStrategy,
        Node,
        NodeId,
        RecallMode,
        RecallQuery,
        RecallReport,
        RecallResult,
        Scope,
        StackEntryId,
        TrailId,
        TurnId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

void main() {
  late _RecallingMemory memory;
  late _StubSubstrate substrate;

  setUp(() {
    memory = _RecallingMemory();
    substrate = _StubSubstrate();
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    ToolAccessSink? toolAccessSink,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
        toolAccessSink: toolAccessSink,
      );

  // A procedure that lists tools, invokes one that runs (`memory.read`), and
  // invokes one that does not exist — exercising `ToolListed`, `ToolInvoked`,
  // and `ToolFailed` in one run.
  LoadedProcedure toolUsingProcedure() => _procedure(
        'tool_using_v1',
        '''
import '${BrainBridges.toolLibrary}';

Future<Object?> run(inputs) async {
  await tool.list();
  await tool.invoke('memory.read', {'text': 'q'});
  await tool.invoke('does.not.exist', {});
  return 1;
}
''',
      );

  group('ProcedureEngine tool-access forwarding', () {
    test(
        'a bound sink receives one record per tool event, run-correlated and '
        'turn-stamped', () async {
      final records = <ToolAccessRecord>[];
      final engine = engineFor(
        <LoadedProcedure>[toolUsingProcedure()],
        toolAccessSink: records.add,
      );

      final turnId = TurnId.generate();
      final run = engine.invoke(
        ProcedureInvocation(
          procedureId: 'tool_using_v1',
          turnId: turnId,
        ),
      );
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);

      // One record per emitted tool event, in call order.
      expect(records.map((r) => r.event.kind).toList(),
          <String>['tool.listed', 'tool.invoked', 'tool.failed'],
          reason: 'list → invoke(ok) → invoke(unknown)');

      for (final record in records) {
        expect(record.runId, run.runId, reason: 'run-correlated');
        expect(record.trailId, isNotNull,
            reason: 'the recorder trail is open when the bridge fires');
        expect(record.turnId, turnId.value, reason: 'turn-stamped');
        expect(record.event.occurredAt, DateTime.utc(2026, 6, 2, 12, 0, 0),
            reason: 'the bridge clock is the engine clock');
      }

      // The invoked record names the tool that ran and its group.
      final invoked = records[1].event as ToolInvoked;
      expect(invoked.name, 'memory.read');
      expect(invoked.group, 'memory');

      // The failed record names the unknown tool.
      final failed = records[2].event as ToolFailed;
      expect(failed.name, 'does.not.exist');
    });

    test('with no sink bound the engine forwards nothing', () async {
      final engine = engineFor(<LoadedProcedure>[toolUsingProcedure()]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'tool_using_v1'))
          .outcome;

      // The run still completes — the sink is purely observational.
      expect(outcome.status, TrailOutcomeStatus.accepted);
    });

    test('a turn-less invocation leaves turnId null', () async {
      final records = <ToolAccessRecord>[];
      final engine = engineFor(
        <LoadedProcedure>[toolUsingProcedure()],
        toolAccessSink: records.add,
      );

      await engine
          .invoke(ProcedureInvocation(procedureId: 'tool_using_v1'))
          .outcome;

      expect(records, isNotEmpty);
      for (final record in records) {
        expect(record.turnId, isNull);
      }
    });
  });

  group('ProcedureEngine tool notice forwarding (P2)', () {
    test('a per-run noticeSink fires once per tool event, in call order',
        () async {
      final notices = <ToolEvent>[];
      final engine = engineFor(<LoadedProcedure>[toolUsingProcedure()]);

      final outcome = await engine
          .invoke(
            ProcedureInvocation(procedureId: 'tool_using_v1'),
            noticeSink: notices.add,
          )
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(notices.map((e) => e.kind).toList(),
          <String>['tool.listed', 'tool.invoked', 'tool.failed']);
      // The notice line is the human-readable surface the route delivers.
      expect((notices[1] as ToolInvoked).noticeLine(), '🔧 tool memory.read');
      expect((notices[2] as ToolFailed).noticeLine(),
          startsWith('⚠️ tool does.not.exist failed:'));
    });

    test('both the trail sink and the notice sink see every event', () async {
      final records = <ToolAccessRecord>[];
      final notices = <ToolEvent>[];
      final engine = engineFor(
        <LoadedProcedure>[toolUsingProcedure()],
        toolAccessSink: records.add,
      );

      await engine
          .invoke(
            ProcedureInvocation(procedureId: 'tool_using_v1'),
            noticeSink: notices.add,
          )
          .outcome;

      expect(records.map((r) => r.event.kind).toList(), notices.map((e) => e.kind).toList());
    });

    test('a throwing notice sink never breaks the run (best-effort)', () async {
      final engine = engineFor(<LoadedProcedure>[toolUsingProcedure()]);

      final outcome = await engine
          .invoke(
            ProcedureInvocation(procedureId: 'tool_using_v1'),
            noticeSink: (_) => throw StateError('notify failed'),
          )
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
    });
  });
}

LoadedProcedure _procedure(String id, String body, {int version = 1}) {
  final source = '''
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
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'ok'),
        LlmStreamCompleted(
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A stateful in-memory `TomBrainMemoryClient` whose `recall` returns one node,
/// so the `memory.read` tool has a real result to return.
class _RecallingMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    final node = Node(
      id: NodeId.generate(),
      typeName: 'Conclusion',
      values: const <String, Object?>{'text': 'hit'},
      createdAt: DateTime.utc(2026, 6, 1),
    );
    return RecallResult(
      nodes: <Node>[node],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.off,
        elapsedMs: 1,
      ),
    );
  }

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
