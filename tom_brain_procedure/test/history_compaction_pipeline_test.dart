// Phase-C todo 9: the booted dispatch route runs the engine-side
// `HistoryCompactor` after a turn's answer is back-filled (hub § 22.4 / § 22.10).
//
// `g21_history_compaction_test.dart` already pins the compactor in isolation
// (fold / fail-retry / over-long-truncate). This suite pins the *wiring*: a
// prompt served through the booted dispatcher, on a session whose pending batch
// has crossed `compactionThreshold`, folds that batch into the bounded summary
// and clears `pending` — and that the path is a no-op (history untouched) when
// no compactor is configured or the batch is below threshold.
//
// The harness mirrors `boot_history_injection_test.dart`: an in-process memory
// double + a prompt-answering substrate, with the live prompt riding as the last
// (answer-less) turn of the seeded `ConversationHistory`. The compactor's own
// substrate seam is a separate one-line stub (it is injected into the
// `HistoryCompactor`, not the engine's substrate).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        ConversationHistory,
        EdgeId,
        HistorySizing,
        HistoryTurn,
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
  late _AnsweringSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BootMemory();
    substrate = _AnsweringSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig config({HistoryCompactor? historyCompactor}) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/hist_compaction'),
        ),
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
        historyCompactor: historyCompactor,
      );

  /// A stub compaction substrate that always returns [summary] — stands in for
  /// the anchored `sub.llm` seam (G.23), independent of the engine substrate.
  HistoryCompactor compactorReturning(String summary) => HistoryCompactor(
        templates: _templates(),
        substrate: (_) async => summary,
      );

  /// A `ConversationHistory` seeded with [answeredTurns] answered turns plus one
  /// live answer-less turn (the prompt about to be served), shaped exactly as
  /// the assembler hands it to the route. Small sizing keeps the pending batch
  /// past threshold with few turns (the rawCount floor of 10 is enforced only at
  /// config parse, so the direct constructor accepts these test values).
  ConversationHistory seededHistory({required int answeredTurns}) {
    final h = ConversationHistory(
      sizing: const HistorySizing(
        rawCount: 2,
        compactionThreshold: 3,
        maxCompactedTokens: 1024,
        maxCompactedChars: 6000,
      ),
    );
    for (var i = 0; i < answeredTurns; i++) {
      h.append(HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i'));
    }
    h.append(HistoryTurn(userPrompt: 'live prompt', brainAnswer: ''));
    return h;
  }

  Access promptWithHistory(ConversationHistory history) => Access(
        envelope: InboundRequest(
            text: 'live prompt', kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        history: history,
        turnId: TurnId.generate(),
      );

  test('a session over threshold compacts after the answer is back-filled',
      () async {
    substrate.answerChunks = <String>['the answer'];
    // rawCount 2 + 3 answered + 1 live ⇒ pending 4 ≥ threshold 3.
    final history = seededHistory(answeredTurns: 5);
    expect(history.needsCompaction, isTrue,
        reason: 'precondition: the seeded batch is over threshold');

    final booted =
        await BrainProcessBoot.boot(config(historyCompactor: compactorReturning('distilled')));
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    // The pending batch was folded into the bounded summary and cleared.
    expect(history.compactedSummary, 'distilled');
    expect(history.pending, isEmpty);
    expect(history.needsCompaction, isFalse);
    // The live turn was still back-filled (the existing § 7.2 #4 behaviour).
    expect(history.rawWindow.last.brainAnswer, 'the answer');
  });

  test('a session below threshold is not compacted', () async {
    substrate.answerChunks = <String>['the answer'];
    // rawCount 2 + 3 answered + 1 live ⇒ pending 2 < threshold 3.
    final history = seededHistory(answeredTurns: 3);
    expect(history.needsCompaction, isFalse);
    expect(history.pending, hasLength(2),
        reason: 'precondition: a non-empty batch that is still below threshold');

    final booted =
        await BrainProcessBoot.boot(config(historyCompactor: compactorReturning('distilled')));
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    // No compaction ran: the summary stays empty and the batch is intact.
    expect(history.compactedSummary, isEmpty);
    expect(history.pending, hasLength(2));
  });

  test('no compactor configured leaves an over-threshold batch untouched',
      () async {
    substrate.answerChunks = <String>['the answer'];
    final history = seededHistory(answeredTurns: 5);
    final pendingBefore = history.pending.toList();
    expect(history.needsCompaction, isTrue);

    // The prototype default: no `historyCompactor` ⇒ the answer path runs
    // exactly as before, with no compaction.
    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    expect(history.compactedSummary, isEmpty);
    expect(history.pending, pendingBefore);
    expect(history.needsCompaction, isTrue);
    // The answer was still back-filled — only compaction is skipped.
    expect(history.rawWindow.last.brainAnswer, 'the answer');
  });
}

/// Writes a `compact_history_v1.yaml` whose scaffolds inject the two history
/// placeholders, into a throwaway directory, and returns a store.
HistoryCompactionTemplateStore _templates() {
  final dir = Directory.systemTemp.createTempSync('hist_compaction_tpl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}compact_history_v1.yaml')
      .writeAsStringSync(r'''
system: |
  Fold the new turns into the running summary. Current: ${history.compacted}
user: |
  New turns: ${history.batch}
''');
  return HistoryCompactionTemplateStore(dir);
}

// ─── In-process memory double (mirrors boot_history_injection_test). ──────
class _BootMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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

// ─── Prompt-answering substrate (returns chunks, terminates the loop). ────
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  /// The opening line of the completion-confirmation prompt: that call must
  /// terminate the agent loop with `DONE`, not contribute answer text.
  static const String _confirmationSentinel =
      'You have just produced an answer for the user.';

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final rawPrompt = call.inputs['prompt'] as String?;
    final isConfirmation = call.roleId == 'assistant_to_user' &&
        rawPrompt != null &&
        rawPrompt.trimLeft().startsWith(_confirmationSentinel);
    if (isConfirmation) {
      return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'DONE'),
        const LlmStreamCompleted(
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
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final chunk in answerChunks)
        LlmStreamChunk(callId: 'c', text: chunk),
      const LlmStreamCompleted(
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
