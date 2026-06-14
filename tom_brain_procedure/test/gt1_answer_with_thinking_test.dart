// G-T1 — `answer_with_thinking_v1` recursive-loop acceptance suite
// (`tom_brain_completion_plan.md` Todo 6; `thinking_specification.md`
// § 4.1–4.7).
//
// Plan step 6.2 (verbatim): "Tests: the loop dispatches sub-prompts, runs an
// evaluator critique, re-enters on rejection, and terminates on accept or
// budget exhaustion; `answer_with_memory_v1` (normal branch) is unchanged and
// still invoked by the router (G-T4)." Plan step 6.5 (gap-hunt): the loop must
// not silently truncate a foreground user prompt without an answer, and the
// evaluator-reject → re-enter path is exercised.
//
// ── Termination contract migrated to todo-based (agent-loop completion plan
//    § 3 / § 5.2, Todo #3) ──────────────────────────────────────────────────
//
// The loop no longer terminates on an iteration cap. It re-enters until every
// session todo is done AND the critique accepts; the only non-todo exit is the
// wall-clock runaway-stop, enforced externally by the engine and not observable
// in the body. The original GT1-4 / GT1-5 pinned the *iteration-cap exhaustion*
// behaviour (`maxIterations`, best-effort draft, `incomplete = true`) — a
// contract this migration removes (`maxIterations` is gone). Those two tests
// were therefore dropped: the "never silent on a hung run" guarantee they
// guarded is now the wall-clock runaway-stop, covered by
// `agent_loop_termination_test.dart` test T5 (skipped pending a body-readable
// deadline primitive — `open_topics.tom_brain.md`). The accept / re-entry /
// dispatch behaviours (GT1-1…GT1-3) are unchanged and remain pinned here; the
// todo-based termination itself is proven in `agent_loop_termination_test.dart`
// (T2 / T4).
//
// This is the *procedure-side* proof of the recursive loop. It drives the
// shipped `scripts/system/answer_with_thinking_v1.dart` through the engine
// with:
//
//   - a **role-aware** substrate double that returns distinct canned text per
//     role (`analyser` / `sub_thinker` / `assistant_to_user` / `evaluator`) and
//     drives the accept / reject decision off a queue of evaluator verdicts, so
//     the test controls how many times the loop re-enters; and
//   - a configurable memory double (the d42 `_BrainMemory` shape) so the
//     recall → synthesise → persist post-conditions can be read off one object.
//
// The four behaviours the plan pins:
//
//   GT1-1  accept on the first critique — one draft, one evaluator call, the
//          answer is returned, `incomplete` is false, and the trail is
//          persisted (Event + Conclusion + derived_from + produced_by).
//   GT1-2  the loop dispatches sub-prompts — the `analyser`, `sub_thinker`,
//          `assistant_to_user` and `evaluator` roles are all called, and the
//          recall conductor (`retrieve_for_prompt_v1`) runs.
//   GT1-3  re-entry on rejection — a REJECT then an ACCEPT yields two drafts
//          and two critiques; the *accepted* (second) draft is returned and
//          `incomplete` is false.
//
// (The former GT1-4 / GT1-5 iteration-cap exhaustion tests were dropped with the
// migration to todo-based termination — see the contract note above.)
//
// The procedure is loaded from the real `scripts/system/` store+resolver path
// so the test exercises the shipped artifact, not an inline copy (mirrors
// d42 / gt2).

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
  late _BrainMemory memory;
  late _RoleAwareSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _BrainMemory();
    substrate = _RoleAwareSubstrate();
    memoryBridge = MemoryBridge(memory);
    parity = AnswerParityPrompts();
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
        now: () => DateTime.utc(2026, 6, 9, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> thinkAbout(String text) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'answer_with_thinking_v1',
          arguments: <String, Object?>{
            'text': text,
          },
        ))
        .outcome;
  }

  // Two recalled node ids the synthesised Conclusion should cite.
  final citedA = NodeId.fromString('n_00000000000000000000000042');
  final citedB = NodeId.fromString('n_00000000000000000000000043');

  /// Seeds recall with two text-bearing cited nodes so the synthesised
  /// Conclusion can draw `derived_from` edges (the trail's provenance).
  void seedRecall() {
    memory.recallResult = RecallResult(
      nodes: <Node>[
        Node(
          id: citedA,
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'memory consolidates in sleep'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
        Node(
          id: citedB,
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'dreaming reconsolidates'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 2},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 7,
      ),
    );
  }

  /// The authoritative final `ProcedureRun` node for the top-level thinking run
  /// — matched by `procedureId`, since the nested recall conductor + `recall_*`
  /// sub-procedures each record their own ProcedureRun (Extension-H step #30).
  ({NodeId id, NodeDraft draft}) finalRunNode() =>
      memory.persistedOfType('ProcedureRun').firstWhere(
            (p) =>
                p.draft.values['status'] != 'running' &&
                p.draft.values['procedureId'] == 'answer_with_thinking_v1',
          );

  group('GT1-1 accept on the first critique', () {
    test('one draft, one critique, the answer is returned and complete',
        () async {
      seedRecall();
      substrate.evaluatorVerdicts = <String>['ACCEPT'];

      final outcome = await thinkAbout('think about how memory consolidates');

      // (a) The run is accepted.
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // (b) The accepted draft is the answer; the loop ran exactly one
      //     iteration (one synthesise, one critique).
      expect(outcome.result!.output<String>('answer'),
          substrate.draftFor(1));
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
      expect(substrate.countOf('assistant_to_user'), 1);
      expect(substrate.countOf('evaluator'), 1);

      // (c) The trail is persisted: an Event for the prompt, a Conclusion for
      //     the answer.
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'],
          'think about how memory consolidates');
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'], substrate.draftFor(1));

      // (d) derived_from edges tie the Conclusion to each cited recalled node.
      final derivedTargets = memory.recordedEdges
          .where((e) => e.type == EdgeType.derivedFrom && e.from == conclusion.id)
          .map((e) => e.to)
          .toSet();
      expect(derivedTargets, <NodeId>{citedA, citedB});

      // (e) a produced_by edge ties the Conclusion to the final run node.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusion.id,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRunNode().id);

      // (f) the reserved transport channel never surfaces as an output.
      expect(outcome.result!.outputs.containsKey(producedNodeIdsOutputKey),
          isFalse);
    });
  });

  group('GT1-2 the loop dispatches sub-prompts (§ 4.2–4.4)', () {
    test('analyser, sub_thinker, assistant_to_user, evaluator are all called '
        'and the recall conductor runs', () async {
      seedRecall();
      substrate.evaluatorVerdicts = <String>['ACCEPT'];

      await thinkAbout('reason about the tradeoffs of local LLMs');

      // Stage A analyse, stage B sub-thinking, stage C synthesise, stage D
      // critique each name their role.
      expect(substrate.countOf('analyser'), greaterThanOrEqualTo(1));
      expect(substrate.countOf('sub_thinker'), greaterThanOrEqualTo(1));
      expect(substrate.countOf('assistant_to_user'), greaterThanOrEqualTo(1));
      expect(substrate.countOf('evaluator'), greaterThanOrEqualTo(1));

      // Stage B memory recall runs through the conductor.
      expect(memory.recallInvoked, isTrue);
    });
  });

  group('GT1-3 re-entry on rejection (stage E)', () {
    test('a REJECT then an ACCEPT yields two drafts; the accepted draft wins',
        () async {
      seedRecall();
      substrate.evaluatorVerdicts = <String>['REJECT', 'ACCEPT'];

      final outcome = await thinkAbout('work through the backup topology');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // Two synthesise passes, two critiques: the loop re-entered once.
      expect(substrate.countOf('assistant_to_user'), 2);
      expect(substrate.countOf('evaluator'), 2);
      // The second (accepted) draft is the returned answer.
      expect(outcome.result!.output<String>('answer'), substrate.draftFor(2));
      expect(outcome.result!.output<bool>('incomplete'), isFalse);
    });
  });

  group('GT1-6 tool-enabled synthesis (§9 — the "normal prompt")', () {
    test('the synthesis draft is offered the tool catalogue; the critique is '
        'not', () async {
      seedRecall();
      // `tools: all` resolves to a non-empty catalogue; the parity resolver
      // surfaces it for every stage except the `tools: none` critique.
      parity.tools = defaultToolCatalogue();
      substrate.evaluatorVerdicts = <String>['ACCEPT'];

      await thinkAbout('synthesise with tools available');

      // The synthesis draft (the user-facing role) saw the catalogue; the
      // evaluator critique never did (§9 — critique is `tools: none`).
      expect(substrate.rolesWithTools, contains('assistant_to_user'));
      expect(substrate.rolesWithTools, isNot(contains('evaluator')));
    });
  });

  group('GT1-7 re-entry templates on pass ≥2 (§9)', () {
    test('the first pass selects the base templates; the re-entry pass selects '
        'the *_reentry templates', () async {
      seedRecall();
      substrate.evaluatorVerdicts = <String>['REJECT', 'ACCEPT'];

      await thinkAbout('re-enter the loop once');

      final ids = parity.requests.map((r) => r.id).toList();
      // First pass: the base analysis + synthesis templates.
      expect(ids, contains('assist_user.answer_with_thinking.analysis'));
      expect(ids, contains('assist_user.answer_with_thinking.synthesis'));
      // Second pass (after the REJECT): the re-entry variants.
      expect(ids, contains('assist_user.answer_with_thinking.analysis_reentry'));
      expect(
          ids, contains('assist_user.answer_with_thinking.synthesis_reentry'));
    });
  });

  group('GT1-8 history accumulation into the re-entry prompt (§9)', () {
    test('the rejected draft + its critique flow into the re-entry synthesis '
        'via \${rejection_context}', () async {
      seedRecall();
      substrate.evaluatorVerdicts = <String>['REJECT', 'ACCEPT'];

      await thinkAbout('accumulate the rejection history');

      // The synthesis_reentry request carries the accumulated rejection history,
      // which includes the first rejected draft (`draft #1`).
      final reentry = parity.requests.firstWhere(
        (r) => r.id == 'assist_user.answer_with_thinking.synthesis_reentry',
      );
      final context = reentry.inputs['rejection_context'];
      expect(context, isA<String>());
      expect(context as String, isNotEmpty);
      expect(context, contains(substrate.draftFor(1)));
    });
  });
}

