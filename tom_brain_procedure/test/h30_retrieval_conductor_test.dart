// H.30 — `retrieve_for_prompt_v1` conductor + the four `recall_*`
// sub-procedures (plan step #30; spec § 23.2).
//
// The conductor orchestrates retrieval: a cheap non-LLM pass always, an
// LLM pass within budget, then a fused `memory.recall.multi` over every
// seed. This suite pins the four Test-clause obligations of plan step #30:
//
//   1. PE-6 — with the substrate stubbed to fail (no LLM seed survives),
//      the conductor still returns a fused non-LLM result. The cheap pass
//      and the classify-driven semantic cheap path do not depend on the
//      completion stream, so the fused recall still runs.
//   2. HyDE embeds *answers*, not questions — `recall_hyde_v1` runs
//      `recall_planner` → `hypothesis_writer` and embeds the hypothetical
//      answers (whose embeddings seed vector recall), never the questions.
//   3. The semantic cheap path seeds from the nearest Concepts —
//      `recall_semantic_v1`'s `classify(target: concept)` confident branch
//      produces a symbolic seed referencing the classified Concept name
//      (Q-H.30.1: a name→symbolic seed, since the cheap path cannot resolve
//      a Concept name to a NodeId for a graph walk).
//   4. PE-4 — the conductor and each sub-procedure are recorded as their
//      own `ProcedureRun` (a node persisted per run), so a retrieval is
//      replayable on the trail.
//
// The procedures are loaded from the real `scripts/system/` store+resolver
// path so the suite exercises the shipped artifacts, not inline copies.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        MultiRecallQuery,
        NodeId,
        RecallMode,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late _RetrievalMemory memory;
  late _RoleSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RetrievalMemory();
    substrate = _RoleSubstrate();
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

  // The conductor dispatches the four `recall_*` sub-procedures through
  // `runProcedure`, so the engine must resolve all five retrieval
  // procedures from the shipped store.
  Future<ProcedureEngine> retrievalEngine() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return engineFor(<LoadedProcedure>[
      resolver.resolve('retrieve_for_prompt_v1'),
      resolver.resolve('recall_hyde_v1'),
      resolver.resolve('recall_lexical_v1'),
      resolver.resolve('recall_semantic_v1'),
      resolver.resolve('recall_symbolic_v1'),
    ]);
  }

  Future<ProcedureOutcome> retrieve(String text) async {
    final engine = await retrievalEngine();
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'retrieve_for_prompt_v1',
          arguments: <String, Object?>{'text': text},
        ))
        .outcome;
  }

  group('H.30-1 PE-6 — the conductor degrades to a fused non-LLM result',
      () {
    test('a failing substrate still yields a fused recall over cheap seeds',
        () async {
      substrate.failAll = true;

      final outcome = await retrieve('how do I automate backups?');

      // The run still closes accepted — an environmental LLM failure does
      // not fail retrieval.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The fused `memory.recall.multi` ran over the surviving non-LLM
      // seeds (the cheap prompt seeds + the classify-driven semantic seed +
      // the symbolic seeds).
      expect(memory.lastMultiRecallQuery, isNotNull);
      expect(memory.lastMultiRecallQuery!.seeds, isNotEmpty);
    });
  });

  group('H.30-2 HyDE embeds answers, not questions', () {
    test('the hypothetical answers are embedded; the questions are not',
        () async {
      await retrieve('how do I automate backups?');

      // `recall_hyde_v1` ran `recall_planner` → `hypothesis_writer` →
      // embedded the answers.
      expect(substrate.embeddedTexts, contains('ans1'));
      expect(substrate.embeddedTexts, contains('ans2'));
      // The clarifying questions are never embedded — only the answers
      // seed vector recall (HyDE).
      expect(substrate.embeddedTexts, isNot(contains('q1')));
      expect(substrate.embeddedTexts, isNot(contains('q2')));
    });
  });

  group('H.30-3 the semantic cheap path seeds from the nearest Concepts',
      () {
    test('a confident classify produces a symbolic seed on the Concept name',
        () async {
      memory.classifyResult = const ClassificationResult(
        decision: ClassificationDecision.confident,
        bestMatch: 'BackupConcept',
        bestSimilarity: 0.91,
        secondSimilarity: 0.40,
      );

      await retrieve('how do I automate backups?');

      final seeds = memory.lastMultiRecallQuery!.seeds;
      final conceptSeeds = seeds.where(
        (s) =>
            s.mode == RecallMode.symbolic &&
            (s.filter?.attributes
                    .any((a) => a.value == 'BackupConcept') ??
                false),
      );
      expect(conceptSeeds, isNotEmpty,
          reason: 'the confident concept classification should seed a '
              'symbolic recall on the Concept name');
    });
  });

  group('H.30-4 PE-4 — every sub-procedure is recorded as a ProcedureRun',
      () {
    test('the conductor plus four sub-procedures each persist a run node',
        () async {
      await retrieve('how do I automate backups?');

      // One ProcedureRun per run: the conductor and the four `recall_*`
      // sub-procedures it dispatches → at least five distinct run markers.
      expect(memory.procedureRunPersists, greaterThanOrEqualTo(5));
    });
  });

  group('H.30-5 retrievalRole tolerates markdown-fenced JSON', () {
    // A live medium model (gemma-4) wraps structured output in a ```json …
    // ``` fence. `retrievalRole` must strip the fence before `jsonDecode` —
    // exactly as the tool-call path (`_parseJsonTextToolCalls`) already does.
    // Without this, every fenced retrieval-role completion degrades to empty
    // seeds and HyDE / semantic recall silently produces nothing on a live
    // substrate.
    test('a fenced recall_planner completion parses to ok:true', () async {
      substrate.fence = true;
      final out = await substrateBridge.retrievalRole(
        'recall_planner',
        'how do I automate backups?',
      );
      expect(out['ok'], isTrue,
          reason: 'a fenced but well-formed JSON answer must parse, not '
              'degrade');
      final output = out['output'] as Map<String, Object?>;
      expect(output['questions'], equals(<String>['q1', 'q2']));
    });

    test('a fenced category_selector completion parses to ok:true', () async {
      substrate.fence = true;
      final out = await substrateBridge.retrievalRole(
        'category_selector',
        'how do I automate backups?',
      );
      expect(out['ok'], isTrue);
      final output = out['output'] as Map<String, Object?>;
      expect(output['conceptNames'], equals(<String>['BackupConcept']));
    });
  });
}

