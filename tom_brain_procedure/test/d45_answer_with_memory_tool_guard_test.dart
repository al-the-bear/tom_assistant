// D.45 — `answer_with_memory_v1` unresolved tool-call guard
// (`agent_loop_completion.md` § 9.1 Todo 8).
//
// D.44 proved a *resolved* tool-deciding turn's `call:NAME{…}` text never
// leaks onto the answer channel. This suite guards the adjacent failure mode:
// a completion that *looks* like a tool-call attempt but resolves to **zero**
// executable calls — a tool name not on offer (or args that fail every parse).
//
// The live defect this guards: such a completion's text is still
// `call:totally.bogus{…}`-shaped prose. Before the guard, the loop saw an empty
// `toolCalls`, treated the text as a plain answer, and returned the raw bogus
// call text as the user's answer. The fix flags the completion
// (`unresolvedToolCall`) so the loop feeds an **error turn** back — naming the
// available tools and asking for a valid call or a plain answer — and re-enters,
// instead of terminating on the unusable text.
//
// What this proves, against the shipped `scripts/system/` artifact:
//
//   1. NO LEAK — the answer the user reads never carries the bogus call text.
//   2. RE-ENTRY — the loop did not exit on the bogus turn; it ran another
//      substrate turn (the error turn) before producing the real answer.
//   3. TERMINAL ANSWER — the eventual plain answer is what the user gets.
//
// The doubles mirror D.44's recall/substrate stubs; the substrate expresses its
// first turn as a TEXT call to a tool that is not in the live catalogue, so the
// call resolves to zero executable calls (the unresolved path).

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
  late _UnknownToolThenAnswerSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _UnknownToolThenAnswerSubstrate();
    memoryBridge = MemoryBridge(memory);
    parity = AnswerParityPrompts();
    // Increment 6 (§7.4): the answer prompt's tool set is resolved from its tool
    // policy. The shipped `defaultToolCatalogue()` matches `tool.list()`, so the
    // answer-step calls carry tools (gating the substrate's bogus-call branch)
    // and the bogus `call:totally.bogus{…}` resolves to zero executable calls
    // against it — the unresolved-attempt path this suite guards.
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

  group('D.45 an unresolved tool-call attempt is not returned as the answer', () {
    test(
      'the loop re-enters with an error turn and delivers the real answer',
      () async {
        substrate.bogusCallTextFor = 'totally.bogus';
        substrate.answerText = 'the final answer';

        final answerDeltas = <String>[];
        final resolver = await systemResolver();
        final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
        final outcome = await engine
            .invoke(
              ProcedureInvocation(
                procedureId: 'answer_with_memory_v1',
                arguments: <String, Object?>{'text': 'please use a tool'},
              ),
              tokenSink: (String delta) async => answerDeltas.add(delta),
            )
            .outcome;

        expect(outcome.status, TrailOutcomeStatus.accepted);

        // The bogus, unresolved call text must never reach the answer channel.
        final answerStream = answerDeltas.join();
        expect(answerStream, isNot(contains('call:totally.bogus')));
        // The terminal, valid answer is what the user gets.
        expect(answerStream, contains('the final answer'));

        // The loop did not exit on the bogus turn: it ran the error-turn re-entry
        // and then the answer turn (≥ 2 substrate completions).
        expect(substrate.callCount, greaterThanOrEqualTo(2));
      },
    );
  });
}

// ── A substrate whose first tools-bearing turn calls an unknown tool ──
//
// The first tools-bearing call writes `call:<bogus>{…}` as TEXT for a tool the
// engine never registered, so the bridge resolves zero executable calls (an
// unresolved attempt). Every subsequent tools-bearing call answers plainly, so
// once the loop feeds its error turn back the next turn terminates.
class _UnknownToolThenAnswerSubstrate implements TomBrainSubstrateClient {
  /// When non-null, the first tools-bearing call writes
  /// `call:<bogusCallTextFor>{text: "probe"}` — a tool not on offer.
  String? bogusCallTextFor;

  /// The text the substrate answers with once it stops proposing.
  String answerText = 'ok';

  /// Total `completeStream` invocations — proves the loop re-entered.
  int callCount = 0;

  bool _proposed = false;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    callCount += 1;
    final hasTools = call.options.toolCatalogue.isNotEmpty;

    const completed = LlmRunCompleted(
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

    if (hasTools && bogusCallTextFor != null && !_proposed) {
      _proposed = true;
      // A text call to a tool not in the live catalogue — looks like a tool
      // call, resolves to zero executable calls (the unresolved path).
      return Stream<LlmEvent>.fromIterable(<LlmEvent>[
        LlmTextDelta('call:$bogusCallTextFor{text: "probe"}'),
        completed,
      ]);
    }

    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(answerText),
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── A recall-capturing `TomBrainMemoryClient` (mirrors D.44) ────────
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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
