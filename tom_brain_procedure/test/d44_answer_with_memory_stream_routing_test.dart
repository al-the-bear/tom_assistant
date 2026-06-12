// D.44 — `answer_with_memory_v1` per-call stream routing
// (`agent_loop_completion.md` § 9.2 Todo 6; procedure spec § 11 step 2).
//
// D.43 proved the loop can *call* a tool. This suite proves the loop streams
// the right text to the right channel: a **tool-deciding** turn's text (the
// `call:NAME{…}` the model writes under the text tool protocol) must never
// reach the **answer** channel the user reads — it belongs on the **thinking**
// channel. Only the **terminal** answer reaches the answer channel.
//
// The live defect this guards: under the text tool protocol a tool-deciding
// turn's completion is prose like `call:memory.read{text: "…"}`. The old loop
// forwarded every `sub.llm` token to the per-run answer sink, so that tool-call
// text leaked into the streamed answer. The fix routes a tools-offered turn's
// tool-deciding text to the thinking sink and delivers only the terminal answer
// (via `emit`) on the answer sink.
//
// What this proves, against the shipped `scripts/system/` artifact and the
// engine's per-run sink bindings:
//
//   1. NO LEAK — with a tool-deciding turn expressed as text, the answer
//      channel (`tokenSink`) never carries the `call:memory.read{…}` text.
//   2. TERMINAL ANSWER ON THE ANSWER CHANNEL — the answer channel carries the
//      final answer text.
//   3. TOOL TEXT ON THE THINKING CHANNEL — the thinking sink carries the
//      tool-deciding turn's text (added once the new sink is wired).
//
// The doubles mirror D.43's recall/substrate stubs; the substrate expresses its
// first tool call as a TEXT completion (the text-protocol path) rather than a
// native `LlmStreamToolCallProposed`, because the leak only manifests for text.

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
  late _RecallCapturingMemory memory;
  late _TextToolThenAnswerSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _TextToolThenAnswerSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
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

  group('D.44-1 a tool-deciding turn never leaks onto the answer channel', () {
    test('the answer channel carries the final answer, not the call: text',
        () async {
      substrate.proposeReadTextFor = 'the tool probe';
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

      final answerStream = answerDeltas.join();
      // The tool-deciding turn's text was the tool call itself; it must never
      // reach the answer the user reads.
      expect(answerStream, isNot(contains('call:memory.read')));
      // The terminal answer is what the user gets.
      expect(answerStream, contains('the final answer'));
    });
  });

  group('D.44-2 a tool-deciding turn streams on the thinking channel', () {
    test('the thinking channel carries the call: text, the answer does not',
        () async {
      substrate.proposeReadTextFor = 'the tool probe';
      substrate.answerText = 'the final answer';

      final answerDeltas = <String>[];
      final thinkingDeltas = <String>[];
      final resolver = await systemResolver();
      final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
      final outcome = await engine
          .invoke(
            ProcedureInvocation(
              procedureId: 'answer_with_memory_v1',
              arguments: <String, Object?>{'text': 'please use a tool'},
            ),
            tokenSink: (String delta) async => answerDeltas.add(delta),
            thinkingSink: (String text) => thinkingDeltas.add(text),
          )
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);

      final thinkingStream = thinkingDeltas.join();
      // The tool-deciding turn's text lands on the thinking channel…
      expect(thinkingStream, contains('call:memory.read'));
      // …and never on the answer the user reads.
      final answerStream = answerDeltas.join();
      expect(answerStream, isNot(contains('call:memory.read')));
      expect(answerStream, contains('the final answer'));
    });
  });
}

// ── A substrate that proposes one tool call AS TEXT, then answers ───
//
// Keyed on whether the call carried a tool catalogue (only the answer step of
// `answer_with_memory_v1` offers tools). The first tools-bearing call writes a
// `call:memory.read{…}` completion (the text tool protocol — the leak path);
// every subsequent tools-bearing call answers, so the loop terminates.
class _TextToolThenAnswerSubstrate implements TomBrainSubstrateClient {
  /// When non-null, the first tools-bearing call writes
  /// `call:memory.read{text: …}` as its completion text.
  String? proposeReadTextFor;

  /// The text the substrate answers with on a non-proposing completion.
  String answerText = 'ok';

  bool _proposed = false;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final hasTools = call.options.toolCatalogue.isNotEmpty;

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

    if (hasTools && proposeReadTextFor != null && !_proposed) {
      _proposed = true;
      // The tool call rides in the completion TEXT (the text tool protocol),
      // not as a native proposal — this is the only shape that can leak onto
      // the answer channel.
      return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        LlmStreamChunk(
          callId: 'c',
          text: 'call:memory.read{text: "$proposeReadTextFor"}',
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

// ── A recall-capturing `TomBrainMemoryClient` (mirrors D.43) ────────
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
