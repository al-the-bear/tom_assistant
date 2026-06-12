// Agent-loop termination — the todo-based termination contract
// (`agent_loop_completion.md` § 3 / § 6, Todo #1; `thinking_specification.md`
// § 4).
//
// These are the RED tests of the agent-loop completion plan, written first.
// They pin the *target* termination contract that Todos #2 (memory path) and
// #3 (thinking path) must satisfy; against the current cap-based loops they
// fail (a plain answer with an open todo terminates early; the prompt carries
// no todo-discipline block; a REJECT records no todo). Once the two procedures
// are migrated to the `while (!finished)` guard of § 3.1 they go green.
//
// The contract under test (§ 3):
//
//   A run is finished IFF every session todo is `done` AND the investigation
//   accepts the last answer. The loop never exits merely because the model
//   stopped proposing tool calls (memory) or because a single critique
//   accepts while open todos remain (thinking). The only non-todo exit is the
//   wall-clock runaway-stop (§ 3.3).
//
// How the doubles express the contract:
//
//   - The engine binds each run's `todo.*` tools to the session store of the
//     invocation's `sessionId`, and exposes that registry as
//     `engine.sessionTodoStores`. The session store is therefore the single
//     source of truth for "what work is open" — the tests read and seed it
//     directly rather than scraping tool-result prose.
//   - `_ScriptedSubstrate` is role-aware (like gt1's double) AND tool-capable
//     (like d43's). In **memory mode** the tools-bearing `assistant_to_user`
//     turns are scripted as a queue of tool-proposals / plain-answers, so a
//     test can interleave `todo.add` / `todo.update` calls with a premature
//     plain answer. In **thinking mode** the synthesis (`assistant_to_user`,
//     tool-less) returns a fresh `draft #N` per call and the evaluator drives
//     ACCEPT / REJECT off a verdict queue, exactly as gt1.
//   - Thinking-path progress on todos is simulated with an `onSynthesis` hook
//     that mutates the session store directly. This keeps the thinking tests
//     decoupled from *how* the act stage will emit todo mutations (Todo #3
//     gates tool-calling to the act stage — an internal choice); the contract
//     they assert is only that the loop reads the live store to decide
//     termination. The hook fires on the synthesis draft count (one draft per
//     iteration), which is robust to whether the loop runs the evaluator every
//     iteration or only once todos are clear.
//
// Test 5 (wall-clock runaway-stop, § 6) is `skip`-ped: it needs the loop body
// to read a deadline, but the cognition layer has no clock primitive today
// (`answer_with_memory_v1.dart` l.320; confirmed — no body-readable budget /
// deadline surface in any bridge). Forcing it deterministically requires a new
// primitive, tracked in `open_topics.tom_brain.md`. The skipped test documents
// the intended assertions so it can be un-skipped once that primitive lands.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _BrainMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _BrainMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
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

  List<TodoEntry> openTodos(ProcedureEngine engine, String sessionId) {
    final store = engine.sessionTodoStores.peek(sessionId);
    if (store == null) return const <TodoEntry>[];
    return store.list().where((e) => !e.done).toList(growable: false);
  }

  group('T1 todo-based termination — memory path (§ 3 / § 6.1)', () {
    test(
        'a plain answer that leaves an open todo re-enters; the loop exits only '
        'once every todo is done', () async {
      final engine = await buildEngine();
      // Scripted tools-bearing answer turns: add a todo, then answer
      // prematurely (one todo still open), then mark it done, then the real
      // final answer.
      substrate.answerTurns = <_Turn>[
        _Turn.tools(<_ProposedCall>[_call('todo.add', {'text': 'step one'})]),
        _Turn.text('partial — still working on step one'),
        _Turn.tools(
            <_ProposedCall>[_call('todo.update', {'id': 't1', 'done': true})]),
        _Turn.text('final answer once every todo is done'),
      ];

      final outcome =
          await runMemory(engine, 'do a two-step task', sessionId: 's-mem');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The premature 'partial' answer must NOT win — the loop kept going
      // because a todo was still open (this is the assertion the current
      // stop-on-no-tool loop fails: it returns 'partial').
      expect(
        outcome.result!.output<String>('answer'),
        'final answer once every todo is done',
      );
      // And no todo is left open at the end.
      expect(openTodos(engine, 's-mem'), isEmpty,
          reason: 'termination requires every todo done');
    });
  });

  group('T2 todo-based termination — thinking path (§ 3 / § 6.2)', () {
    test(
        'an ACCEPT critique does not terminate while a session todo is open; '
        'the loop exits once todos are clear and the critique accepts',
        () async {
      seedRecall();
      substrate.thinkingMode = true;
      substrate.evaluatorVerdicts = <String>['ACCEPT', 'ACCEPT'];

      final engine = await buildEngine();
      // Pre-seed one open todo for this session. The thinking loop must read
      // it and refuse to terminate on the first ACCEPT.
      engine.sessionTodoStores.forSession('s-think').add('finish the analysis');
      // Simulate the act stage completing the work on the second iteration:
      // when the second synthesis draft is produced, mark every session todo
      // done so the loop can then terminate. (One synthesis draft per
      // iteration, so this is robust to the evaluator's call cadence.)
      substrate.onSynthesis = (int draftCount) {
        if (draftCount >= 2) {
          final store = engine.sessionTodoStores.peek('s-think')!;
          for (final e in store.list()) {
            store.update(e.id, done: true);
          }
        }
      };

      final outcome =
          await runThinking(engine, 'reflect on memory', sessionId: 's-think');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // Two synthesis passes: iter 1 ACCEPT had an open todo (re-enter); iter 2
      // ACCEPT with the todo cleared terminates. The current loop, which exits
      // on the first ACCEPT, produces only one draft.
      expect(substrate.synthCount, 2,
          reason: 'the open todo blocks the first ACCEPT from terminating');
      expect(outcome.result!.output<String>('answer'), substrate.draftFor(2));
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
      expect(openTodos(engine, 's-think'), isEmpty);
    });
  });

  group('T3 empty-todo bootstrap (§ 3.2 / § 6.3)', () {
    test('a trivial prompt that seeds no todos still produces an answer',
        () async {
      // Non-regression guard: the new bootstrap (§ 3.2 seeds an implicit todo)
      // must NOT let `_openTodoCount() == 0` short-circuit before any answer is
      // produced. Green both before and after the migration — it protects the
      // trivial case the todo-based exit could otherwise break.
      final engine = await buildEngine();
      substrate.answerTurns = <_Turn>[_Turn.text('hi there')];

      final outcome = await runMemory(engine, 'hello', sessionId: 's-boot');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final answer = outcome.result!.output<String>('answer');
      expect(answer, isNotNull);
      expect(answer!.isNotEmpty, isTrue,
          reason: 'never silent — a trivial prompt is still answered');
    });
  });

  group('T4 investigation pushes missing work as todos (§ 6.4)', () {
    test('a REJECT critique records at least one open todo and re-enters',
        () async {
      seedRecall();
      substrate.thinkingMode = true;
      substrate.evaluatorVerdicts = <String>['REJECT', 'ACCEPT'];

      final engine = await buildEngine();
      // Once the rejection has pushed its missing pieces as todos and the loop
      // re-enters, simulate the act stage completing them on the second draft
      // so the run can terminate.
      substrate.onSynthesis = (int draftCount) {
        if (draftCount >= 2) {
          final store = engine.sessionTodoStores.peek('s-reject');
          if (store != null) {
            for (final e in store.list()) {
              store.update(e.id, done: true);
            }
          }
        }
      };

      final outcome =
          await runThinking(engine, 'work the backup topology', sessionId: 's-reject');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The REJECT investigation fed its missing pieces back as todos — the
      // mechanism that lets "investigate the last answer" drive the todo-based
      // termination. The current loop re-enters on REJECT but records no todo,
      // so this store is empty against the shipped artifact.
      final store = engine.sessionTodoStores.peek('s-reject');
      expect(store, isNotNull,
          reason: 'the rejection created a session todo for its missing pieces');
      expect(store!.list(), isNotEmpty,
          reason: 'at least one todo was pushed by the REJECT investigation');
      expect(substrate.synthCount, greaterThanOrEqualTo(2),
          reason: 'the loop re-entered to work the pushed todo');
    });
  });

  group('T5 wall-clock runaway-stop (§ 3.3 / § 6.5)', () {
    test(
      'with the deadline tripped and an open todo, the loop exits incomplete '
      'with a non-empty answer (never silent)',
      () async {
        // Intended contract once a body-readable deadline primitive exists:
        //   - force the deadline into the past;
        //   - script a loop that never clears its open todo;
        //   - assert the run still returns a non-empty answer with
        //     incomplete == true (the only non-todo exit, § 3.3).
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

      await runMemory(engine, 'hello', sessionId: 's-prompt');

      // The reminder the request mandates: the prompt must name the todo tools
      // (with a worked sample the model can copy parameter names from, § 9.1).
      // The current `_assemblePrompt` renders only the passed-in catalogue and
      // says nothing about todos, so both substrings are absent today.
      final prompt = substrate.toolBearingPrompts.last.toLowerCase();
      expect(prompt, contains('todo.add'),
          reason: 'the prompt must instruct the model to seed todos');
      expect(prompt, contains('todo.update'),
          reason: 'the prompt must instruct the model to mark todos done');
    });
  });
}

