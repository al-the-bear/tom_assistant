// Boot threads the answering session's history into the route and back-fills
// the answer (access spec § 7.2 / § 21.5; hub § 11).
//
// Regression suite for the live "doesn't remember my name" defect: a prompt
// served through the booted dispatcher must (1) carry the conversation's
// earlier turns into the substrate prompt, so a memoryless model can answer a
// follow-up that depends on an earlier turn, and (2) back-fill the answer into
// the turn the SessionManager appended for this prompt, so the *next* turn's
// assembled history includes this exchange.
//
// The `Access` rides a `ConversationHistory` exactly as the assembler builds
// it: an earlier *answered* turn, then a freshly-appended *answer-less* turn
// for the live prompt. The route drops that last turn from `priorTurns` (it is
// the live prompt, passed separately as `text`), renders the earlier one into
// the prompt, and after the run writes the answer back into the live turn.
//
// Doubles mirror `boot_turn_summary_sink_test.dart`, with the substrate
// capturing the assembled prompt.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        ConversationHistory,
        EdgeId,
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
  late _PromptCapturingSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BootMemory();
    substrate = _PromptCapturingSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig config() => BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/boot_history_inj'),
        ),
        // Increment 6 (§6): the booted answer step resolves its prompt — including
        // the rendered prior-turn history — through the host `PromptResolver`. The
        // parity fake reproduces the pre-migration assembled transcript so the
        // captured substrate prompt still carries the history this suite asserts.
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
      );

  /// An `Access` carrying [history], shaped as the assembler builds it: the
  /// live prompt is the last (answer-less) turn already appended to [history].
  Access promptWithHistory(String text, ConversationHistory history) => Access(
        // The entry router is the only routable procedure after the Todo-6
        // route-flip (§ 4.0.1); the two-phase route then runs the answer branch
        // it selects, whose answer prompt is the last one the substrate sees.
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        history: history,
        turnId: TurnId.generate(),
      );

  test('an earlier turn is rendered into the substrate prompt', () async {
    substrate.answerChunks = <String>['Your name is Alexis.'];

    // Turn 1 already happened and was answered; turn 2 (the live prompt) is
    // appended answer-less, exactly as the SessionManager would on admit.
    final history = ConversationHistory()
      ..append(HistoryTurn(
        userPrompt: 'My name is Alexis',
        brainAnswer: 'Nice to meet you, Alexis.',
      ))
      ..append(HistoryTurn(userPrompt: 'What is my name?', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher
        .accept(promptWithHistory('What is my name?', history));

    final prompt = substrate.lastPrompt!;
    // The earlier exchange reached the substrate — the model is no longer blind.
    expect(prompt, contains('My name is Alexis'));
    expect(prompt, contains('Nice to meet you, Alexis.'));
    // The live prompt is present once, as the user prompt (not duplicated as a
    // prior turn).
    expect(prompt, contains('What is my name?'));
  });

  test('the answer is back-filled into the live turn after the run', () async {
    substrate.answerChunks = <String>['Your name is Alexis.'];

    final history = ConversationHistory()
      ..append(HistoryTurn(
        userPrompt: 'My name is Alexis',
        brainAnswer: 'Nice to meet you, Alexis.',
      ))
      ..append(HistoryTurn(userPrompt: 'What is my name?', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher
        .accept(promptWithHistory('What is my name?', history));

    // The live turn was answer-less on admit; the route wrote the answer back.
    final last = history.durableRecord.last;
    expect(last.userPrompt, 'What is my name?');
    expect(last.brainAnswer, 'Your name is Alexis.');
  });

  test('a cold first turn threads no prior turns', () async {
    substrate.answerChunks = <String>['Hello.'];

    // The very first prompt: history holds only the just-appended live turn.
    final history = ConversationHistory()
      ..append(HistoryTurn(userPrompt: 'hello', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory('hello', history));

    final prompt = substrate.lastPrompt!;
    expect(prompt, isNot(contains('User:')));
    expect(prompt, isNot(contains('Assistant:')));
    // Still back-filled, so the next turn sees this one.
    expect(history.durableRecord.single.brainAnswer, 'Hello.');
  });
}

// ─── In-process memory double (mirrors boot_turn_summary_sink_test). ──────
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

// ─── Prompt-capturing substrate (records the assembled prompt). ────────
class _PromptCapturingSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];
  String? lastPrompt;

  /// The opening line of the completion-confirmation prompt (agent-loop
  /// completion plan § 3.1, revision 2026-06-14). The trailing `sub.llm`
  /// confirmation call must NOT overwrite the captured answer prompt.
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
    // The confirmation call terminates the loop with `DONE`; only the answer
    // prompt is captured for assertion.
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
    lastPrompt = rawPrompt;
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
