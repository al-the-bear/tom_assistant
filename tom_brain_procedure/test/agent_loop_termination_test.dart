// Agent-loop termination — the completion-confirmation contract
// (`agent_loop_completion.md` § 3 / § 6, revision 2026-06-14;
// `thinking_specification.md` § 4).
//
// These tests pin the *target* termination contract that the memory path
// (`answer_with_memory_v1`) and the thinking path (`answer_with_thinking_v1`)
// satisfy after the 2026-06-14 revision. The mechanical "every session todo is
// done" gate is gone; termination is now an explicit model decision.
//
// The contract under test (§ 3, revision 2026-06-14):
//
//   After producing a draft answer a run asks the model — in its normal
//   `assistant_to_user` profile and presenting the live todo list — whether the
//   work is finished (`DONE`) or whether it should keep going (`CONTINUE`). On
//   `CONTINUE` the draft and the are-you-done exchange are folded into the
//   conversation history and the loop re-enters; on `DONE` (or any unparseable
//   reply — the never-hang default) the loop exits. The confirmation turn streams
//   to the **thinking** channel, so its verdict never leaks into the answer.
//
//   On the thinking path the self-critique is an inner gate: a REJECT re-enters
//   directly (and records its missing pieces as a session todo, so the work is
//   tracked); only an ACCEPT reaches the completion-confirmation gate.
//
//   The only non-confirmation exit is the wall-clock runaway-stop (§ 3.3).
//
// How the doubles express the contract:
//
//   - `_ScriptedSubstrate` is role-aware AND tool-capable. In **memory mode**
//     the tools-bearing `assistant_to_user` turns are scripted as a queue of
//     tool-proposals / plain-answers (the inner `tool_loop_v1` cycle). In
//     **thinking mode** the synthesis (`assistant_to_user`, tool-less) returns a
//     fresh `draft #N` per call and the evaluator drives ACCEPT / REJECT off a
//     verdict queue.
//   - The **completion-confirmation** call (`sub.llm`, role `assistant_to_user`,
//     no tools, thinking channel) is recognised by its prompt sentinel and
//     answered from the `confirmationVerdicts` queue (`DONE` / `CONTINUE`). It is
//     detected before the answer/synthesis routing so it is never mistaken for a
//     synthesis draft.
//   - The engine binds each run's `todo.*` tools to the session store of the
//     invocation's `sessionId`, exposed as `engine.sessionTodoStores`. The tests
//     read and seed it directly.
//
// Test 5 (wall-clock runaway-stop, § 3.3) is `skip`-ped: it needs the loop body
// to read a deadline, but the cognition layer has no clock primitive today.
// Forcing it deterministically requires a new primitive, tracked in
// `open_topics.tom_brain.md`. The skipped test documents the intended assertions
// so it can be un-skipped once that primitive lands.

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

/// The opening of the procedures' `_confirmationQuestion` — the double keys the
/// completion-confirmation call off it (kept in sync with the two procedures'
/// helper text). Matched as a **prefix** of the raw `sub.llm` prompt: the
/// confirmation question is passed verbatim, so it *starts* with this line,
/// whereas an answer/synthesis prompt only ever *embeds* the question inside its
/// folded-in conversation history. A prefix match therefore never mistakes a
/// re-entry's answer prompt (which carries the prior confirmation turn) for a
/// fresh confirmation call.
const String _confirmationSentinel =
    'You have just produced an answer for the user.';

