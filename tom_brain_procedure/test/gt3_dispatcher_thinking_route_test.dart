// G-T (gap-hunt § 6.5) — the dispatcher-level two-phase route-flip proof.
//
// gt1 proves the recursive loop *as a procedure* (engine-direct); this suite
// proves the loop is reachable *through the dispatcher* exactly as a live
// prompt arrives. Todo 6's done-when: "a deliberation-cued prompt runs the
// recursive loop end-to-end, the normal branch is untouched, and both are
// reachable only via the router."
//
// The route (§ 4.0.1) is two-phase within one foreground admission:
//   1. classify — invoke the entry router `prompt_analyzer_v1` (no sink);
//   2. answer — invoke the branch it selects, streaming, top-level.
// The branch is `_resolveAnswerBranch(routerTarget, promptText)`: thinking iff
// the router said thinking OR the deterministic cue floor
// (`classifyDeliberationCue`) reads the prompt as a deliberation request. The
// fake substrate returns no THINKING/NORMAL token, so the router always
// classifies `normal` — which means a cued prompt reaching the thinking branch
// can *only* be the cue floor firing. That is the tie-breaker this suite pins.
//
// The observable signal is the persisted `ProcedureRun` set: each run records a
// ProcedureRun node carrying its `procedureId`, so which answer branch ran is
// read straight off memory (the gt1 / d54 `finalRunNode()` precedent). The
// router's own phase-1 ProcedureRun proves the answer branch was reached only
// through it.

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

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

void main() {
  late _BootMemory memory;
  late _RoleAwareSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BootMemory();
    substrate = _RoleAwareSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig config() => BrainProcessConfig(
    substrate: substrate,
    memoryProvisioning: MemoryProvisioningConfig.inProcess(
      client: memory,
      memoryConfig: MemoryConfig.forTesting(root: 'ztmp/gt3_dispatcher'),
    ),
    // Increment 6 (§6): the normal branch's `answer_with_memory_v1` resolves
    // its prompt through the host `PromptResolver`. The thinking + router
    // branches call `sub.llm`/`sub.send` directly and never consult it; the
    // parity fake supplies the normal branch's assembled prompt.
    promptResolver: parity.resolver,
    routeChainOf: parity.routeChainOf,
  );

  /// A live user prompt as the channel delivers it — un-hinted, so the
  /// dispatcher routes it through the entry router (§ 4.0.1). [delivered]
  /// captures the streamed answer.
  Access userPrompt(String text, {List<String>? delivered}) => Access(
    envelope: InboundRequest(
      text: text,
      kindHint: SystemProcedures.promptAnalyzerV1,
    ),
    identity: ResolvedIdentity(principalId: 'p1'),
    session: Session(sessionId: 's1'),
    persona: Persona.assistant(),
    deliver: (chunk) {
      if (delivered != null && chunk.textDelta.isNotEmpty) {
        delivered.add(chunk.textDelta);
      }
      return Stream<OutboundChunk>.value(chunk);
    },
    turnId: TurnId.generate(),
  );

  /// The `procedureId`s of every completed (status != 'running') answer/router
  /// run the loop persisted — the proof of which branches executed.
  Set<String> completedRunIds() => memory
      .persistedOfType('ProcedureRun')
      .where((p) => p.draft.values['status'] != 'running')
      .map((p) => p.draft.values['procedureId'] as String)
      .toSet();

  group('a deliberation-cued prompt runs the recursive loop through accept()', () {
    test(
      'the thinking branch runs end-to-end; the normal branch is untouched',
      () async {
        final delivered = <String>[];
        final booted = await BrainProcessBoot.boot(config());
        addTearDown(booted.shutdown);

        // "think about" is a cue floor trigger; the fake router still classifies
        // normal, so reaching the thinking branch can only be the cue floor.
        await booted.dispatcher.accept(
          userPrompt(
            'think about how memory consolidates',
            delivered: delivered,
          ),
        );

        final completed = completedRunIds();
        expect(
          completed,
          contains(SystemProcedures.answerWithThinkingV1),
          reason: 'the cued prompt ran the recursive thinking loop',
        );
        expect(
          completed,
          isNot(contains(SystemProcedures.answerWithMemoryV1)),
          reason: 'the normal branch is untouched for a cued prompt',
        );
        // Reached only via the router: phase-1 prompt_analyzer_v1 ran first.
        expect(
          completed,
          contains(SystemProcedures.promptAnalyzerV1),
          reason: 'the answer branch is reachable only through the router',
        );
        // A foreground prompt is never answered with silence (gap-hunt § 6.5).
        expect(delivered.join().isNotEmpty, isTrue);
      },
    );
  });

  group('a normal prompt runs the memory branch through accept()', () {
    test('the memory branch runs; the thinking branch is untouched', () async {
      final delivered = <String>[];
      final booted = await BrainProcessBoot.boot(config());
      addTearDown(booted.shutdown);

      // No cue word: the router classifies normal and the cue floor agrees.
      await booted.dispatcher.accept(
        userPrompt('what is a quasar?', delivered: delivered),
      );

      final completed = completedRunIds();
      expect(
        completed,
        contains(SystemProcedures.answerWithMemoryV1),
        reason: 'an un-cued prompt runs the normal memory branch',
      );
      expect(
        completed,
        isNot(contains(SystemProcedures.answerWithThinkingV1)),
        reason: 'the thinking branch never runs for an un-cued prompt',
      );
      expect(
        completed,
        contains(SystemProcedures.promptAnalyzerV1),
        reason: 'the memory branch is reachable only through the router',
      );
      expect(delivered.join().isNotEmpty, isTrue);
    });
  });
}

// ── A role-aware substrate (mirrors gt1's). ─────────────────────────────
//
// Returns generic text for the router's `analyser` classification call (no
// THINKING/NORMAL token → the router defaults to normal), and ACCEPT for the
// thinking loop's `evaluator` so a cued run accepts on its first critique.
class _RoleAwareSubstrate implements TomBrainSubstrateClient {
  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    final text = call.roleId == 'evaluator' ? 'ACCEPT' : 'a thoughtful answer';
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(text),
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
    vec: Vec(Float32List.fromList(<double>[0.0])),
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

// ── In-process memory double (mirrors boot_turn_summary_sink_test). ──────
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
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      recallResult;

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async => classifyResult;

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
  Stream<Node> stream(StreamQuery query) {
    // CLP-76: the boot now enumerates brain `Procedure` nodes from memory.
    // This double serves none, so the procedure tier sees an empty stream.
    final types = query.filter.typeNames;
    return Stream<Node>.fromIterable(
      _nodes.values.where((n) => types.isEmpty || types.contains(n.typeName)),
    );
  }

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
