// D.39 — `answer_with_memory_v1` step 3 (persist the exchange) acceptance suite.
//
// Plan step D.39 (verbatim): "Persist the exchange: an `Event` node for the
// inbound prompt; a `Conclusion` node for the answer; a `produced_by` edge to
// the `ProcedureRun`; a `derived_from` edge from the conclusion to each
// recalled node it cited."
//
// The proof obligation is that, when the shipped disk procedure is invoked
// through the engine with a `text` input and a recall double that returns two
// memory nodes, the body:
//
//   1. PERSISTS AN EVENT carrying the inbound prompt and a CONCLUSION carrying
//      the answer.
//   2. DRAWS A `derived_from` EDGE from the Conclusion to every recalled node
//      it cited.
//   3. REPORTS the Conclusion id so the run recorder draws the `produced_by`
//      edge from the Conclusion to the authoritative final `ProcedureRun`
//      node (the body cannot draw it — the run node only exists at
//      `complete()`, after the body returns).
//   4. KEEPS `answer` as the only surfaced output — the reserved
//      `producedNodeIds` channel is consumed and stripped by the engine.
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

void main() {
  late _PersistCapturingMemory memory;
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _PersistCapturingMemory();
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

  // The two recalled node ids the body should cite in its `derived_from` edges.
  final citedA = NodeId.fromString('n_00000000000000000000000042');
  final citedB = NodeId.fromString('n_00000000000000000000000043');

  /// Seeds the recall double with two text-bearing nodes.
  void seedRecall() {
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

  group('D.39-1 the exchange is persisted as an Event + a Conclusion', () {
    test('an Event carries the inbound prompt', () async {
      seedRecall();
      substrate.answerChunks = <String>['Back up by rsyncing nightly.'];

      await runWith('how do I automate backups?');

      final event = memory.persistedOfType('Event').single;
      expect(event.draft.values['summary'], 'how do I automate backups?');
    });

    test('a Conclusion carries the generated answer', () async {
      seedRecall();
      substrate.answerChunks = <String>['Back up by rsyncing nightly.'];

      await runWith('how do I automate backups?');

      final conclusion = memory.persistedOfType('Conclusion').single;
      expect(conclusion.draft.values['statement'],
          'Back up by rsyncing nightly.');
    });
  });

  group('D.39-2 a derived_from edge ties the Conclusion to each recalled node',
      () {
    test('one derived_from edge per cited node, from the Conclusion', () async {
      seedRecall();

      await runWith('how do I automate backups?');

      final conclusionId = memory.persistedOfType('Conclusion').single.id;
      final derivedTargets = memory.recordedEdges
          .where((e) => e.type == EdgeType.derivedFrom && e.from == conclusionId)
          .map((e) => e.to)
          .toSet();

      expect(derivedTargets, <NodeId>{citedA, citedB});
    });

    test('no derived_from edges when recall returned nothing', () async {
      // Default recallResult is empty.
      await runWith('plain question');

      final conclusionId = memory.persistedOfType('Conclusion').single.id;
      final derivedFromConclusion = memory.recordedEdges.where(
        (e) => e.type == EdgeType.derivedFrom && e.from == conclusionId,
      );
      expect(derivedFromConclusion, isEmpty);
    });
  });

  group('D.39-3 a produced_by edge ties the Conclusion to the ProcedureRun',
      () {
    test('the recorder draws produced_by from the Conclusion to the run node',
        () async {
      seedRecall();

      await runWith('how do I automate backups?');

      final conclusionId = memory.persistedOfType('Conclusion').single.id;
      // The authoritative final ProcedureRun node for the top-level answer run
      // is the one persisted with a terminal status (the inflight marker
      // carries status 'running') whose procedureId is the answer procedure —
      // step-1 recall now fans out through the conductor + four `recall_*`
      // sub-procedures (Extension-H step #30), each of which records its own
      // ProcedureRun, so the run must be matched by procedureId, not just by a
      // terminal status.
      final finalRun = memory.persistedOfType('ProcedureRun').firstWhere(
            (p) =>
                p.draft.values['status'] != 'running' &&
                p.draft.values['procedureId'] == 'answer_with_memory_v1',
          );

      final producedBy = memory.recordedEdges.where(
        (e) => e.type == EdgeType.producedBy && e.from == conclusionId,
      );
      expect(producedBy, hasLength(1));
      expect(producedBy.single.to, finalRun.id);
    });
  });

  group('D.39-4 the run succeeds and producedNodeIds is not a surfaced output',
      () {
    test('the outcome is accepted, answer is present, producedNodeIds stripped',
        () async {
      seedRecall();
      substrate.answerChunks = <String>['Back up by ', 'rsyncing nightly.'];

      final outcome = await runWith('how do I automate backups?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'Back up by rsyncing nightly.');
      // The reserved transport key never surfaces as a declared output.
      expect(outcome.result!.outputs.containsKey(producedNodeIdsOutputKey),
          isFalse);
    });
  });
}

// ── A persist + edge capturing `TomBrainMemoryClient` ────────────────
//
// Returns a configurable recall result, assigns a fresh id to every persisted
// node and records the (id, draft) pair, records every edge's (from, type, to),
// and models just enough of the store for the run recorder's trail + stack
// writes to succeed. Extends the C.18 / D.8 / D.37 / D.38 doubles with persist
// and edge capture so the D.39 post-conditions can be asserted.
class _PersistCapturingMemory implements TomBrainMemory {
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
  /// fires; this suite pins the persist + edge post-conditions, not the cold
  /// path, so the default is left as-is and the run still closes accepted.
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
// concatenation of `answerChunks` is the answer text the body persists as the
// Conclusion. Mirrors the D.38 double.
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
