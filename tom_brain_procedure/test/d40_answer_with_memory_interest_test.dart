// D.40 — `answer_with_memory_v1` step 4 (cold-classification interest push)
// acceptance suite.
//
// Plan step D.40 (verbatim): "Push an `InterestItem` to `interests` if the
// prompt embedding lands far from any existing centroid (cold-classification
// path)."
//
// The body implements the plan literally: it embeds the prompt (`sub.embed`)
// and classifies the vector against memory's node-type centroids
// (`mem.classify`). A `decision == 'unknown'` is memory's own "far from every
// centroid (or cold start)" signal (memory § 7.2) — the cold-classification
// path. `embed` and `classify` are therefore in this procedure's § 4.4
// `requires` set and on the bridged primitive surface (Q-D.40.1). The cold
// signal is no longer inferred from an empty recall: this double drives it
// directly via `classifyResult`. The proof obligation is that, when the
// shipped disk procedure is invoked through the engine:
//
//   COLD  (`classify` returns `unknown`) →
//     1. PERSISTS an `InterestItem` carrying the prompt as `topic` and a
//        non-empty `why`.
//     2. PUSHES that `InterestItem` onto the `interests` bootstrap stack.
//     3. does NOT report the `InterestItem` in `producedNodeIds` (its schema
//        forbids an incoming `produced_by` edge — Q-D.40.2).
//
//   WARM  (`classify` returns `confident`) →
//     4. persists NO `InterestItem` and pushes NOTHING onto `interests`.
//
//   And in both cases the run still closes accepted with the `answer` output.
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
  late _InterestCapturingMemory memory;
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _InterestCapturingMemory();
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

  /// Seeds the WARM path: the prompt classifies confidently against a known
  /// centroid (so no interest is pushed), and recall surfaces one text-bearing
  /// node.
  void seedWarmRecall() {
    memory.classifyResult = const ClassificationResult(
      decision: ClassificationDecision.confident,
      bestMatch: 'Conclusion',
      bestSimilarity: 0.92,
      secondSimilarity: 0.18,
    );
    memory.recallResult = RecallResult(
      nodes: <Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000042'),
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'rsync nightly to the NAS'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 2},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 4,
      ),
    );
  }

  group('D.40-1 the cold path records an InterestItem', () {
    test('an InterestItem carries the prompt as topic and a non-empty why',
        () async {
      // Default classifyResult is `unknown` → cold path.
      await runWith('what is a quasar?');

      final interest = memory.persistedOfType('InterestItem').single;
      expect(interest.draft.values['topic'], 'what is a quasar?');
      expect(interest.draft.values['why'], isNotNull);
      expect((interest.draft.values['why'] as String).isNotEmpty, isTrue);
    });

    test('the InterestItem is pushed onto the `interests` stack', () async {
      await runWith('what is a quasar?');

      final interestId = memory.persistedOfType('InterestItem').single.id;
      final entries = await memory.stacks.peek('interests');
      expect(entries.map((e) => e.nodeId), <NodeId>[interestId]);
    });

    test('the InterestItem is not reported as a produced node', () async {
      await runWith('what is a quasar?');

      final interestId = memory.persistedOfType('InterestItem').single.id;
      // No produced_by edge is drawn to the InterestItem (its schema forbids
      // an incoming produced_by edge — Q-D.40.2).
      final producedByInterest = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.to == interestId,
      );
      expect(producedByInterest, isEmpty);
    });
  });

  group('D.40-2 the warm path records no interest', () {
    test('no InterestItem persisted when recall returned nodes', () async {
      seedWarmRecall();

      await runWith('how do I back up?');

      expect(memory.persistedOfType('InterestItem'), isEmpty);
    });

    test('nothing pushed onto `interests` when recall returned nodes',
        () async {
      seedWarmRecall();

      await runWith('how do I back up?');

      final entries = await memory.stacks.peek('interests');
      expect(entries, isEmpty);
    });
  });

  group('D.40-3 the run still succeeds on both paths', () {
    test('cold: accepted outcome with an answer output', () async {
      substrate.answerChunks = <String>['A quasar is a luminous galactic core.'];

      final outcome = await runWith('what is a quasar?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'A quasar is a luminous galactic core.');
    });

    test('warm: accepted outcome with an answer output', () async {
      seedWarmRecall();
      substrate.answerChunks = <String>['Back up by rsyncing nightly.'];

      final outcome = await runWith('how do I back up?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'Back up by rsyncing nightly.');
    });
  });
}

// ── A persist + edge + stack capturing `TomBrainMemoryClient` ────────
//
// Returns a configurable recall result, assigns a fresh id to every persisted
// node and records the (id, draft) pair, records every edge's (from, type, to),
// and models just enough of the store (trails + stacks) for the run recorder's
// writes and the cold-path `interests` push to succeed. Mirrors the D.39
// double, extended so the `interests` stack contents are readable via `peek`.
class _InterestCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every persisted node, in order, with the id the store assigned it.
  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  /// Every edge drawn, in order.
  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  /// Empty by default. Tests seed nodes for the warm path.
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// `unknown` by default — the cold-classification path. Tests set this to
  /// `confident` for the warm path (Q-D.40.1).
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  /// The persisted nodes of a given type, in persist order.
  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

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

// ── An answer-capturing `TomBrainSubstrateClient` ───────────────────
//
// Emits a canned chunked stream that terminates with Completed; the
// concatenation of `answerChunks` is the answer text the body produces.
// Mirrors the D.38 / D.39 double.
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  List<String> answerChunks = <String>['ok'];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
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
