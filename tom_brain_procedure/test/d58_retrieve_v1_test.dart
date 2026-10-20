// retrieve_v1 — the zero-LLM diagnostic retrieval procedure
// (`tom_brain_procedure_specification.md` § 24.9; SC-Q4; I-4).
//
// `mode: retrieval` selects `retrieve_v1`: "pure memory retrieval with no
// synthesis, for diagnostics". The procedure is a thin memory-only read modelled
// on `passthrough_v1`'s shape in the *opposite* direction — it imports the
// memory bridge and nothing from the substrate, issues a single bm25 `mem.recall`
// over the user's text, formats the hits as a plain-text block, and persists
// nothing. Two guarantees are **structural**:
//
//   1. **Zero LLM.** Because the script never imports `substrate_bridge.dart`,
//      the d4rt `SandboxValidator` makes a `sub.*` call impossible (overview
//      principle 7) — the diagnostic read can never reach a model. A source
//      assertion pins the import is absent so a future edit that re-introduces
//      a substrate call trips this test, not production.
//   2. **No embedding callout.** The recall passes `modes: ['bm25']` — pure
//      FTS, no `vector` mode — so memory makes no embedding callout (principle
//      11 honoured in its strongest form). The recording memory captures the
//      `RecallQuery` so the bm25-only / read-only knobs are asserted directly.
//
// This suite drives the *shipped* `scripts/system/retrieve_v1.dart` through the
// engine (the real store + resolver path, mirroring d55), and pins:
//
//   • the recalled context is surfaced under `answer` (formatted) and the raw
//     hits under `nodes`;
//   • exactly one `mem.recall`, bm25-only, `countsAsAccess: false`;
//   • the body persists nothing beyond the recorder's ProcedureRun markers;
//   • the script imports no substrate bridge (the structural zero-LLM guarantee).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

