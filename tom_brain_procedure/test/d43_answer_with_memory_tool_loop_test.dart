// D.43 — `answer_with_memory_v1` runs the complete tool-calling loop
// (procedure spec § 21.2 / § 11 step 2; access spec § 7.2).
//
// D.38c proved the live answer path made the model *aware* of its tools (it
// rendered the catalogue into the prompt). This suite proves the missing other
// half: the model can actually *call* them. A tool the model proposes is run
// through the live `tool.invoke` surface, its result is folded back into the
// transcript, and the loop re-enters until the model answers with no tool call.
//
// What this proves, against the shipped `scripts/system/` artifact and the
// engine's per-run `ToolBridge` binding:
//
//   1. INVOKED END-TO-END — when the substrate proposes `memory.read{text}`,
//      the loop reaches the real tool, which calls `memory.recall` with that
//      text. We assert the recall actually happened on the memory double, so
//      this is a true end-to-end invocation, not just prompt prose.
//   2. RESULT FOLDED BACK — a later tools-bearing completion sees a
//      "Tool results:" block naming the tool, so the model can answer from it.
//   3. ANSWER RETURNED — after the tool turn the model answers and the run
//      surfaces that text as the `answer` output, accepted.
//   4. NO-TOOL RUN UNCHANGED (PE-9 guard) — a substrate that never proposes a
//      tool still answers in one turn with no tool block, exactly as before.
//
// The doubles mirror D.38c's recall/substrate stubs; the substrate gains a
// scripted "propose once, then answer" behaviour keyed on whether the call
// carried a tool catalogue (so the conductor's tool-less `recall_*` calls never
// trigger it), and the memory double records the recall queries it is asked.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

void main() {
  late _RecallCapturingMemory memory;
  late _ToolThenAnswerSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _ToolThenAnswerSubstrate();
    memoryBridge = MemoryBridge(memory);
    parity = AnswerParityPrompts();
    // Increment 6 (§7.4): the answer prompt's tool set is resolved from its tool
    // policy, not a procedure input. The shipped `defaultToolCatalogue()` is the
    // production set `tool.list()` exposes, so the substrate's answer-step calls
    // carry tools (gating its `proposeReadFor` branch) and a proposed
    // `memory.read{…}` resolves against it — exactly the pre-migration behaviour.
    parity.tools = defaultToolCatalogue();
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: parity.resolver,
      routeChainOf: parity.routeChainOf,
    );
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> runWith(String text) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'answer_with_memory_v1',
          arguments: <String, Object?>{'text': text},
        ))
        .outcome;
  }

  group('D.43-1 a proposed tool call is invoked end-to-end', () {
    test('the model proposing memory.read reaches the real recall surface',
        () async {
      substrate.proposeReadFor = 'the tool probe';

      await runWith('please use a tool');

      // The loop ran the proposed tool through `tool.invoke`, which reached the
      // shipped `memory.read` tool, which called `memory.recall` with the text
      // the model proposed. Only the tool issues a single `recall` (the
      // retrieval conductor fuses into `recall.multi`), so this query is the
      // tool's footprint.
      expect(
        memory.recallQueries.map((q) => q.text),
        contains('the tool probe'),
      );
    });

    test('the tool result is folded into a later completion transcript',
        () async {
      substrate.proposeReadFor = 'the tool probe';

      await runWith('please use a tool');

      // The completion that produced the final answer saw the tool result —
      // the loop appended a "Tool results:" block naming the tool before
      // re-entering, so the model could answer from it.
      final answeringPrompt = substrate.toolBearingPrompts.last;
      expect(answeringPrompt, contains('Tool results:'));
      expect(answeringPrompt, contains('memory.read'));
    });

    test('the run answers after the tool turn and is accepted', () async {
      substrate.proposeReadFor = 'the tool probe';
      substrate.answerText = 'answered after the tool ran';

      final outcome = await runWith('please use a tool');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'answered after the tool ran');
    });
  });

  group('D.43-2 a run with no proposed tool answers in one turn (PE-9 guard)',
      () {
    test('a substrate that never proposes a tool still answers', () async {
      // proposeReadFor left null ⇒ the substrate answers every call.
      substrate.answerText = 'plain answer';

      final outcome = await runWith('no tools needed');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'), 'plain answer');
      // The tool was never invoked, so memory saw no single-query recall from a
      // tool (the conductor uses recall.multi, not recall).
      expect(memory.recallQueries, isEmpty);
    });

    test('with no tool turn the answering prompt holds no tool-result block',
        () async {
      substrate.answerText = 'plain answer';

      await runWith('no tools needed');

      final answeringPrompt = substrate.toolBearingPrompts.last;
      expect(answeringPrompt, isNot(contains('Tool results:')));
    });
  });
}

// ── A substrate that proposes one tool call, then answers ───────────
//
// Keyed on whether the call carried a tool catalogue: only the answer step of
// `answer_with_memory_v1` offers tools, so the conductor's tool-less `recall_*`
// completions never trip the propose branch (they fall through to the answer
// branch and return harmless text the conductor degrades). The first
// tools-bearing call proposes `memory.read{text: proposeReadFor}`; every
// subsequent tools-bearing call answers, so the loop terminates.
class _ToolThenAnswerSubstrate implements TomBrainSubstrateClient {
  /// When non-null, the first tools-bearing call proposes `memory.read` with
  /// this text; left null, the substrate answers every call (the no-tool path).
  String? proposeReadFor;

  /// The text the substrate answers with on a non-proposing completion.
  String answerText = 'ok';

  bool _proposed = false;

  /// The prompts of every completion that carried a tool catalogue, in order —
  /// the answer-step calls of `answer_with_memory_v1` (the conductor's calls are
  /// tool-less and excluded).
  final List<String> toolBearingPrompts = <String>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final hasTools = call.options.toolCatalogue.isNotEmpty;
    if (hasTools) {
      toolBearingPrompts.add(call.inputs['prompt']! as String);
    }

    const completed = LlmStreamCompleted(
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
    );

    if (hasTools && proposeReadFor != null && !_proposed) {
      _proposed = true;
      return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        LlmStreamToolCallProposed(
          callId: 'c',
          toolCallId: 'tc1',
          toolName: 'memory.read',
          arguments: <String, Object?>{'text': proposeReadFor!},
        ),
        completed,
      ]);
    }

    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: answerText),
      completed,
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

// ── A recall-capturing `TomBrainMemoryClient` ───────────────────────
//
// Records every single-query `recall` it is asked (the `memory.read` tool's
// footprint) and otherwise models just enough of the store for the run
// recorder's writes to succeed. Mirrors the D.38c double.
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every `recall` query asked, in order — the `memory.read` tool is the only
  /// caller of single-query `recall` (the conductor uses `recallMulti`).
  final List<RecallQuery> recallQueries = <RecallQuery>[];

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

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return recallResult;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      recallResult;

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