void main() {
  late _BrainMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BrainMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    parity = AnswerParityPrompts();
    // Increment 6 (§7.4): the answer prompt's tool set is resolved from its tool
    // policy, not a runtime input. The shipped `defaultToolCatalogue()` is what
    // `tool.list()` exposes, so the memory-path answer turns carry tools — the
    // gate the scripted substrate uses to consume its tool-proposing answer
    // turns and to capture the tools-bearing prompt. Thinking-mode turns ignore
    // the catalogue (`!thinkingMode && hasTools`), and the completion
    // confirmation is tool-less, so neither is affected.
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
        now: () => DateTime.utc(2026, 6, 12, 12, 0, 0),
      );

  Future<ProcedureEngine> buildEngine() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return engineFor(resolver.ids.map(resolver.resolve).toList());
  }

  Future<ProcedureOutcome> runMemory(
    ProcedureEngine engine,
    String text, {
    required String sessionId,
  }) =>
      engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            sessionId: sessionId,
            arguments: <String, Object?>{'text': text},
          ))
          .outcome;

  Future<ProcedureOutcome> runThinking(
    ProcedureEngine engine,
    String text, {
    required String sessionId,
  }) =>
      engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_thinking_v1',
            sessionId: sessionId,
            arguments: <String, Object?>{'text': text},
          ))
          .outcome;

  // Two recalled, text-bearing nodes so the thinking path can draw provenance
  // edges (mirrors gt1's seed; not asserted here, just keeps recall non-empty).
  void seedRecall() {
    memory.recallResult = RecallResult(
      nodes: <Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000042'),
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'memory consolidates in sleep'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 1},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 5,
      ),
    );
  }

  group('T1 completion-confirmation — memory path (§ 3 / § 6.1)', () {
    test(
        'a CONTINUE confirmation re-enters; the loop exits on DONE, returning '
        'the last draft', () async {
      final engine = await buildEngine();
      // Two answer drafts; the first confirmation says CONTINUE (re-enter), the
      // second says DONE (exit). The winning answer is the second draft.
      substrate.answerTurns = <_Turn>[
        _Turn.text('draft one'),
        _Turn.text('draft two'),
      ];
      substrate.confirmationVerdicts = <String>['CONTINUE', 'DONE'];

      final outcome =
          await runMemory(engine, 'do a two-step task', sessionId: 's-mem');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The CONTINUE kept the loop going — the first draft must NOT win.
      expect(
        outcome.result!.output<String>('answer'),
        'draft two',
      );
      // The model was asked to confirm completion once per draft.
      expect(substrate.confirmationCount, 2,
          reason: 'one are-you-done confirmation per draft');
    });

    test('a DONE confirmation on the first pass exits immediately', () async {
      final engine = await buildEngine();
      substrate.answerTurns = <_Turn>[_Turn.text('the only answer')];
      substrate.confirmationVerdicts = <String>['DONE'];

      final outcome =
          await runMemory(engine, 'a one-shot task', sessionId: 's-once');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'), 'the only answer');
      expect(substrate.confirmationCount, 1);
    });

    test('the confirmation prompt presents the live todo list', () async {
      final engine = await buildEngine();
      substrate.answerTurns = <_Turn>[_Turn.text('done answer')];
      substrate.confirmationVerdicts = <String>['DONE'];
      // Seed an open session todo; it must surface in the confirmation prompt so
      // the model can reason over the live task list (§ 3.1 revision).
      engine.sessionTodoStores.forSession('s-list').add('write the report');

      await runMemory(engine, 'task with an open todo', sessionId: 's-list');

      expect(substrate.confirmationPrompts, isNotEmpty);
      expect(substrate.confirmationPrompts.last, contains('write the report'),
          reason: 'the confirmation must present the live todo list as evidence');
    });
  });

  group('T2 completion-confirmation — thinking path (§ 3 / § 6.2)', () {
    test(
        'an ACCEPT reaches the confirmation gate; a CONTINUE re-enters and a DONE '
        'terminates', () async {
      seedRecall();
      substrate.thinkingMode = true;
      // Both critiques accept; the first confirmation continues (re-enter), the
      // second finishes.
      substrate.evaluatorVerdicts = <String>['ACCEPT', 'ACCEPT'];
      substrate.confirmationVerdicts = <String>['CONTINUE', 'DONE'];

      final engine = await buildEngine();
      final outcome =
          await runThinking(engine, 'reflect on memory', sessionId: 's-think');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // Two synthesis passes: iter 1 ACCEPT → CONTINUE (re-enter); iter 2 ACCEPT
      // → DONE (terminate).
      expect(substrate.synthCount, 2,
          reason: 'the CONTINUE confirmation re-enters after the first ACCEPT');
      expect(substrate.confirmationCount, 2,
          reason: 'the confirmation runs once per ACCEPT');
      expect(outcome.result!.output<String>('answer'), substrate.draftFor(2));
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
    });
  });

  group('T3 bootstrap (§ 3.2 / § 6.3)', () {
    test('a trivial prompt that seeds no todos still produces an answer',
        () async {
      // Non-regression guard: a trivial prompt is answered once and the DONE
      // confirmation exits — never silent.
      final engine = await buildEngine();
      substrate.answerTurns = <_Turn>[_Turn.text('hi there')];
      substrate.confirmationVerdicts = <String>['DONE'];

      final outcome = await runMemory(engine, 'hello', sessionId: 's-boot');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final answer = outcome.result!.output<String>('answer');
      expect(answer, isNotNull);
      expect(answer!.isNotEmpty, isTrue,
          reason: 'never silent — a trivial prompt is still answered');
    });
  });

  group('T4 a REJECT records missing work and re-enters directly (§ 6.4)', () {
    test(
        'a REJECT critique records at least one open todo and re-enters without '
        'asking for confirmation', () async {
      seedRecall();
      substrate.thinkingMode = true;
      // First critique rejects (re-enter directly), second accepts; the post-
      // ACCEPT confirmation finishes.
      substrate.evaluatorVerdicts = <String>['REJECT', 'ACCEPT'];
      substrate.confirmationVerdicts = <String>['DONE'];

      final engine = await buildEngine();
      final outcome = await runThinking(engine, 'work the backup topology',
          sessionId: 's-reject');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The REJECT investigation fed its missing pieces back as a session todo —
      // tracked open work, even though termination no longer gates on it.
      final store = engine.sessionTodoStores.peek('s-reject');
      expect(store, isNotNull,
          reason: 'the rejection created a session todo for its missing pieces');
      expect(store!.list(), isNotEmpty,
          reason: 'at least one todo was pushed by the REJECT investigation');
      // Re-entered after the REJECT; produced a second draft.
      expect(substrate.synthCount, greaterThanOrEqualTo(2),
          reason: 'the REJECT re-entered to redraft');
      // Confirmation runs only after an ACCEPT — once here, not after the REJECT.
      expect(substrate.confirmationCount, 1,
          reason: 'the REJECT re-enters directly; only the ACCEPT confirms');
    });
  });

  group('T5 wall-clock runaway-stop (§ 3.3 / § 6.5)', () {
    test(
      'with the deadline tripped, the loop exits incomplete with a non-empty '
      'answer (never silent)',
      () async {
        // Intended contract once a body-readable deadline primitive exists:
        //   - force the deadline into the past;
        //   - script a loop that always answers CONTINUE;
        //   - assert the run still returns a non-empty answer with
        //     incomplete == true (the only non-confirmation exit, § 3.3).
        // Cannot be driven today: the cognition layer has no clock primitive,
        // so the body cannot gracefully observe `_deadlineTripped()`. Tracked
        // in open_topics.tom_brain.md.
      },
      skip: 'needs a body-readable deadline primitive (§ 3.3); see '
          'open_topics.tom_brain.md',
    );
  });

  group('T6 the answering prompt carries the todo-discipline block (§ 4 / § 6.6)',
      () {
    test('the assembled prompt teaches the todo.* tools', () async {
      final engine = await buildEngine();
      substrate.answerTurns = <_Turn>[_Turn.text('plain answer')];
      substrate.confirmationVerdicts = <String>['DONE'];

      await runMemory(engine, 'hello', sessionId: 's-prompt');

      // The reminder the request mandates: the prompt must name the todo tools
      // (with a worked sample the model can copy parameter names from, § 9.1).
      final prompt = substrate.toolBearingPrompts.last.toLowerCase();
      expect(prompt, contains('todo.add'),
          reason: 'the prompt must instruct the model to seed todos');
      expect(prompt, contains('todo.update'),
          reason: 'the prompt must instruct the model to mark todos done');
    });
  });
}

