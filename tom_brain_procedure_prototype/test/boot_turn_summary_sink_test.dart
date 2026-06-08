// Boot threads the turn-summary sink to the dispatch route
// (`tom_brain_logging.md` §5.4 / §5.5 / §10 step #5 — the boot half of the seam).
//
// `BrainProcessConfig.turnSummarySink` is the production seam the `SummaryFanout`
// binds onto for its per-turn §5.4 / §5.5 narrative blocks. The user prompt and
// the final answer are not on any `LlmTrailRecord` — they are only known at the
// dispatch edge — so the route emits one [TurnSummary] when a turn completes.
// This suite proves boot threads that sink through `_buildRoute`, so a prompt
// served through the booted dispatcher fires exactly one [TurnSummary] carrying
// the turn's id, session, principal, persona, prompt, and final answer. A boot
// with no sink stays silent.
//
// Doubles mirror `boot_llm_trail_sink_test.dart` (in-process memory + answering
// substrate), trimmed to the one cold-path run `answer_with_memory_v1` performs.

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
        TurnId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _BootMemory memory;
  late _AnsweringSubstrate substrate;

  setUp(() {
    memory = _BootMemory();
    substrate = _AnsweringSubstrate();
  });

  BrainProcessConfig configWith({TurnSummarySink? turnSummarySink}) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/boot_turn_sink'),
        ),
        turnSummarySink: turnSummarySink,
      );

  Access userPrompt(String text, {TurnId? turnId}) => Access(
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.answerWithMemoryV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        turnId: turnId,
      );

  group('boot threads the turnSummarySink onto the route (§10 step #5)', () {
    test('a completed turn fires one summary carrying prompt + final answer',
        () async {
      substrate.answerChunks = <String>['an answer'];
      final summaries = <TurnSummary>[];
      final turnId = TurnId.generate();

      final booted = await BrainProcessBoot.boot(
          configWith(turnSummarySink: summaries.add));
      addTearDown(booted.shutdown);

      await booted.dispatcher
          .accept(userPrompt('what is a quasar?', turnId: turnId));

      expect(summaries, hasLength(1),
          reason: 'one completed turn fires exactly one turn summary');
      final summary = summaries.single;
      expect(summary.turnId, turnId.value);
      expect(summary.sessionId, 's1');
      expect(summary.principalId, 'p1');
      expect(summary.persona, Persona.assistant().personaId);
      expect(summary.userPrompt, 'what is a quasar?');
      expect(summary.finalAnswer, 'an answer',
          reason: 'the answer the run produced rides onto the summary');
    });

    test('a turn with no turnId fires no summary (nothing to key a block on)',
        () async {
      substrate.answerChunks = <String>['an answer'];
      final summaries = <TurnSummary>[];

      final booted = await BrainProcessBoot.boot(
          configWith(turnSummarySink: summaries.add));
      addTearDown(booted.shutdown);

      await booted.dispatcher.accept(userPrompt('what is a quasar?'));

      expect(summaries, isEmpty,
          reason: 'no turnId → no §5.4 / §5.5 block can be keyed');
    });

    test('with no sink bound boot wires no emitter and stays silent', () async {
      substrate.answerChunks = <String>['an answer'];
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // The run still completes — the sink is purely observational. The
      // exchange was persisted (cold path), proving the run actually ran.
      await booted.dispatcher
          .accept(userPrompt('what is a quasar?', turnId: TurnId.generate()));
      expect(
          memory
              .persistedOfType('Conclusion')
              .single
              .draft
              .values['statement'],
          'an answer');
    });
  });
}

// ─── In-process memory double (mirrors boot_llm_trail_sink_test). ──────
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
