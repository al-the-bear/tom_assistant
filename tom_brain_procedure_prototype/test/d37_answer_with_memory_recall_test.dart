// D.37 — `answer_with_memory_v1` step 1 (recall) acceptance suite.
//
// Plan step D.37 (verbatim): "Step 1 — recall: `recall(text:
// access.envelope.text, modes: {bm25, vector}, k: 8)`." This is the first
// body step of `answer_with_memory_v1`: the no-op stub body (D.8/D.36) is
// replaced by a real `mem.recall(...)` call over the inbound prompt.
//
// The proof obligation is that, when the shipped disk procedure is invoked
// through the engine with a `text` input, the body:
//
//   1. READS THE INPUT — `inputs.get('text')` resolves through the bridged
//      `ProcedureInputs` read surface (D.37) and reaches `recall` as the
//      query text.
//   2. CALLS RECALL with the spec parameters — `modes: {bm25, vector}`,
//      `k: 8` — translated by `MemoryBridge` into a `RecallQuery`.
//   3. SUCCEEDS — the run closes `accepted` and the recall result flows back
//      as the transitional `recall` output (the engine coerces the body's
//      returned `Map`; `ProcedureResult` is not yet bridged — Q-C.38.2).
//
// The body calls `mem.recall` (D.37) and `sub.llm` (D.38); this suite pins
// only the recall behaviour, so the substrate double is a minimal answering
// stub (a terminal Completed stream — the body's `sub.llm` must return for the
// run to close). The memory double captures the constructed `RecallQuery`. The
// procedure is loaded from the real `scripts/system/` store+resolver path so
// the test exercises the shipped artifact, not an inline copy.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _RecallCapturingMemory memory;
  late _InertSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecallCapturingMemory();
    substrate = _InertSubstrate();
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
    final engine = engineFor(<LoadedProcedure>[
      resolver.resolve('answer_with_memory_v1'),
    ]);
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'answer_with_memory_v1',
          arguments: <String, Object?>{'text': text},
        ))
        .outcome;
  }

  group('D.37-1 the body reads its input and calls recall with it', () {
    test('the inbound text reaches recall as the query text', () async {
      await runWith('how do I automate backups?');

      expect(memory.lastRecallQuery, isNotNull);
      expect(memory.lastRecallQuery!.text, 'how do I automate backups?');
    });
  });

  group('D.37-2 recall is called with the § D.37 parameters', () {
    test('modes are exactly {bm25, vector} and k is 8', () async {
      await runWith('any prompt');

      final query = memory.lastRecallQuery!;
      expect(
        query.modes,
        <RecallMode>{RecallMode.bm25, RecallMode.vector},
      );
      expect(query.k, 8);
    });
  });

  group('D.37-3 the run succeeds once recall feeds the answer step', () {
    test('the outcome is accepted and recall was invoked', () async {
      memory.recallResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000042'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'rsync nightly to NAS'},
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

      final outcome = await runWith('how do I automate backups?');

      // Recall ran (its result now feeds the D.38 answer step rather than
      // surfacing directly), and the run closes accepted.
      expect(memory.lastRecallQuery, isNotNull);
      expect(outcome.status, TrailOutcomeStatus.accepted);
    });
  });
}

// ── A minimal answering `TomBrainSubstrateClient` ──────────────────
//
// The body calls `sub.llm` (D.38), so the double must emit a terminal
// Completed stream or the body's `sub.llm` would never return. This suite
// pins recall, not the answer text, so the canned answer is a fixed marker;
// the D.38 suite asserts the assembled prompt and the answer plumbing.
class _InertSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'ok'),
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
// Captures the `RecallQuery` the bridge constructs and returns a canned
// result. Models just enough of the store for the run recorder's writes to
// succeed (trails are entry logs, stacks are push/peek containers, persisted
// nodes are resolvable by id). Mirrors the C.18 / D.8 doubles.
class _RecallCapturingMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  RecallQuery? lastRecallQuery;
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecallQuery = query;
    return recallResult;
  }

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
