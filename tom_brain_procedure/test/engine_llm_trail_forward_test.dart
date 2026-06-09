// Engine-level raw-LLM-trail forwarding (`tom_brain_logging.md` §5.2 / §9 /
// §10 step #4 — the "engine → writer" half of the seam).
//
// The bridge fires one [LlmCallObservation] per completed `llm` call
// (`substrate_bridge_llm_trail_test.dart` covers that). The *engine* is the
// only place that knows the run's correlation — its `runId` and the live
// `trailId` the recorder opened — so it wraps each observation into an
// [LlmTrailRecord] carrying both and hands it to the bound `llmTrailSink`.
//
// With no sink bound the engine wires no observer onto the per-run bridge, so
// nothing is emitted and the run completes unchanged.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, TurnId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  late _StatefulMemory memory;
  late _RecordingSubstrate substrate;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _RecordingSubstrate();
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    LlmTrailSink? llmTrailSink,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
        llmTrailSink: llmTrailSink,
      );

  group('ProcedureEngine raw-LLM-trail forwarding (§5.2 / §10 step #4)', () {
    test('a bound sink receives one record per llm call, run-correlated',
        () async {
      final records = <LlmTrailRecord>[];
      final engine = engineFor(
        <LoadedProcedure>[
          _procedure(
            'two_calls_v1',
            '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('first');
  await sub.llm('second');
  return 1;
}
''',
          ),
        ],
        llmTrailSink: records.add,
      );

      final turnId = TurnId.generate();
      final run = engine.invoke(
        ProcedureInvocation(procedureId: 'two_calls_v1', turnId: turnId),
      );
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(records, hasLength(2),
          reason: 'one record per completed llm call');

      // Both records carry the run's id …
      expect(records[0].runId, run.runId);
      expect(records[1].runId, run.runId);
      // … and the live trailId the recorder opened (non-null while the trail
      // is open during the llm call).
      expect(records[0].trailId, isNotNull,
          reason: 'the recorder trail is open when the bridge fires');
      expect(records[1].trailId, records[0].trailId,
          reason: 'both calls of one run share the run trail');

      // The observation provenance survives the wrap (wire + turn stamp).
      final first = records[0].observation;
      expect(first.callType, 'assistant_to_user');
      expect(first.answer, 'ok');
      expect(first.wire, isNotNull);
      expect(first.wire!.anchorHash, first.report.anchorHash);
      expect(first.turnId, turnId.value);
      expect(first.callSeq, 1);
      expect(records[1].observation.callSeq, 2);
    });

    test('with no sink bound the engine forwards nothing', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'one_call_v1',
          '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('only');
  return 1;
}
''',
        ),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'one_call_v1'))
          .outcome;

      // The run still completes — the sink is purely observational.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(substrate.calls, hasLength(1));
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

/// A `TomBrainSubstrateClient` whose completed event carries a
/// [CapturedWirePrompt] (anchor-prefixed) whose `anchorHash` matches the
/// report's — so the observation the bridge fires carries a real wire body.
class _RecordingSubstrate implements TomBrainSubstrateClient {
  final List<LlmCall> calls = <LlmCall>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    calls.add(call);
    final prompt = call.inputs['prompt'] as String;
    const anchorHash = 'sha256:anchor';
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      const LlmStreamChunk(callId: 'c', text: 'ok'),
      LlmStreamCompleted(
        callId: 'c',
        wire: CapturedWirePrompt(
          body: 'ANCHOR\n\n$prompt',
          anchorHash: anchorHash,
          roleId: call.roleId,
        ),
        report: const LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: anchorHash,
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A stateful in-memory `TomBrainMemoryClient` (just enough for the
//    recorder's writes — mirrors engine_turn_correlation_test.dart). ──────
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
