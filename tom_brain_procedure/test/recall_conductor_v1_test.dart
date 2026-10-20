// §15 — `recall_conductor_v1`, the agentic pre-answer recall curation loop
// (memory_specification.md § 6.7; memory_optimization_plan.md § 15).
//
// The conductor seeds a recency-boosted, read-only recall, lets the cheap
// local route judge sufficiency and re-search the cold/old/prompt/answer
// corners, then hands back a *small, volume-capped* curated id set with a
// per-node rationale. This suite drives that loop on a stub LLM and pins the
// two §15 proof obligations plus the degrade contract:
//
//   RC-1  The loop runs: round 1 the stub says "not enough, search cold", the
//         conductor issues the read-only re-search; round 2 the stub returns a
//         KEEP block. The curated set is capped at `volumeCap` even though the
//         stub asked to keep more, and the kept ids are the surfaced ones.
//   RC-2  Every recall the conductor issued — the seed and the re-search —
//         ran read-only: `countsAsAccess == false` on every captured query.
//   RC-3  Degrade: when the conductor LLM call fails (local route
//         unavailable), the run still returns a volume-capped curated set
//         drawn from the seed, flagged `degraded: true`.
//
// Harness flavor (b): a fake `TomBrainMemory` capturing every `RecallQuery`
// and a scripted `TomBrainSubstrateClient` whose per-call responses are the
// line directives the conductor prompt is asked to emit. `sub.run` is wired
// through a minimal inline `PromptResolver`; all system procedures are loaded
// so `tool_loop_v1` (which `sub.run` delegates to) resolves.

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
  late _ConductorMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _ConductorMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    // `sub.run` needs a PromptResolver; the conductor prompt resolves to a
    // tool-less `assistant`-route prompt (the stub keys off call order, not
    // the body), and the route chain is empty (the stub ignores it).
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: (String id, Map<String, Object?> inputs) async =>
          const ResolvedPrompt(
            role: 'assistant',
            llmRoute: 'assistant',
            templateBody: 'curate',
            tools: <Object?>[],
            maxToolLoops: 64,
            temperature: null,
            channel: null,
          ),
      routeChainOf: (String _) => const <RouteEntry>[],
    );
  });

  Future<ProcedureOutcome> conduct(Map<String, Object?> args) async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    final engine = ProcedureEngine(
      resolver: ProcedureResolver(resolver.ids.map(resolver.resolve).toList()),
      memory: memory,
      memoryBridge: memoryBridge,
      substrateBridge: substrateBridge,
      now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
    );
    return engine
        .invoke(
          ProcedureInvocation(
            procedureId: 'recall_conductor_v1',
            arguments: args,
          ),
        )
        .outcome;
  }

  group('RC-1 the loop curates a volume-capped set', () {
    test('search → keep, capped at volumeCap, kept ids are surfaced', () async {
      // The seed surfaces five nodes; the stub keeps all five but volumeCap
      // is three, so curation must stop at three.
      final ids = memory.seedIds;
      expect(ids.length, greaterThanOrEqualTo(5));

      substrate.responses
        ..add('SUFFICIENT: no\nSEARCH: cold rare backup facts')
        ..add(_keepBlock(ids));

      final outcome = await conduct(<String, Object?>{
        'text': 'how do I automate backups?',
        'volumeCap': 3,
      });

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final result = outcome.result!;

      final curated = result.output<List>('curatedIds')!.cast<String>();
      expect(curated.length, 3, reason: 'curation is capped at volumeCap');
      for (final id in curated) {
        expect(
          ids,
          contains(id),
          reason: 'only nodes the loop surfaced may be curated',
        );
      }
      // The KEEP path succeeded, so the run did not fall back to the seed.
      expect(result.output<bool>('degraded'), isFalse);
      // The re-search the stub asked for actually ran (round 1 → round 2).
      expect(result.output<int>('searches'), greaterThanOrEqualTo(1));
      // Two conductor turns: round 1 (search) + round 2 (keep).
      expect(substrate.completions, 2);

      final rationale = result.output<Map>('rationale')!;
      for (final id in curated) {
        expect(rationale.containsKey(id), isTrue);
      }

      // The answer layer (§ 16) is handed the curated nodes' full content, not
      // just their ids: one node map per curated id, in curated order, each
      // carrying the `id` the answer's `recordAccess` call later marks.
      final curatedNodes = result.output<List>('curatedNodes')!;
      expect(
        curatedNodes.length,
        curated.length,
        reason: 'one node map per curated id',
      );
      for (var i = 0; i < curated.length; i++) {
        final node = curatedNodes[i] as Map;
        expect(
          node['id'],
          curated[i],
          reason: 'curatedNodes are in curated order and carry their id',
        );
      }
    });
  });

  group('RC-2 every conductor recall is read-only', () {
    test('seed and re-search both run with countsAsAccess:false', () async {
      substrate.responses
        ..add('SUFFICIENT: no\nSEARCH: cold rare backup facts')
        ..add(_keepBlock(memory.seedIds));

      await conduct(<String, Object?>{
        'text': 'how do I automate backups?',
        'volumeCap': 3,
      });

      // At least the seed recall and the cold re-search were issued, and not
      // one of them counted as an access — curation must not warm memory.
      expect(memory.recallQueries.length, greaterThanOrEqualTo(2));
      for (final q in memory.recallQueries) {
        expect(
          q.countsAsAccess,
          isFalse,
          reason: 'conductor recalls are inspections, never uses',
        );
      }
      // The re-search reached the cold corner (recallCold → ranking coldest).
      expect(
        memory.recallQueries.any((q) => q.ranking.name == 'coldest'),
        isTrue,
        reason: 'the SEARCH: cold directive drives a coldest-ranked recall',
      );
      // The seed was recency-boosted.
      expect(
        memory.recallQueries.any((q) => q.ranking.name == 'recencyBoosted'),
        isTrue,
        reason: 'the seed recall is recency-boosted',
      );
    });
  });

  group('RC-3 the loop degrades to the seed when the LLM is unavailable', () {
    test(
      'a failing conductor call returns a capped seed set, degraded:true',
      () async {
        substrate.failAll = true;

        final outcome = await conduct(<String, Object?>{
          'text': 'how do I automate backups?',
          'volumeCap': 2,
        });

        expect(outcome.status, TrailOutcomeStatus.accepted);
        final result = outcome.result!;

        expect(result.output<bool>('degraded'), isTrue);
        final curated = result.output<List>('curatedIds')!.cast<String>();
        // Degrades to the seed, still volume-capped.
        expect(curated.length, 2);
        for (final id in curated) {
          expect(memory.seedIds, contains(id));
        }
        // The seed recall still ran read-only even on the degrade path.
        expect(memory.recallQueries, isNotEmpty);
        for (final q in memory.recallQueries) {
          expect(q.countsAsAccess, isFalse);
        }
      },
    );
  });
}