// ── A role-aware `TomBrainSubstrateClient` ──────────────────────────
//
// Returns distinct canned text per role so the loop's stages are
// individually observable, and drives the accept / reject decision off
// [evaluatorVerdicts] (consumed in order; [defaultVerdict] once the queue is
// empty). `assistant_to_user` produces a fresh `draft #N` per call so the
// test can assert *which* draft won. Counts calls per role and tolerates the
// recall conductor's retrieval-role calls (they fall through to the default
// text and degrade gracefully — PE-6).
class _RoleAwareSubstrate implements TomBrainSubstrateClient {
  final Map<String, int> _byRole = <String, int>{};

  /// The opening line of the completion-confirmation prompt (agent-loop
  /// completion plan § 3.1, revision 2026-06-14). After each accepted draft the
  /// body asks the model — in its normal `assistant_to_user` profile — whether
  /// it is `DONE` or wants to `CONTINUE`; that call reaches the substrate as a
  /// `sub.llm` with `inputs['prompt']` starting with this sentinel, distinct
  /// from the synthesis drafts (which arrive through `sub.run`'s assembled
  /// template, never carrying a raw `prompt`). The double routes it to a
  /// [confirmationVerdicts] queue and does **not** count it as a draft.
  static const String _confirmationSentinel =
      'You have just produced an answer for the user.';

