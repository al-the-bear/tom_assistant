// D.42 — `answer_with_memory_v1` consolidated body proof.
//
// Plan step D.42 (verbatim): "Tests: a synthetic inbound prompt produces a
// streamed answer; the post-conditions on memory are satisfied (event +
// conclusion + edges + interest push when applicable)."
//
// D.37–D.41 each pinned one body step in isolation (recall, answer, persist,
// cold-path interest, automation note). D.42 is the *end-to-end* proof: one
// synthetic inbound prompt is driven through the engine against the shipped
// disk procedure, and a *single* run is asserted to satisfy the whole bundle
// of post-conditions the spec promises (§ 11) — proving the steps compose, not
// just that each works alone. Two paths are covered because the post-condition
// set differs by the classification decision (cold path) and the recall
// outcome (citations). The cold path is driven by `classify`, not by an empty
// recall (Q-D.40.1) — this double controls it via `classifyResult`:
//
//   WARM  (`classify` returns `confident`, recall surfaced cited nodes) →
//     • a streamed answer is produced (the multi-chunk substrate stream is
//       drained into the single `answer` output — per-token delivery to a live
//       caller is a Phase E concern, Q-D.38.1);
//     • an `Event` carries the inbound prompt; a `Conclusion` carries the
//       answer;
//     • a `derived_from` edge ties the `Conclusion` to *each* cited node;
//     • a `produced_by` edge ties the `Conclusion` to the authoritative final
//       `ProcedureRun` node (drawn by the recorder at complete());
//     • NO interest push (the prompt classified confidently).
//
//   COLD  (`classify` returns `unknown`, recall surfaced nothing) →
//     • the same streamed-answer + Event + Conclusion + produced_by
//       post-conditions;
//     • NO `derived_from` edges (nothing was cited);
//     • an `InterestItem` is persisted *and* pushed onto the `interests`
//       stack — "interest push when applicable".
//
// The procedure is loaded from the real `scripts/system/` store+resolver path,
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

void main() {
  late _BrainMemory memory;
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _BrainMemory();
    substrate = _AnsweringSubstrate();
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

  // The two recalled node ids the warm path should cite in its derived_from
  // edges.
  final citedA = NodeId.fromString('n_00000000000000000000000042');
  final citedB = NodeId.fromString('n_00000000000000000000000043');

  /// Seeds the WARM path: the prompt classifies confidently (so no interest is
  /// pushed) and recall surfaces two text-bearing cited nodes.
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
          id: citedA,
          typeName: 'Conclusion',
          values: const <String, Object?>{'text': 'rsync nightly to the NAS'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
        Node(
          id: citedB,
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

  /// The authoritative final `ProcedureRun` node for the top-level answer run —
  /// the one the recorder persists with a terminal status (the inflight marker
  /// carries 'running') whose procedureId is the answer procedure. Step-1
  /// recall now fans out through the conductor + four `recall_*` sub-procedures
  /// (Extension-H step #30), each recording its own ProcedureRun, so the answer
  /// run must be matched by procedureId, not just by a terminal status.
  ({NodeId id, NodeDraft draft}) finalRunNode() =>
      memory.persistedOfType('ProcedureRun').firstWhere(
            (p) =>
                p.draft.values['status'] != 'running' &&
                p.draft.values['procedureId'] == 'answer_with_memory_v1',
          );

  group('D.42-1 a synthetic inbound prompt produces a streamed answer', () {
    test('the multi-chunk substrate stream is drained into one answer output',
        () async {
      seedWarmRecall();
      // A genuinely chunked stream: the proof that the body drains the whole
      // stream is that `answer` is the concatenation of every chunk.
      substrate.answerChunks = <String>[
        'Back up by ',
        'rsyncing ',
        'nightly to the NAS.',
      ];

      final outcome = await runWith('how do I automate backups?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'Back up by rsyncing nightly to the NAS.');
      // The reserved body→engine transport channel never surfaces as output.
      expect(outcome.result!.outputs.containsKey(producedNodeIdsOutputKey),
          isFalse);
    });
  });

  group('D.42-2 warm path — event + conclusion + both edge kinds, no interest',
      () {
    test('a single run satisfies the full warm post-condition bundle',
        () async {
      seedWarmRecall();
      substrate.answerChunks = <String>['Back up by rsyncing nightly.'];

      final outcome = await runWith('how do I automate backups?');

      // (a) The run is accepted.
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // (b) An Event carries the inbound prompt.
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'how do I automate backups?');

      // (c) A Conclusion carries the generated answer.
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'Back up by rsyncing nightly.');

      // (d) A derived_from edge ties the Conclusion to each cited node.
      final derivedTargets = memory.recordedEdges
          .where((e) =>
              e.type == EdgeType.derivedFrom && e.from == conclusion.id)
          .map((e) => e.to)
          .toSet();
      expect(derivedTargets, <NodeId>{citedA, citedB});

      // (e) A produced_by edge ties the Conclusion to the final run node.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusion.id,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRunNode().id);

      // (f) No interest push: the prompt was not cold.
      expect(memory.persistedOfType('InterestItem'), isEmpty);
      expect(await memory.stacks.peek('interests'), isEmpty);
    });
  });

  group(
      'D.42-3 cold path — event + conclusion + produced_by + interest push, '
      'no derived_from', () {
    test('a single run satisfies the full cold post-condition bundle',
        () async {
      // Default classify `unknown` → the cold-classification path.
      substrate.answerChunks = <String>['I have no notes on that yet.'];

      final outcome = await runWith('what is a quasar?');

      // (a) The run is accepted.
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // (b) An Event carries the inbound prompt.
      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'what is a quasar?');

      // (c) A Conclusion carries the generated answer.
      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'I have no notes on that yet.');

      // (d) No derived_from edges — nothing was cited.
      final derivedFromConclusion = memory.recordedEdges.where(
        (e) => e.type == EdgeType.derivedFrom && e.from == conclusion.id,
      );
      expect(derivedFromConclusion, isEmpty);

      // (e) A produced_by edge ties the Conclusion to the final run node.
      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusion.id,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRunNode().id);

      // (f) Interest push when applicable: an InterestItem is persisted and
      //     pushed onto the `interests` stack.
      final interest = memory.persistedOfType('InterestItem').single;
      expect(interest.draft.values['topic'], 'what is a quasar?');
      expect((interest.draft.values['why'] as String).isNotEmpty, isTrue);

      final interests = await memory.stacks.peek('interests');
      expect(interests, hasLength(1));
      expect(interests.single.nodeId, interest.id);

      // (g) The InterestItem is NOT a produced result — no produced_by edge
      //     points at it (its bootstrap schema forbids one, Q-D.40.2).
      final producedToInterest = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.to == interest.id,
      );
      expect(producedToInterest, isEmpty);
    });
  });
}

// ── A consolidated stateful `TomBrainMemoryClient` ──────────────────
//
// Combines the D.39 persist/edge-capture double with the D.40/D.41
// recall-configurable + stack-modelling double, so a single run's complete set
// of post-conditions (persisted nodes, edges, and the `interests` stack push)
// can be read off one object. Models just enough of the store for the run
// recorder's trail + stack writes to succeed.
class _BrainMemory implements TomBrainMemory {
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

  /// `unknown` by default — the cold-classification path. The warm helper sets
  /// this to `confident` (Q-D.40.1).
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
// Mirrors the D.39 / D.40 / D.41 double.
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
