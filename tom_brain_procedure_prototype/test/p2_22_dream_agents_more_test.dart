// P2.22 — the remaining cognitive/dream agents as D4rt scripts, end-to-end
// through the procedure engine against the real memory store.
//
// prototype_implementation_plan_2.md #22:
//   "Cognitive/dream agents — synthesis, inquiry, reconsolidation, pruning,
//    repetition, research. Implement `dream_synthesise_v1`,
//    `dream_inquisitor_v1`, `dream_reconsolidate_v1`, `dream_prune_v1`,
//    `dream_repetition_detect_v1`, and `research_v1` (the latter using web
//    tools + LLM) plus `dream_recentroid_v1` (centroid recomputation via
//    `findUncertain`). Test: one script test each (stub LLM/web), asserting
//    the spec'd memory effect and scope/budget compliance. Verify: each agent
//    runs end-to-end through the engine and leaves the expected memory delta."
//
// ── What this suite proves ──────────────────────────────────────────────
//
// The seven dream scripts are shipped artifacts under `scripts/system/`. This
// suite loads them through the production resolver path (`DiskProcedureStore`
// + `ProcedureResolver.fromStore`) and drives each one through
// `ProcedureEngine.invoke` against a *real* on-disk `SqliteTomBrainMemory`
// (not a fake) and a *stub* substrate (deterministic LLM text, a 768-dim
// embedding, and — for the Researcher — deterministic web search/fetch). The
// store is the seam the cognitive agents actually call, so each case is a
// proof the agent leaves its spec'd memory delta against the production stack.
//
// Each agent's case asserts two things the plan calls for:
//   - the *memory effect* — the nodes/edges/centroid/demotions the agent's
//     spec role (memory § 9) is supposed to leave; and
//   - *scope/budget compliance* — the run is `accepted` (a budget breach
//     closes a run `budgetExceeded`, not `accepted`), and every write lands
//     because the agent's registered `writeScopes` permit exactly it — an
//     out-of-scope write would throw `AgentScopeViolation` and the run would
//     error. The Pruner case additionally registers *no* node write scope,
//     proving it can only demote (memory § 9.5 "a Pruner cannot create new
//     nodes, only demote").
//
// Like p2_15 – p2_21 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, NodeDraft, Scope, Vec, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// The shared salient term every seeded node carries, so BM25 recall surfaces
/// the whole seeded set from a single-term query. Vector mode degrades without
/// a query embedding (the store does not embed the query on behalf of the
/// caller), so recall here rides on BM25 — the query and the seeded text must
/// share this term.
const _salientTerm = 'project';

/// A deterministic 768-dim vector. The agent properties under test ride on
/// BM25 recall and the stub substrate, not on embedding *values*, so a
/// deterministic vector is sufficient. Seeded Claims for the recentroid case
/// all share one vector so the recomputed centroid equals it.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_21.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Builds an Event [NodeDraft]; `summary` is the embedding + FTS source. Every
/// summary carries [_salientTerm] so the dream scripts' BM25 recall surfaces
/// it.
NodeDraft _eventDraft({required String summary, required int seed}) =>
    NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': summary,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// Builds a Claim [NodeDraft]; `statement` is the embedding + FTS source. Every
/// statement carries [_salientTerm]. [seed] picks the embedding vector.
NodeDraft _claimDraft({required String statement, required int seed}) =>
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'statement': statement},
      embedding: _v768(seed: seed),
    );