  /// The evaluator verdicts to emit, in order. When exhausted, [defaultVerdict]
  /// is used. A REJECT forces a re-entry; an ACCEPT exits the loop.
  List<String> evaluatorVerdicts = <String>['ACCEPT'];

  /// The verdict emitted once [evaluatorVerdicts] is exhausted (default
  /// ACCEPT so an under-specified test still terminates; the exhaustion tests
  /// set it to REJECT).
  String defaultVerdict = 'ACCEPT';

  /// The completion-confirmation replies to emit, in order. When exhausted,
  /// [defaultConfirmation] is used. `DONE` terminates the loop; `CONTINUE …`
  /// re-enters. Defaults to a single `DONE` so an under-specified test
  /// terminates after the first accepted draft.
  List<String> confirmationVerdicts = <String>['DONE'];

  /// The confirmation reply emitted once [confirmationVerdicts] is exhausted.
  String defaultConfirmation = 'DONE';

  int _evaluatorCalls = 0;
  int _confirmationCalls = 0;

  /// How many completion-confirmation calls the loop issued.
  int get confirmationCount => _confirmationCalls;

  /// The set of roles whose completion was offered a non-empty tool catalogue —
  /// the proof that `tools: all` reaches the substrate for the synthesis draft
  /// while `tools: none` keeps the critique tool-free (§9).
  final Set<String> rolesWithTools = <String>{};

