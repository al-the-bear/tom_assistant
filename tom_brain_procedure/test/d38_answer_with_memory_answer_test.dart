// D.38 — `answer_with_memory_v1` step 2 (answer) acceptance suite.
//
// Plan step D.38 (verbatim): "Step 2 — answer: `llm(prompt:
// assembled-from-recall + access.envelope.text, role: 'assistant_to_user')`.
// Stream tokens back via the `Access.deliver` callback." This is the second
// body step: after recall, the body assembles a prompt out of the recalled
// memory plus the inbound prompt and runs it through the substrate's `llm`
// under the user-facing role, returning the generated answer as the `answer`
// output.
//
// The proof obligation is that, when the shipped disk procedure is invoked
// through the engine with a `text` input and a recall double that returns
// memory, the body:
//
//   1. ASSEMBLES THE PROMPT from recall + the inbound text — every recalled
//      node's `text` value becomes a context line and the user prompt is
//      appended, and that assembled string is what reaches `sub.llm`.
//   2. NAMES THE USER-FACING ROLE — `assistant_to_user`.
//   3. SURFACES THE ANSWER — the run closes `accepted` and the concatenated
//      LLM chunk text is the `answer` output.
//
// `Access.deliver` token streaming is a Phase E concern not reachable from the
// procedure prototype (Q-D.38.1); `sub.llm` drains the stream and returns the
// whole answer (Q-C.13.1), which is what this suite asserts.
//
// The procedure is loaded from the real `scripts/system/` store+resolver path
// so the test exercises the shipped artifact, not an inline copy.

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
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _AnsweringSubstrate();
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

  /// Seeds the recall double with two text-bearing nodes.
  void seedRecall() {
    memory.recallResult = RecallResult(
      nodes: <Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000042'),
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'rsync nightly to the NAS'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
        Node(
          id: NodeId.fromString('n_00000000000000000000000043'),
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'the NAS lives at 10.0.0.4'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 4},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 9,
      ),
    );
  }

  group('D.38-1 the prompt is assembled from recall + the inbound text', () {
    test('every recalled node text and the user prompt reach sub.llm',
        () async {
      seedRecall();

      await runWith('how do I automate backups?');

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      // The recalled node texts appear as context lines.
      expect(prompt, contains('rsync nightly to the NAS'));
      expect(prompt, contains('the NAS lives at 10.0.0.4'));
      // The inbound prompt is folded in.
      expect(prompt, contains('how do I automate backups?'));
    });

    test('with no recall the prompt is just the user prompt', () async {
      // Default recallResult is empty — no context block, only the prompt.
      await runWith('plain question');

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(prompt, contains('plain question'));
      expect(prompt, isNot(contains('Relevant recalled memory')));
    });
  });

  group('D.38-2 the answer step names the user-facing role', () {
    test('the role is assistant_to_user', () async {
      seedRecall();

      await runWith('how do I automate backups?');

      expect(substrate.lastCall!.roleId, 'assistant_to_user');
    });
  });

  group('D.38-3 the run succeeds and surfaces the generated answer', () {
    test('the outcome is accepted and the answer output is the LLM text',
        () async {
      seedRecall();
      substrate.answerChunks = <String>['Back up by ', 'rsyncing nightly.'];

      final outcome = await runWith('how do I automate backups?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'Back up by rsyncing nightly.');
    });
  });
}

// ── An answer-capturing `TomBrainSubstrateClient` ───────────────────
//
// Captures the `LlmCall` the bridge constructs (so the test can assert the
// assembled prompt and the role) and emits a canned chunked stream that
// terminates with Completed. `embed` is satisfied minimally; everything else
// falls through to `noSuchMethod`.
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<String> answerChunks = <String>['ok'];

  /// The opening line of the completion-confirmation prompt (agent-loop
  /// completion plan § 3.1, revision 2026-06-14). After each accepted draft the
  /// body asks the model whether it is `DONE` or wants to `CONTINUE` via a
  /// direct `sub.llm` call; that call must NOT be captured as the answer call.
  static const String _confirmationSentinel =
      'You have just produced an answer for the user.';

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final rawPrompt = call.inputs['prompt'];
    final isConfirmation = call.roleId == 'assistant_to_user' &&
        rawPrompt is String &&
        rawPrompt.trimLeft().startsWith(_confirmationSentinel);
    // The confirmation call terminates the loop with `DONE`; the answer call is
    // the one the suite asserts against, so only it is captured.
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
    lastCall = call;
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

// ── A recall-capturing `TomBrainMemoryClient` ───────────────────────
//
// Returns a configurable recall result and models just enough of the store
// for the run recorder's writes to succeed (trails are entry logs, stacks are
// push/peek containers, persisted nodes are resolvable by id). Mirrors the
// C.18 / D.8 / D.37 doubles.
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  RecallQuery? lastRecallQuery;
  MultiRecallQuery? lastMultiRecallQuery;
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// The classification `classify` returns. `unknown` (far from every
  /// centroid / cold start) by default, so the step-4 cold-interest path
  /// fires; this suite pins prompt assembly + role, not the cold path, so the
  /// default is left as-is and the run still closes accepted.
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecallQuery = query;
    return recallResult;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
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
