// D.8 — `answer_with_memory_v1` artifact acceptance suite.
//
// Plan step D.8 (verbatim): "Add `scripts/system/answer_with_memory_v1.dart`
// as a stub." D.8 shipped the file as a no-op stub; D.37 replaced the no-op
// body with the first real step (`recall`). Under no-backwards-compat this
// suite is migrated in the same change: it no longer asserts the stub shape
// (empty `requires`, a `stub` marker output) but the D.37 contract. The
// recall *behaviour* (query text/modes/k) is pinned by the dedicated D.37
// suite (`d37_answer_with_memory_recall_test.dart`); this suite keeps the
// artifact-level obligations:
//
//   1. ON DISK        — `scripts/system/answer_with_memory_v1.dart` exists
//                       and loads from the real store+resolver path with a
//                       valid `answer_with_memory_v1` v1 header that now
//                       declares
//                       `requires: [recall, embed, classify, llm, persist,
//                       edge, stack.push, note]` (D.37–D.41).
//   2. RUNS ACCEPTED  — invoking it through the engine with a `text` input
//                       resolves an accepted outcome and the recorder writes
//                       the run to `recent_runs`.
//   3. COEXISTS       — the real `scripts/system/` directory ships two
//                       system procedures (`think_v1` + `answer_with_memory_v1`)
//                       and the resolver indexes both without clashing.
//
// The body calls `mem.recall` (D.37) and `sub.llm` (D.38), so the substrate
// double emits a terminal Completed stream (otherwise `sub.llm` never
// returns) and the memory double is the same stateful in-memory client the
// C.38/C.39 engine + C.40 sugar suites use, extended here with a
// recall-capable surface (the recorder still writes a real trail + run
// record around the run).

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
  late _StatefulMemory memory;
  late _InertSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _InertSubstrate();
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

  /// Builds a resolver over the real `scripts/system/` directory — the same
  /// store+resolver path the dispatcher uses, so the test exercises the
  /// shipped artifact rather than an inline copy.
  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  group('D.8-1 the procedure is on disk and loads with a valid header', () {
    test('scripts/system/answer_with_memory_v1.dart exists', () {
      expect(
        File('scripts/system/answer_with_memory_v1.dart').existsSync(),
        isTrue,
        reason: 'D.8 must add the answer_with_memory_v1 system procedure',
      );
    });

    test('the disk procedure parses with the answer_with_memory_v1 v1 header',
        () async {
      final resolver = await systemResolver();
      final loaded = resolver.resolve('answer_with_memory_v1');
      expect(loaded.header.id, 'answer_with_memory_v1');
      expect(loaded.header.version, 1);
      // D.37–D.41 / Extension-H step #30 — step-1 recall runs through the
      // `retrieve_for_prompt_v1` conductor (`runProcedure`); the body still
      // calls the cold-path `embed` + `classify`, `persist`/`edge`, the
      // cold-path `stack.push`, then the repetition `note`. Increment 6
      // (`prompt_configuration.md` §6) migrated the normal path onto `sub.run`:
      // the inline prompt assembly + send/`tool.list` loop are gone — the answer
      // step now names the registered prompt via `run` and delegates the inner
      // tool loop (which still resolves `tool.invoke`) to `tool_loop_v1`. So the
      // header adds `run`. The completion-confirmation contract (agent-loop
      // completion plan § 3, revision 2026-06-14) re-introduces a direct `sub.llm`
      // call: after each accepted draft the body asks the model — in its normal
      // `assistant_to_user` profile, presenting the live todo list — whether it is
      // `DONE` or wants to `CONTINUE`, so `llm` is back in the requires set.
      expect(
          loaded.header.requires,
          <String>[
            'runProcedure',
            'run',
            'llm',
            'embed',
            'classify',
            'persist',
            'edge',
            'stack.push',
            'note',
            'tool.invoke',
          ]);
      // The only declared cap is the wall-clock deadline (§ 5.4): the
      // user-facing answer budget is "virtually unlimited" on every count
      // dimension — the per-run `MemoryWriteGuard` is the non-fatal backstop
      // against a runaway write loop, so reaching it skips+notes rather than
      // failing the run and silencing an already-produced answer.
      expect(loaded.header.budget.wallClockMs, 14400000);
    });
  });

  group('D.8-2 invoking the procedure resolves an accepted outcome', () {
    test('answer_with_memory_v1 runs to an accepted outcome', () async {
      final resolver = await systemResolver();
      final engine = engineFor(resolver.ids.map(resolver.resolve).toList());

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: <String, Object?>{'text': 'how do I back up?'},
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The body recalled through the retrieval conductor (Extension-H step
      // #30) and fed the fused recall into the answer step (D.38), which
      // surfaces the generated answer as the `answer` output.
      expect(memory.lastMultiRecallQuery, isNotNull);
      expect(outcome.result!.outputs.containsKey('answer'), isTrue);

      // The recorder wrote the whole run tree to `recent_runs`: the top-level
      // answer run plus the conductor and its four `recall_*` sub-procedures
      // (Extension-H step #30) — each nested run records its own ProcedureRun
      // (the recorder is the sole writer for every run, top-level and nested,
      // spec § 8). Increment 6 (`prompt_configuration.md` §6) added one more:
      // the answer step's `sub.run` delegates its inner tool loop to a nested
      // `tool_loop_v1` run (§7.2), so the single prompt now produces seven
      // recorded runs.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(7));
    });
  });

  group('D.8-3 the two system stubs coexist in the shipped directory', () {
    test('the resolver indexes both think_v1 and answer_with_memory_v1',
        () async {
      final resolver = await systemResolver();
      expect(resolver.knows('think_v1'), isTrue);
      expect(resolver.knows('answer_with_memory_v1'), isTrue);
      expect(resolver.ids, containsAll(<String>['answer_with_memory_v1', 'think_v1']));
    });
  });
}

// ── A minimal answering `TomBrainSubstrateClient` ──────────────────
//
// The body calls `sub.llm` (D.38), so the double emits a terminal Completed
// stream — otherwise the body's `sub.llm` would never return and the run
// would not close. This artifact-acceptance suite only checks the run closes
// accepted with an `answer` output, so the canned answer is a fixed marker.
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

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read back:
// trails are ordered entry logs, stacks are push/peek/remove containers,
// persisted nodes are resolvable by id. Copied from the C.40 sugar suite;
// unimplemented members fall through to `noSuchMethod`.
class _StatefulMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// The query the most recent `recall` was called with (D.37).
  RecallQuery? lastRecallQuery;

  /// The query the most recent `recallMulti` was called with — the conductor
  /// path now reaches the store through `recallMulti`, not `recall`.
  MultiRecallQuery? lastMultiRecallQuery;

  /// The canned result `recall` returns — an empty result by default.
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
  /// fires; this artifact suite only checks the run closes accepted, so the
  /// default is left as-is.
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