  /// How many times [roleId] was called.
  int countOf(String roleId) => _byRole[roleId] ?? 0;

  /// The synthesised draft text for the [n]-th `assistant_to_user` call
  /// (1-based) — the canned text this double returns for that draft.
  String draftFor(int n) => 'draft #$n';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final role = call.roleId;
    final rawPrompt = call.inputs['prompt'];
    final isConfirmation = role == 'assistant_to_user' &&
        rawPrompt is String &&
        rawPrompt.trimLeft().startsWith(_confirmationSentinel);
    final text = isConfirmation ? _nextConfirmation() : _textForCounted(role);
    if (call.options.toolCatalogue.isNotEmpty) {
      rolesWithTools.add(role);
    }
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: text),
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

  /// Counts the [role] call (drafts are numbered off this count) and returns
  /// its canned text. The confirmation call is handled before this point and
  /// never reaches here, so it never inflates a role count.
  String _textForCounted(String role) {
    _byRole[role] = (_byRole[role] ?? 0) + 1;
    return _textFor(role);
  }

  /// The next completion-confirmation reply (DONE / CONTINUE …), consumed in
  /// order from [confirmationVerdicts] with [defaultConfirmation] as the
  /// fallback. Increments [confirmationCount].
  String _nextConfirmation() {
    final n = _confirmationCalls++;
    return n < confirmationVerdicts.length
        ? confirmationVerdicts[n]
        : defaultConfirmation;
  }

  String _textFor(String role) {
    switch (role) {
      case 'analyser':
        return 'Analysis: the user is asking a reflective question.';
      case 'sub_thinker':
        return 'Sub-reasoning: the relevant factors are X, Y, Z.';
      case 'assistant_to_user':
        return draftFor(_byRole['assistant_to_user']!);
      case 'evaluator':
        final n = _evaluatorCalls++;
        return n < evaluatorVerdicts.length
            ? evaluatorVerdicts[n]
            : defaultVerdict;
      default:
        // Retrieval-role calls from the recall conductor: any text; the
        // conductor degrades gracefully on a non-JSON result (PE-6).
        return 'ok';
    }
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

// ── A consolidated stateful `TomBrainMemory` ────────────────────────
//
// The d42 `_BrainMemory` shape: recall-configurable, persist/edge-capturing,
// trail + stack modelling — enough for the run recorder's writes to succeed
// and for the loop's persist post-conditions to be read off one object.
class _BrainMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];
  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  /// Set true once the recall conductor's `recall.multi` (or a direct recall)
  /// runs — the proof the loop dispatched its memory sub-prompt.
  bool recallInvoked = false;

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
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallInvoked = true;
    return recallResult;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    recallInvoked = true;
    return recallResult;
  }

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
