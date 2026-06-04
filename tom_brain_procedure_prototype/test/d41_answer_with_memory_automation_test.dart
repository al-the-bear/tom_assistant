// D.41 — `answer_with_memory_v1` step 5 (automation-candidate note)
// acceptance suite.
//
// Plan step D.41 (verbatim): "Emit a `note('automation_candidate', …)` if the
// prompt matches a recent identical-shape prompt (cheap repetition check)."
//
// Step 3 persists every inbound prompt as an immutable `Event` whose `summary`
// is the prompt text, so when the user asks the *same* thing again the
// four-mode recall in step 1 surfaces that prior `Event`. The body reads the
// identical-shape signal off the recall it already ran — no second memory
// query (Q-D.41.1) — and, on a match, emits an `automation_candidate` note on
// the run trail (the wire the dispatcher's harvester keys on, § 5.1 / § 11
// step 5). The proof obligations, when the shipped disk procedure is invoked
// through the engine:
//
//   REPEAT  (recall surfaced a prior `Event` whose `summary` == this prompt) →
//     1. EMITS an `automation_candidate` trail note carrying a non-empty `why`
//        and the prompt as `signature`.
//
//   NO-REPEAT  (recall surfaced no matching `Event`, or nothing at all) →
//     2. emits NO `automation_candidate` note.
//
//   And on the repeat path the run still closes accepted with the `answer`.
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

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _RepeatCapturingMemory memory;
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RepeatCapturingMemory();
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

  /// The `automation_candidate` notes a finished run wrote to its trail.
  Iterable<Map<String, Object?>> automationNotes(ProcedureOutcome outcome) =>
      outcome.entries
          .where((e) =>
              e.kind == TrailEntryKind.note &&
              e.payload['category'] == automationCandidateCategory)
          .map((e) => e.payload['payload'] as Map<String, Object?>);

  /// Seeds the recall double with a prior `Event` carrying [summary] as its
  /// `summary` — the resurfaced earlier turn that makes a prompt a repeat.
  void seedPriorEvent(String summary) {
    // The topic was asked before, so it classifies confidently — the signal
    // under test is repetition, not cold curiosity.
    memory.classifyResult = const ClassificationResult(
      decision: ClassificationDecision.confident,
      bestMatch: 'Event',
      bestSimilarity: 0.95,
      secondSimilarity: 0.10,
    );
    memory.recallResult = RecallResult(
      nodes: <Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000041'),
          typeName: 'Event',
          values: <String, Object?>{'summary': summary},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 1},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 3,
      ),
    );
  }

  /// Seeds recall with one unrelated `Conclusion` (a warm, non-repeat recall).
  void seedUnrelatedRecall() {
    memory.classifyResult = const ClassificationResult(
      decision: ClassificationDecision.confident,
      bestMatch: 'Conclusion',
      bestSimilarity: 0.90,
      secondSimilarity: 0.20,
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

  group('D.41-1 the repeat path emits an automation-candidate note', () {
    test('a single automation_candidate note is written to the trail',
        () async {
      seedPriorEvent('what is a quasar?');

      final outcome = await runWith('what is a quasar?');

      expect(automationNotes(outcome), hasLength(1));
    });

    test('the note carries a non-empty why and the prompt as signature',
        () async {
      seedPriorEvent('what is a quasar?');

      final outcome = await runWith('what is a quasar?');

      final note = automationNotes(outcome).single;
      expect(note['signature'], 'what is a quasar?');
      expect(note['why'], isNotNull);
      expect((note['why'] as String).isNotEmpty, isTrue);
    });
  });

  group('D.41-2 the no-repeat paths emit nothing', () {
    test('a warm recall with no matching Event emits no automation note',
        () async {
      seedUnrelatedRecall();

      final outcome = await runWith('what is a quasar?');

      expect(automationNotes(outcome), isEmpty);
    });

    test('a recalled Event with a different summary is not a repeat', () async {
      seedPriorEvent('how do I back up?');

      final outcome = await runWith('what is a quasar?');

      expect(automationNotes(outcome), isEmpty);
    });

    test('an empty (cold) recall emits no automation note', () async {
      // Default classify `unknown` → the cold path (D.40); recall is empty so
      // there is no prior Event → not a repeat.
      final outcome = await runWith('what is a quasar?');

      expect(automationNotes(outcome), isEmpty);
    });
  });

  group('D.41-3 the run still succeeds on the repeat path', () {
    test('repeat: accepted outcome with an answer output', () async {
      seedPriorEvent('what is a quasar?');
      substrate.answerChunks = <String>['A quasar is a luminous galactic core.'];

      final outcome = await runWith('what is a quasar?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'),
          'A quasar is a luminous galactic core.');
    });
  });
}

// ── A recall + persist + edge + stack capturing `TomBrainMemoryClient` ──
//
// Returns a configurable recall result, assigns a fresh id to every persisted
// node, records every edge, and models just enough of the store (trails +
// stacks) for the run recorder's writes and the cold-path push to succeed.
// Mirrors the D.40 double.
class _RepeatCapturingMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  final List<({NodeId from, EdgeType type, NodeId to})> recordedEdges =
      <({NodeId from, EdgeType type, NodeId to})>[];

  /// Empty by default. Tests seed nodes for the warm/repeat paths.
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  /// `unknown` by default — the cold-classification path. Tests with a known
  /// topic set this to `confident` (Q-D.40.1). The repetition signal under
  /// test here (D.41) is independent of the classification decision.
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

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
// Mirrors the D.39 / D.40 double.
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