/// A budget wide enough never to interfere — the per-run *header* budget (the
/// script's own `budget:` block) is what bounds the run.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers a cognitive agent whose id equals [name] (the dream procedures'
/// id equals their agent name) with the given write [scopes].
AgentRegistration _agent(String name, Set<String> scopes) => AgentRegistration(
      agentName: name,
      procedureId: name,
      defaultBudget: _unboundedBudget(),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: scopes,
    );

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_22_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  Future<SqliteTomBrainMemory> openStore() async {
    final store = SqliteTomBrainMemory();
    await store.open(freshConfig());
    addTearDown(store.close);
    return store;
  }

  /// Seeds three episodic Events sharing [_salientTerm], unscoped (the
  /// bootstrap/system write path, not a cognitive-agent write).
  Future<void> seedEvents(SqliteTomBrainMemory store) async {
    const summaries = <String>[
      'The project build was deployed to the bomber server.',
      'The project build was deployed to the bomber server again.',
      'The project roadmap meeting set the quarterly goals.',
    ];
    for (var i = 0; i < summaries.length; i++) {
      await store.persist(
        _eventDraft(summary: summaries[i], seed: 100 + i),
        scope: Scope(producer: 'p2.22:seed', idempotencyKey: 'ev-$i'),
      );
    }
  }

  /// Seeds [count] Claims sharing [_salientTerm], unscoped. Each Claim gets a
  /// distinct seeded vector; the recentroid case does not rely on the stored
  /// vector (recall does not rehydrate it — Q-A.35.1) but on re-embedding the
  /// Claim's text, so the seeded embedding here only has to be a valid 768-dim
  /// vector.
  Future<void> seedClaims(
    SqliteTomBrainMemory store, {
    int count = 3,
  }) async {
    for (var i = 0; i < count; i++) {
      await store.persist(
        _claimDraft(
          statement: 'The project fact number $i is recorded.',
          seed: 200 + i,
        ),
        scope: Scope(producer: 'p2.22:seed', idempotencyKey: 'cl-$i'),
      );
    }
  }

  /// Builds an engine that runs the dream procedure named [agentName] under
  /// that agent identity, wired over the real [store] and the [substrate] stub.
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
    required String agentName,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    return ProcedureEngine(
      resolver:
          ProcedureResolver(<LoadedProcedure>[system.resolve(agentName)]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: agentName),
      substrateBridge: SubstrateBridge(substrate),
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runDream({
    required ProcedureEngine engine,
    required String procedureId,
    Map<String, Object?> arguments = const <String, Object?>{
      'source': _salientTerm,
    },
  }) =>
      engine
          .invoke(ProcedureInvocation(
            procedureId: procedureId,
            arguments: arguments,
          ))
          .outcome;

  group('remaining dream agents through the engine against real memory '
      '(needs vec0)', () {
    test('Synthesiser distils recalled Claims into a Conclusion with '
        'derived_from edges', () async {
      final store = await openStore();
      await seedClaims(store);
      store.registerAgent(_agent('dream_synthesise_v1', <String>{
        AgentRegistration.nodeScope('Conclusion'),
        AgentRegistration.edgeScope('derived_from'),
      }));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(
              llmText: 'The project is consistently deployed to bomber.'),
          agentName: 'dream_synthesise_v1',
        ),
        procedureId: 'dream_synthesise_v1',
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final stats = await store.stats();
      expect(stats.nodeCountByType['Conclusion'] ?? 0, greaterThan(0),
          reason: 'a synthesised Conclusion node was persisted');
      expect(stats.edgeCountByType['derived_from'] ?? 0, greaterThan(0),
          reason: 'the Conclusion is tied to its source Claims');
    });

    test('Inquisitor raises Question nodes and pushes them onto '
        'questions_open', () async {
      final store = await openStore();
      await seedClaims(store);
      store.registerAgent(_agent('dream_inquisitor_v1', <String>{
        AgentRegistration.nodeScope('Question'),
        AgentRegistration.stackScope('questions_open'),
      }));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(
              llmText: 'What does the project deployment depend on?'),
          agentName: 'dream_inquisitor_v1',
        ),
        procedureId: 'dream_inquisitor_v1',
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final stats = await store.stats();
      expect(stats.nodeCountByType['Question'] ?? 0, greaterThan(0),
          reason: 'an open Question was persisted');

      final pushed = await store.stacks.peek('questions_open', k: 16);
      expect(pushed, isNotEmpty,
          reason: 'the Question was pushed onto questions_open');
    });

    test('Reconsolidator records a Contradiction and demotes the superseded '
        'Claim', () async {
      final store = await openStore();
      await seedClaims(store);
      final before = await store.stats();
      final claimsBefore = before.nodeCountByType['Claim'] ?? 0;
      expect(claimsBefore, greaterThan(1));

      store.registerAgent(_agent('dream_reconsolidate_v1', <String>{
        AgentRegistration.nodeScope('Contradiction'),
        AgentRegistration.edgeScope('contradicts'),
      }));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(
              llmText: 'The two project facts conflict on the deploy target.'),
          agentName: 'dream_reconsolidate_v1',
        ),
        procedureId: 'dream_reconsolidate_v1',
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final after = await store.stats();
      expect(after.nodeCountByType['Contradiction'] ?? 0, greaterThan(0),
          reason: 'a Contradiction node summarises the conflict');
      expect(after.edgeCountByType['contradicts'] ?? 0, greaterThan(0),
          reason: 'the Contradiction is tied to the conflicting Claims');
      expect(after.nodeCountByType['Claim'] ?? 0, lessThan(claimsBefore),
          reason: 'the superseded Claim was demoted (no longer active)');
    });

    test('Pruner can only demote — it carries no node write scope and reduces '
        'the active Claim count', () async {
      final store = await openStore();
      await seedClaims(store);
      final before = await store.stats();
      final claimsBefore = before.nodeCountByType['Claim'] ?? 0;
      expect(claimsBefore, greaterThan(0));

      // No node/edge/stack write scope: any creation throws
      // AgentScopeViolation. Demotion is the agent's only permitted mutation
      // (memory § 9.5).
      store.registerAgent(_agent('dream_prune_v1', const <String>{}));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(llmText: 'prune: this project fact is '
              'redundant'),
          agentName: 'dream_prune_v1',
        ),
        procedureId: 'dream_prune_v1',
      );

      expect(outcome.status, TrailOutcomeStatus.accepted,
          reason: 'the Pruner only demotes — no out-of-scope write occurs');
      final after = await store.stats();
      expect(after.nodeCountByType['Claim'] ?? 0, lessThan(claimsBefore),
          reason: 'the Pruner demoted at least one redundant Claim');
    });

    test('Repetition detector records a Pattern and an AutomationIdea pushed '
        'onto automation_ideas', () async {
      final store = await openStore();
      await seedEvents(store);
      store.registerAgent(_agent('dream_repetition_detect_v1', <String>{
        AgentRegistration.nodeScope('Pattern'),
        AgentRegistration.nodeScope('AutomationIdea'),
        AgentRegistration.stackScope('automation_ideas'),
      }));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(
              llmText: 'The project build-and-deploy step repeats.'),
          agentName: 'dream_repetition_detect_v1',
        ),
        procedureId: 'dream_repetition_detect_v1',
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final stats = await store.stats();
      expect(stats.nodeCountByType['Pattern'] ?? 0, greaterThan(0),
          reason: 'a recurring Pattern was recorded');
      expect(stats.nodeCountByType['AutomationIdea'] ?? 0, greaterThan(0),
          reason: 'a candidate AutomationIdea was recorded');

      final pushed = await store.stacks.peek('automation_ideas', k: 16);
      expect(pushed, isNotEmpty,
          reason: 'the AutomationIdea was pushed onto automation_ideas');
    });

    test('Researcher turns a web search + fetch into a Source and a Claim '
        'with an evidence_for edge', () async {
      final store = await openStore();
      store.registerAgent(_agent('research_v1', <String>{
        AgentRegistration.nodeScope('Source'),
        AgentRegistration.nodeScope('Claim'),
        AgentRegistration.edgeScope('evidence_for'),
      }));

      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: _AgentSubstrate(
            llmText: 'The project deploys to bomber via vLLM.',
            searchHits: <SearchHit>[
              SearchHit(
                title: 'Project deployment notes',
                url: Uri.parse('https://example.com/project'),
                snippet: 'How the project deploys.',
                rank: 1,
              ),
            ],
            fetchText: 'The project deploys to bomber nightly.',
          ),
          agentName: 'research_v1',
        ),
        procedureId: 'research_v1',
        arguments: const <String, Object?>{'source': 'project deployment'},
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final stats = await store.stats();
      expect(stats.nodeCountByType['Source'] ?? 0, greaterThan(0),
          reason: 'the fetched page became a Source node');
      expect(stats.nodeCountByType['Claim'] ?? 0, greaterThan(0),
          reason: 'the researched fact became a Claim node');
      expect(stats.edgeCountByType['evidence_for'] ?? 0, greaterThan(0),
          reason: 'the Source is evidence for the Claim');
    });

    test('Recentroid recomputes the Claim centroid so classify resolves to '
        'Claim', () async {
      final store = await openStore();
      // The agent recomputes the Claim centroid by re-embedding each recalled
      // member's text (recall does not rehydrate stored vectors — Q-A.35.1).
      // All eight seeded Claims share the same-length statement, so the stub
      // substrate (which embeds by text length) re-embeds them to one vector;
      // the recomputed centroid equals that vector. Seed enough Claims to clear
      // the classifier's cold-start gate (spec § 7.1: a centroid is not served
      // until its example count reaches `coldStartMinExamples`, default 8) —
      // `updateCentroid` derives the centroid's example count from the live
      // Claim count, so fewer than the gate would leave the recomputed centroid
      // untrusted and classify `unknown`.
      await seedClaims(store, count: 8);
      store.registerAgent(_agent('dream_recentroid_v1', const <String>{}));

      final substrate = _AgentSubstrate(llmText: 'classified');
      final outcome = await runDream(
        engine: await engineFor(
          store: store,
          substrate: substrate,
          agentName: 'dream_recentroid_v1',
        ),
        procedureId: 'dream_recentroid_v1',
        arguments: const <String, Object?>{
          'source': _salientTerm,
          'forKey': 'Claim',
        },
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);

      // The memory delta: a Claim centroid now exists, equal to the members'
      // re-embedding. Classifying that same vector (the substrate's embedding
      // of a member's statement) resolves to Claim; cold-start would return
      // `unknown`.
      final memberVec =
          (await substrate.embed('The project fact number 0 is recorded.')).vec;
      final result = await store.classify(memberVec);
      expect(result.bestMatch, 'Claim',
          reason: 'the recomputed centroid makes a member vector classify as '
              'Claim');
    });
  }, skip: skipNoBinary);
}

// ── A deterministic dream/research substrate stub ───────────────────────
//
// Drives every dream script: each `sub.llm(...)` returns [llmText]; `embed`
// returns a 768-dim vector so persisted nodes carry an accepted dimension; the
// Researcher's `search` returns [searchHits] and `fetch` returns a text body
// of [fetchText]. Everything else routes through `noSuchMethod` (unused by the
// scripts under test).
class _AgentSubstrate implements TomBrainSubstrateClient {
  _AgentSubstrate({
    required this.llmText,
    this.searchHits = const <SearchHit>[],
    this.fetchText = '',
  });

  /// The single completion every `sub.llm(...)` returns.
  final String llmText;

  /// Hits `sub.search(...)` returns (Researcher only).
  final List<SearchHit> searchHits;

  /// The text body `sub.fetch(...)` returns (Researcher only).
  final String fetchText;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: llmText),
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
        vec: _v768(seed: text.length),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'nomic-embed-text',
          dims: _bootstrapDims,
          normalized: true,
        ),
      );

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async =>
      WebSearchResult(provider: 'stub', query: query, hits: searchHits);

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async =>
      WebFetchResult(
        url: url,
        status: 200,
        contentType: 'text/html',
        text: fetchText,
        contentBytes: fetchText.length,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