// ── A scripted, role-aware + tool-capable substrate double ──────────
//
// Memory mode (default): tools-bearing `assistant_to_user` turns consume
// [answerTurns] in order — each is either a list of proposed tool calls or a
// plain answer. Thinking mode: tool-less `assistant_to_user` synthesis returns
// a fresh `draft #N` and fires [onSynthesis]; the `evaluator` role drives
// ACCEPT / REJECT off [evaluatorVerdicts]. The completion-confirmation call
// (`assistant_to_user`, no tools, keyed off [_confirmationSentinel]) is answered
// from [confirmationVerdicts]. All other roles (the recall conductor, analyser,
// sub_thinker) return harmless canned text the loop degrades gracefully on
// (PE-6).
class _ScriptedSubstrate implements TomBrainSubstrateClient {
  /// When true, `assistant_to_user` calls are thinking-path synthesis drafts
  /// (tool-less) rather than memory-path tools-bearing answer turns.
  bool thinkingMode = false;

  /// Memory-path answer turns, consumed by tools-bearing `assistant_to_user`
  /// calls in order. When exhausted, a terminal `'done'` answer is returned.
  List<_Turn> answerTurns = <_Turn>[];
  int _answerIdx = 0;

  /// Evaluator verdicts, in order; [defaultVerdict] once exhausted.
  List<String> evaluatorVerdicts = <String>['ACCEPT'];
  String defaultVerdict = 'ACCEPT';
  int _evalIdx = 0;