_ProposedCall _call(String name, Map<String, Object?> args) =>
    _ProposedCall(name, args);

// ── A scripted, role-aware + tool-capable substrate double ──────────
//
// Memory mode (default): tools-bearing `assistant_to_user` turns consume
// [answerTurns] in order — each is either a list of proposed tool calls or a
// plain answer. Thinking mode: tool-less `assistant_to_user` synthesis returns
// a fresh `draft #N` and fires [onSynthesis]; the `evaluator` role drives
// ACCEPT / REJECT off [evaluatorVerdicts]. All other roles (the recall
// conductor, analyser, sub_thinker) return harmless canned text the loop
// degrades gracefully on (PE-6).
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

    if (role == 'evaluator') {
      final idx = _evalIdx++;
      final verdict =
          idx < evaluatorVerdicts.length ? evaluatorVerdicts[idx] : defaultVerdict;
      return _text(verdict);
    }

    if (role == 'assistant_to_user') {
      if (!thinkingMode && hasTools) {
        toolBearingPrompts.add(call.inputs['prompt']! as String);
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
    final turn = answerTurns[_answerIdx++];
    final calls = turn.calls;
    if (calls != null) {
      final events = <LlmStreamEvent>[];
      var i = 0;
      for (final c in calls) {
        events.add(LlmStreamToolCallProposed(
          callId: 'c',
          toolCallId: 'tc${i++}',
          toolName: c.name,
          arguments: c.args,
        ));
      }
      events.add(_completed());
      return Stream<LlmStreamEvent>.fromIterable(events);
    }
    return _text(turn.text!);
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

/// One scripted memory-path answer turn: either [calls] (a tool-proposing
/// turn) or [text] (a plain answer). Exactly one is non-null.
class _Turn {
  _Turn.tools(this.calls) : text = null;
  _Turn.text(this.text) : calls = null;

  final List<_ProposedCall>? calls;
  final String? text;
}

/// A single proposed tool call in a scripted [_Turn].
class _ProposedCall {
  _ProposedCall(this.name, this.args);

  final String name;
  final Map<String, Object?> args;
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