void main() {
  late _RecallMemory memory;
  late _SilentSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _RecallMemory();
    substrate = _SilentSubstrate();
    memoryBridge = MemoryBridge(memory);
    // retrieve_v1 never calls `sub.*` (it imports no substrate bridge), but the
    // engine is still constructed with one. A prompt resolver is wired so the
    // engine bring-up matches d55; it is never exercised by this procedure.
    final prompts = StubPromptResolver(role: 'assistant_to_user');
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: prompts.resolver,
      routeChainOf: prompts.routeChainOf,
    );
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 29, 12, 0, 0),
      );

  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  Future<ProcedureOutcome> retrieve(String text) async {
    final resolver = await systemResolver();
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(
          ProcedureInvocation(
            procedureId: 'retrieve_v1',
            arguments: <String, Object?>{'text': text},
          ),
        )
        .outcome;
  }

  group('d58-1 the diagnostic read surfaces the recalled context', () {
    test('the run is accepted and the answer lists the recalled hits', () async {
      memory.recallResult = _recallWith(<Node>[
        Node(
          id: NodeId.fromString('n_00000000000000000000000061'),
          typeName: 'Conclusion',
          values: const <String, Object?>{
            'statement': 'the NAS lives at 10.0.0.4',
          },
          createdAt: DateTime.utc(2026, 6, 1),
        ),
        Node(
          id: NodeId.fromString('n_00000000000000000000000062'),
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'backups run nightly'},
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      ]);

      final outcome = await retrieve('where is the NAS?');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final answer = outcome.result!.output<String>('answer');
      // No synthesis — the raw hits, verbatim, one line each.
      expect(answer, contains('Retrieved 2 memories for: where is the NAS?'));
      expect(answer, contains('[Conclusion] the NAS lives at 10.0.0.4'));
      expect(answer, contains('[Claim] backups run nightly'));

      // The raw recalled node maps are also surfaced for programmatic callers.
      final nodes = outcome.result!.output<List<Object?>>('nodes');
      expect(nodes, hasLength(2));
    });

    test('an empty recall yields an explicit no-matches answer', () async {
      memory.recallResult = _recallWith(const <Node>[]);

      final outcome = await retrieve('nothing matches this');

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final answer = outcome.result!.output<String>('answer');
      expect(
        answer,
        contains('Retrieved 0 memories for: nothing matches this'),
      );
      expect(answer, contains('(no matches)'));
    });
  });

  group('d58-2 exactly one bm25, read-only recall (no embedding callout)', () {
    test(
      'the single recall is bm25-only and does not count as access',
      () async {
        memory.recallResult = _recallWith(const <Node>[]);

        await retrieve('diagnostic probe');

        // One recall, no second pass.
        expect(memory.recallQueries, hasLength(1));
        final query = memory.recallQueries.single;
        // bm25 only — the `vector` mode (which makes an embedding callout) is
        // deliberately absent, so the read touches no embedding model (SC-Q4).
        expect(query.modes, <RecallMode>{RecallMode.bm25});
        // A diagnostic inspection must not perturb the recency/frequency signal.
        expect(query.countsAsAccess, isFalse);
      },
    );
  });

  group('d58-3 the body persists nothing (no memory writes)', () {
    test(
      'the only persisted nodes are the recorder ProcedureRun markers',
      () async {
        memory.recallResult = _recallWith(const <Node>[]);

        await retrieve('diagnostic probe');

        // The run recorder persists the start + final ProcedureRun markers; the
        // body itself writes no node. Anything other than ProcedureRun would be a
        // body write — the diagnostic read is supposed to be side-effect-free.
        expect(memory.persistedTypeNames.toSet(), <String>{
          procedureRunNodeType,
        });
      },
    );
  });

  group('d58-4 the zero-LLM guarantee is structural (missing import)', () {
    test('the shipped script does not import the substrate bridge', () async {
      final source = File('scripts/system/retrieve_v1.dart').readAsStringSync();

      // The sandbox enforces "no sub.*" by the *absence* of this import — pin it
      // so a future edit that re-adds a substrate call trips here, not
      // production. Match an actual `import …substrate_bridge.dart…` statement,
      // not a mere mention of the file name in a comment.
      final importsSubstrateBridge = RegExp(
        r"^\s*import\s+[^\n]*substrate_bridge\.dart",
        multiLine: true,
      );
      expect(
        importsSubstrateBridge.hasMatch(source),
        isFalse,
        reason:
            'retrieve_v1 must never import the substrate bridge (SC-Q4); '
            'the missing import is the sandbox-enforced zero-LLM guarantee.',
      );
    });
  });
}

RecallResult _recallWith(List<Node> nodes) => RecallResult(
  nodes: nodes,
  report: RecallReport(
    candidatesPerMode: <RecallMode, int>{RecallMode.bm25: nodes.length},
    fusionStrategy: FusionStrategy.rrf,
    diversityStrategy: DiversityStrategy.mmr,
    elapsedMs: 3,
  ),
);

// ── A recall-recording `TomBrainMemory` ─────────────────────────────────
//
// Returns the seeded [recallResult] and captures every [RecallQuery] so the
// bm25-only / read-only assertions hold, while modelling enough of the trail +
// persist surface for the engine's run recorder. Mirrors d55's `_RecorderMemory`
// plus a `recall` that records its query.
class _RecallMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  /// Every persisted node's `typeName`, in persist order.
  final List<String> persistedTypeNames = <String>[];

  /// Every recall query the body issued, in order.
  final List<RecallQuery> recallQueries = <RecallQuery>[];

  /// The canned recall result. Tests seed it per scenario.
  RecallResult recallResult = _recallWith(const <Node>[]);

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
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
    persistedTypeNames.add(draft.typeName);
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

// ── A never-called `TomBrainSubstrateClient` ────────────────────────────
//
// retrieve_v1 imports no substrate bridge, so `completeStream` is never reached;
// it throws if it ever is, turning an accidental substrate call into a loud test
// failure rather than a silent pass. `embed` returns a trivial vector for any
// incidental engine bring-up need.
class _SilentSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmEvent> completeStream(LlmCall call) => throw StateError(
    'retrieve_v1 must issue no substrate completion (SC-Q4)',
  );

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