  /// Completion-confirmation verdicts (`DONE` / `CONTINUE`), in order;
  /// [defaultConfirmation] once exhausted (the never-hang default is `DONE`).
  List<String> confirmationVerdicts = <String>['DONE'];
  String defaultConfirmation = 'DONE';
  int _confIdx = 0;

  /// The prompts of every completion-confirmation call, in order.
  final List<String> confirmationPrompts = <String>[];

  /// How many completion-confirmation calls were issued.
  int get confirmationCount => confirmationPrompts.length;

  /// Fired with the 1-based synthesis draft count each time a thinking-mode
  /// synthesis draft is produced — the seam a test uses to simulate the act
  /// stage making progress on the session todo store.
  void Function(int draftCount)? onSynthesis;

  final Map<String, int> _byRole = <String, int>{};

  /// The prompts of every tools-bearing completion, in order.
  final List<String> toolBearingPrompts = <String>[];

  int _synthCount = 0;

  /// How many tool-less `assistant_to_user` synthesis drafts were produced.
  int get synthCount => _synthCount;

  /// How many times [roleId] was called.
  int countOf(String roleId) => _byRole[roleId] ?? 0;

  /// The canned synthesised draft text for the [n]-th synthesis call (1-based).
  String draftFor(int n) => 'draft #$n';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final role = call.roleId;
    _byRole[role] = (_byRole[role] ?? 0) + 1;
    final hasTools = call.options.toolCatalogue.isNotEmpty;
    final promptInput = call.inputs['prompt'];
    final prompt = promptInput is String ? promptInput : '';

    if (role == 'evaluator') {
      final idx = _evalIdx++;
      final verdict =
          idx < evaluatorVerdicts.length ? evaluatorVerdicts[idx] : defaultVerdict;
      return _text(verdict);
    }

    if (role == 'assistant_to_user') {
      // The completion-confirmation call (`sub.llm`, no tools): keyed off the
      // confirmation sentinel so it is never mistaken for a synthesis draft or
      // an answer turn. Matched as a prefix (the raw question is passed verbatim)
      // so a re-entry's answer/synthesis prompt — which embeds the prior
      // confirmation turn in its history — is not mis-detected. Detected before
      // the answer/synthesis routing.
      if (prompt.trimLeft().startsWith(_confirmationSentinel)) {
        confirmationPrompts.add(prompt);
        final idx = _confIdx++;
        final verdict = idx < confirmationVerdicts.length
            ? confirmationVerdicts[idx]
            : defaultConfirmation;
        return _text(verdict);
      }
      if (!thinkingMode && hasTools) {
        toolBearingPrompts.add(prompt);
        return _consumeAnswerTurn();
      }
      // Thinking-path synthesis (tool-less): a fresh draft per iteration.
      final n = ++_synthCount;
      onSynthesis?.call(n);
      return _text(draftFor(n));
    }

    // analyser / sub_thinker / recall-conductor roles.
    return _text(_cannedFor(role));
  }

  Stream<LlmStreamEvent> _consumeAnswerTurn() {
    if (_answerIdx >= answerTurns.length) {
      return _text('done');
    }
    return _text(answerTurns[_answerIdx++].text);
  }

  String _cannedFor(String role) {
    switch (role) {
      case 'analyser':
        return 'Analysis: the user asks a reflective question.';
      case 'sub_thinker':
        return 'Sub-reasoning: the relevant factors are X, Y, Z.';
      default:
        return 'ok';
    }
  }

  Stream<LlmStreamEvent> _text(String text) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        LlmStreamChunk(callId: 'c', text: text),
        _completed(),
      ]);

  LlmStreamCompleted _completed() => const LlmStreamCompleted(
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

/// One scripted memory-path answer turn — the plain-answer [text] the inner
/// `tool_loop_v1` cycle returns for one `sub.run`.
class _Turn {
  _Turn.text(this.text);

  final String text;
}

// ── A consolidated stateful `TomBrainMemory` (the gt1 / d42 shape) ───
//
// Recall-configurable, persist/edge-capturing, trail + stack modelling — enough
// for the run recorder's writes to succeed and for the loop's persist
// post-conditions to be read off one object.
class _BrainMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];
  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

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
  }) async {
    recordedEdges.add((from: from, type: type, to: to));
    return EdgeId.generate();
  }

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
