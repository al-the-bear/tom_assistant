// D.38b — `answer_with_memory_v1` local conversation-history injection
// (access spec § 7.2 / § 21.5; hub spec § 11, § 22.3).
//
// Regression suite for the live "doesn't remember my name" defect: the
// substrate call received only the current prompt, so a memoryless model could
// not answer a follow-up that depended on an earlier turn. The fix threads the
// answering session's earlier turns into the procedure as a `priorTurns` input
// (the dispatcher route reads them off `access.history`), and the procedure
// renders them as `User:` / `Assistant:` lines into the assembled prompt ahead
// of the recall block and the live prompt.
//
// What this proves, against the shipped `scripts/system/` artifact:
//
//   1. PRIOR TURNS ARE RENDERED — each `{user, assistant}` turn surfaces in the
//      assembled prompt as a `User:` / `Assistant:` pair, so a follow-up like
//      "what is my name?" can be answered from the threaded history alone.
//   2. ORDER — prior turns precede the live `User prompt:` line.
//   3. COLD FIRST TURN — with no `priorTurns` input the prompt is unchanged
//      (PE-9 regression guard), carrying only the live prompt.
//
// The doubles mirror D.38's recall/substrate stubs; only the invocation
// arguments differ (a `priorTurns` list alongside `text`).

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
  late _AnsweringSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecallCapturingMemory();
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

  Future<ProcedureOutcome> runWith(
    String text, {
    List<Map<String, Object?>>? priorTurns,
  }) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'answer_with_memory_v1',
          arguments: <String, Object?>{
            'text': text,
            'priorTurns': ?priorTurns,
          },
        ))
        .outcome;
  }

  group('D.38b-1 prior turns are rendered into the assembled prompt', () {
    test('a follow-up sees the earlier turn it depends on', () async {
      await runWith(
        'what is my name?',
        priorTurns: <Map<String, Object?>>[
          <String, Object?>{
            'user': 'My name is Alexis',
            'assistant': 'Nice to meet you, Alexis.',
          },
        ],
      );

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      // The earlier user statement and the brain's recorded reply both reach
      // the substrate, so a memoryless model can still answer the follow-up.
      expect(prompt, contains('My name is Alexis'));
      expect(prompt, contains('Nice to meet you, Alexis.'));
      // Rendered with the User:/Assistant: convention (hub § 22.4).
      expect(prompt, contains('User: My name is Alexis'));
      expect(prompt, contains('Assistant: Nice to meet you, Alexis.'));
    });

    test('prior turns precede the live user prompt', () async {
      await runWith(
        'what is my name?',
        priorTurns: <Map<String, Object?>>[
          <String, Object?>{
            'user': 'My name is Alexis',
            'assistant': 'Nice to meet you, Alexis.',
          },
        ],
      );

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(prompt.indexOf('My name is Alexis'),
          lessThan(prompt.indexOf('what is my name?')));
    });
  });

  group('D.38b-2 a cold first turn carries no history (PE-9 guard)', () {
    test('with no priorTurns the prompt holds only the live prompt', () async {
      await runWith('plain first question');

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(prompt, contains('plain first question'));
      expect(prompt, isNot(contains('User:')));
      expect(prompt, isNot(contains('Assistant:')));
    });

    test('an empty priorTurns list is treated as cold', () async {
      await runWith('plain first question',
          priorTurns: const <Map<String, Object?>>[]);

      final prompt = substrate.lastCall!.inputs['prompt']! as String;
      expect(prompt, isNot(contains('User:')));
      expect(prompt, isNot(contains('Assistant:')));
    });
  });
}

// ── An answer-capturing `TomBrainSubstrateClient` ───────────────────
class _AnsweringSubstrate implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<String> answerChunks = <String>['ok'];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
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
// Returns an empty recall (this suite pins history rendering, not recall) and
// models just enough of the store for the run recorder's writes to succeed.
// Mirrors the D.38 double.
class _RecallCapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

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
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

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