// ── A retrieval-capturing `TomBrainMemory` ──────────────────────────
//
// Captures the `MultiRecallQuery` the bridge constructs for `recallMulti`,
// returns a canned `RecallResult`, lets the test set the `classify`
// outcome, and counts how many `ProcedureRun` nodes were persisted (PE-4).
// Models just enough of the store for the run recorder's writes to succeed.
class _RetrievalMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  MultiRecallQuery? lastMultiRecallQuery;
  int procedureRunPersists = 0;

  /// The classification the semantic cheap path reads. `unknown` by default
  /// so the LLM `category_selector` branch is the fallback; the cheap-path
  /// test sets a confident result.
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  RecallResult _cannedResult() => RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000042'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'rsync nightly to NAS'},
            createdAt: DateTime.utc(2026, 6, 1),
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 3},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 5,
        ),
        provenance: <RecallProvenanceEntry>[
          RecallProvenanceEntry(
            nodeId: NodeId.fromString('n_00000000000000000000000042'),
            seedIndexes: const <int>[0],
            fusedScore: 0.5,
          ),
        ],
      );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return _cannedResult();
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async => _cannedResult();

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
    if (draft.typeName == procedureRunNodeType) procedureRunPersists++;
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

// ── A role-aware `TomBrainSubstrateClient` ───────────────────────────
//
// `completeStream` emits role-specific structured JSON (the retrieval
// roles' output schemas) so `SubstrateBridge.retrievalRole` parses a typed
// output. `embed` records its text so the suite can prove HyDE embeds
// answers (ans1/ans2), not questions (q1/q2). `failAll` flips every
// completion to a terminal failure to exercise PE-6.
class _RoleSubstrate implements TomBrainSubstrateClient {
  final List<String> embeddedTexts = <String>[];
  bool failAll = false;

  /// When true, every completion is wrapped in a ```json … ``` markdown
  /// fence — the shape a live medium model (gemma) emits for structured
  /// output. `SubstrateBridge.retrievalRole` must tolerate it (the tool-call
  /// path already does).
  bool fence = false;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    if (failAll) {
      return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        const LlmStreamFailed(
          callId: 'c',
          failure: LlmFailure(classCode: 'network', message: 'stubbed'),
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 0,
            tokensOut: 0,
            retries: 0,
            wallClockMs: 1,
          ),
        ),
      ]);
    }
    final payload = _jsonFor(call.roleId);
    final text = fence ? '```json\n$payload\n```' : payload;
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

  static String _jsonFor(String roleId) {
    switch (roleId) {
      case 'recall_planner':
        return '{"questions":["q1","q2"]}';
      case 'hypothesis_writer':
        return '{"answers":["ans1","ans2"]}';
      case 'query_term_writer':
        return '{"query":"backups","synonyms":["rsync"]}';
      case 'category_selector':
        return '{"node_types":["Conclusion"],"edge_types":[],'
            '"concept_names":["BackupConcept"]}';
      default:
        return 'ok';
    }
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    embeddedTexts.add(text);
    return EmbeddingResult(
      vec: Vec(Float32List.fromList(<double>[0.1, 0.2])),
      modelIdentity: const EmbeddingModelIdentity(
        providerId: 'p',
        modelId: 'm',
        dims: 2,
        normalized: true,
      ),
    );
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
