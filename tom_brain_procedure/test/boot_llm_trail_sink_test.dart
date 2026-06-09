// Boot threads the raw-LLM-trail sink to the engine (`tom_brain_logging.md`
// §5.2 / §10 step #4 — the boot half of the seam).
//
// `BrainProcessConfig.llmTrailSink` is the production seam an `LlmTrailWriter`
// binds onto. This suite proves boot threads that sink through `_wireEngine`
// onto the `ProcedureEngine`, so a prompt submitted through the booted
// dispatcher fires one [LlmTrailRecord] per completed `llm` call — carrying the
// run's id and the wire the substrate saw. A boot with no sink stays silent.
//
// Doubles mirror `d44_brain_process_boot_test.dart` (in-process memory +
// answering substrate), trimmed to the one cold-path run
// `answer_with_memory_v1` performs (one `sub.llm` answer call).

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        EdgeId,
        InboundRequest,
        NodeId,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _BootMemory memory;
  late _AnsweringSubstrate substrate;

  setUp(() {
    memory = _BootMemory();
    substrate = _AnsweringSubstrate();
  });

  BrainProcessConfig configWith({LlmTrailSink? llmTrailSink}) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/boot_trail_sink'),
        ),
        llmTrailSink: llmTrailSink,
      );

  Access userPrompt(String text) => Access(
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.answerWithMemoryV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
      );

  group('boot threads the llmTrailSink onto the engine (§10 step #4)', () {
    test('a bound sink receives a run-correlated record per llm call', () async {
      substrate.answerChunks = <String>['an answer'];
      final records = <LlmTrailRecord>[];

      final booted =
          await BrainProcessBoot.boot(configWith(llmTrailSink: records.add));
      addTearDown(booted.shutdown);

      await booted.dispatcher.accept(userPrompt('what is a quasar?'));

      expect(records, isNotEmpty,
          reason: 'the answer llm call fires one raw-trail record');
      final record = records.first;
      // The record is run-correlated (the only place the run id is known).
      expect(record.runId, isNotNull);
      expect(record.trailId, isNotNull,
          reason: 'the recorder trail is open when the bridge fires');
      // The wire the substrate saw survives onto the observation.
      expect(record.observation.wire, isNotNull);
      expect(record.observation.wire!.anchorHash,
          record.observation.report.anchorHash);
    });

    test('with no sink bound boot wires no observer and stays silent', () async {
      substrate.answerChunks = <String>['an answer'];
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // The run still completes — the sink is purely observational. The
      // exchange was persisted (cold path), proving the run actually ran.
      await booted.dispatcher.accept(userPrompt('what is a quasar?'));
      expect(memory.persistedOfType('Conclusion').single.draft.values['statement'],
          'an answer');
    });
  });
}

// ─── In-process memory double (mirrors d44_brain_process_boot_test). ───
class _BootMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  ClassificationResult classifyResult = const ClassificationResult.unknown();

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async => recallResult;

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      classifyResult;

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
    persisted.add((id: id, draft: draft));
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

// ─── Answer-capturing substrate carrying a wire on completion. ─────────
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final prompt = call.inputs['prompt'] as String? ?? '';
    const anchorHash = 'sha256:anchor';
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final chunk in answerChunks)
        LlmStreamChunk(callId: 'c', text: chunk),
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