/// Builds a KEEP directive block over [ids] — one `KEEP: <id> | <rationale>`
/// line per id, the line format the conductor body parses.
String _keepBlock(List<String> ids) {
  final lines = <String>['SUFFICIENT: yes'];
  for (final id in ids) {
    lines.add('KEEP: $id | relevant to the request');
  }
  return lines.join('\n');
}

// ── A recall-capturing `TomBrainMemory` ─────────────────────────────
//
// Returns a fixed five-node seed for every recall (seed + every re-search),
// captures every `RecallQuery` the bridge builds (so the suite can assert the
// read-only invariant and the ranking the loop drove), and models just enough
// of the store for the run recorder's writes to succeed.
class _ConductorMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<RecallQuery> recallQueries = <RecallQuery>[];
  MultiRecallQuery? lastMultiRecallQuery;

  /// The fixed seed corpus — five Claims with stable ids. The body maps each
  /// to its `node.id.value`, so [seedIds] are exactly the id strings the
  /// conductor surfaces and the test's KEEP lines reference.
  final List<Node> _seedNodes = <Node>[
    for (var i = 1; i <= 5; i++)
      Node(
        id: NodeId.fromString('n_0000000000000000000000000$i'),
        typeName: 'Claim',
        values: <String, Object?>{'statement': 'backup fact $i'},
        createdAt: DateTime.utc(2026, 6, 1),
      ),
  ];

  List<String> get seedIds =>
      _seedNodes.map((n) => n.id.value).toList(growable: false);

  RecallResult _seedResult() => RecallResult(
    nodes: _seedNodes,
    report: const RecallReport(
      candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 5},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 3,
    ),
  );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallQueries.add(query);
    return _seedResult();
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return _seedResult();
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async => const ClassificationResult.unknown();

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
  }) async => EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── A scripted `TomBrainSubstrateClient` ────────────────────────────
//
// `completeStream` pops the next canned response (the conductor's line
// directives) per call, counting completions so the suite can assert the
// number of conductor turns. `failAll` flips every completion to a terminal
// failure so the conductor's `sub.run` throws and the body degrades.
class _ScriptedSubstrate implements TomBrainSubstrateClient {
  final List<String> responses = <String>[];
  int completions = 0;
  bool failAll = false;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    if (failAll) {
      return Stream<LlmEvent>.fromIterable(<LlmEvent>[
        const LlmRunFailed(
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
    final text = completions < responses.length
        ? responses[completions]
        : (responses.isEmpty ? '' : responses.last);
    completions++;
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(text),
      const LlmRunCompleted(
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
    vec: Vec(Float32List.fromList(<double>[0.1, 0.2])),
    modelIdentity: const EmbeddingModelIdentity(
      providerId: 'p',
      modelId: 'm',
      dims: 2,
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
