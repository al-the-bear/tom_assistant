// restructure_tree_v1 — the long-running, checkpointed schema re-migration
// agent (memory § 11.2; the monthly dream lane), end-to-end through the
// procedure engine against the real memory store.
//
// dream_subsystem_redesign.tom_brain.md part (a): the monthly lane fires
// `restructure_tree_v1`, but the script did not exist. This suite is the proof
// the shipped script leaves its spec'd memory delta.
//
// ── What this suite proves ──────────────────────────────────────────────
//
// The migration descriptor lives on the `restructure_backlog` bootstrap stack
// (the durable cursor — `MigrationApi` is not bridged into d4rt): each entry's
// `attrs` carry `{targetType, query, fromType?}`. One pass:
//
//   1. recalls the candidates the descriptor's `query` identifies (restricted
//      to `fromType`);
//   2. for each candidate that re-embeds and `classify`s *confidently into the
//      target type*, persists a reclassified node, edges it `derived_from` the
//      original, and demotes the original `migrationArchive` — never deletes
//      (HP6);
//   3. removes a descriptor from the backlog only when a pass reclassifies
//      nothing (its candidate set is exhausted; non-completion is allowed,
//      § 11.4).
//
// The two cases assert exactly those two outcomes against a *real* on-disk
// `SqliteTomBrainMemory`:
//
//   * `reclassifies a confident candidate` — a candidate Claim becomes a new
//     `Insight` node, tied `derived_from` the Claim, and the Claim is demoted
//     (drops from the active count); the descriptor stays on the backlog.
//   * `retires an exhausted descriptor` — a descriptor whose query recalls no
//     migratable candidate reclassifies nothing and is removed from the
//     backlog.
//
// Like p2_15 – p2_22 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

// @Timeout — heavy end-to-end d4rt integration test (real store / vec0 / full
// procedure). Under the default parallel runner (one isolate per core) the box
// is oversubscribed and this test can exceed the 30s package:test default from
// CPU starvation alone; it passes in isolation. The generous ceiling removes the
// false TimeoutException and only ever bites a genuine hang.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, BrainVersion, NodeDraft, NodeId, Scope, Vec,
        WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// The embedding model id the bootstrap types use; the custom `Insight` target
/// type reuses it so its vectors land in the already-installed 768-dim index.
const _modelId = 'nomic-embed-text@v1.5';

/// The salient term every candidate Claim carries so the descriptor's BM25
/// recall surfaces it (vector mode degrades without a caller-supplied query
/// embedding — the store does not embed the query for the caller).
const _salientTerm = 'project';

/// A deterministic 768-dim vector keyed by [seed]. The `_AgentSubstrate` stub
/// embeds a string to `_v768(seed: text.length)`, so a centroid set to
/// `_v768(seed: candidateText.length)` is exactly what a candidate of that
/// length re-embeds to — making the candidate classify confidently into the
/// target type.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_22.
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

/// The custom target type the migration reclassifies *into*. Its single
/// `statement` field is a superset-free match for a Claim's `{statement}`, so
/// the reclassified node validates with the original's values unchanged; it may
/// emit `derived_from` (the provenance edge back to the original) and reuses
/// the bootstrap embedding model so its vectors index alongside the rest.
NodeTypeDecl _insightType() => NodeTypeDecl(
      typeName: 'Insight',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'statement': const FieldSpec(
          name: 'statement',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: _modelId,
        dimensions: _bootstrapDims,
        sourceFields: <String>['statement'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'statement'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: null,
        reinforcementResetsHorizon: true,
        demoteFromIndexes: true,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom, EdgeType.mentions},
      allowedIncoming: const <EdgeType>{EdgeType.derivedFrom, EdgeType.mentions},
    );

/// A Claim draft; `statement` is the embedding + FTS source.
NodeDraft _claimDraft({required String statement, required int seed}) =>
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'statement': statement},
      embedding: _v768(seed: seed),
    );

/// An Insight draft used only to populate the type's active count (so
/// `updateCentroid` derives an example count past the cold-start gate).
NodeDraft _insightDraft({required String statement, required int seed}) =>
    NodeDraft(
      typeName: 'Insight',
      values: <String, Object?>{'statement': statement},
      embedding: _v768(seed: seed),
    );

/// A budget wide enough never to interfere — the script's own `budget:` header
/// is what bounds the run.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers the Restructurer agent with the wildcard write scope (memory
/// § 9.5 / the redesign note: it writes `node:*` reclassified nodes, the
/// `derived_from` provenance edge, and demotes originals).
AgentRegistration _restructurer() => AgentRegistration(
      agentName: 'restructure_tree_v1',
      procedureId: 'restructure_tree_v1',
      defaultBudget: _unboundedBudget(),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: const <String>{AgentRegistration.globalWildcard},
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
    final root = Directory.systemTemp.createTempSync('tbm_restructure_');
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

  /// Builds an engine that runs `restructure_tree_v1` under that agent
  /// identity, over the real [store] and the [substrate] stub.
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    final prompts = StubPromptResolver();
    return ProcedureEngine(
      resolver: ProcedureResolver(<LoadedProcedure>[
        system.resolve('restructure_tree_v1'),
      ]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: 'restructure_tree_v1'),
      substrateBridge: SubstrateBridge(
        substrate,
        promptResolver: prompts.resolver,
        routeChainOf: prompts.routeChainOf,
      ),
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runRestructure(ProcedureEngine engine) => engine
      .invoke(ProcedureInvocation(
        procedureId: 'restructure_tree_v1',
        arguments: const <String, Object?>{},
      ))
      .outcome;

  /// Seeds [count] active `Insight` nodes so `updateCentroid('Insight', …)`
  /// derives an example count that clears the classifier's cold-start gate
  /// (default 8). Returns the first seeded id (used as a descriptor's
  /// entry-node handle).
  Future<NodeId> seedInsights(
    SqliteTomBrainMemory store, {
    int count = 8,
  }) async {
    NodeId? first;
    for (var i = 0; i < count; i++) {
      final id = await store.persist(
        _insightDraft(statement: 'Seeded insight number $i.', seed: 300 + i),
        scope: Scope(producer: 'restructure:seed', idempotencyKey: 'ins-$i'),
      );
      first ??= id;
    }
    return first!;
  }

  group('restructure_tree_v1 through the engine against real memory '
      '(needs vec0)', () {
    test('reclassifies a confident candidate into the target type, edges it '
        'derived_from the original, and demotes the original', () async {
      final store = await openStore();
      store.registerAgent(_restructurer());
      await store.registerNodeType(_insightType());

      // The descriptor's entry-node handle (any existing node id; the script
      // only uses it to retire an exhausted descriptor, which does not happen
      // here). Reuse a seeded Insight id; seeding also clears the cold-start
      // gate for the Insight centroid.
      final descriptorNode = await seedInsights(store);

      // The candidate Claim. `_textOf({statement})` is the statement itself, so
      // the script re-embeds exactly this string; the stub embeds by length.
      const candidateStatement = 'The project insight worth promoting now.';
      await store.persist(
        _claimDraft(statement: candidateStatement, seed: 1),
        scope: Scope(producer: 'restructure:seed', idempotencyKey: 'cand-0'),
      );

      // Set the Insight centroid to the candidate's re-embedding so it
      // classifies confidently into Insight (the only centroid present ⇒ a
      // wide margin). updateCentroid derives the example count from the live
      // Insight count (8), past the cold-start gate.
      await store.updateCentroid(
        'Insight',
        _v768(seed: candidateStatement.length),
      );

      // Push the migration descriptor onto the durable cursor.
      await store.stacks.push(
        'restructure_backlog',
        descriptorNode,
        attrs: const <String, Object?>{
          'targetType': 'Insight',
          'query': _salientTerm,
          'fromType': 'Claim',
        },
      );

      final before = await store.stats();
      final insightsBefore = before.nodeCountByType['Insight'] ?? 0;
      final claimsBefore = before.nodeCountByType['Claim'] ?? 0;
      expect(claimsBefore, 1, reason: 'exactly one candidate Claim seeded');

      final outcome = await runRestructure(
        await engineFor(store: store, substrate: _AgentSubstrate()),
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result?.outputs['reclassified'], 1,
          reason: 'the one confident candidate was reclassified');

      final after = await store.stats();
      expect(after.nodeCountByType['Insight'] ?? 0, insightsBefore + 1,
          reason: 'a reclassified Insight node was persisted');
      expect(after.edgeCountByType['derived_from'] ?? 0, greaterThan(0),
          reason: 'the new Insight is tied derived_from the original Claim');
      expect(after.nodeCountByType['Claim'] ?? 0, lessThan(claimsBefore),
          reason: 'the original Claim was demoted (no longer active) — HP6 '
              'keeps it addressable, just out of default retrieval');

      // The descriptor stays on the backlog: this pass migrated a candidate,
      // so its candidate set may not be exhausted.
      final backlog = await store.stacks.peek('restructure_backlog', k: 16);
      expect(backlog.map((e) => e.nodeId), contains(descriptorNode),
          reason: 'a descriptor that reclassified ≥1 candidate is retained');
    });

    test('retires an exhausted descriptor — a pass that reclassifies nothing '
        'removes it from the backlog', () async {
      final store = await openStore();
      store.registerAgent(_restructurer());
      await store.registerNodeType(_insightType());

      final descriptorNode = await seedInsights(store);

      // A descriptor whose query recalls no migratable candidate. No Claim
      // carries this term, so recall is empty and the pass reclassifies
      // nothing ⇒ the descriptor is exhausted and removed.
      await store.stacks.push(
        'restructure_backlog',
        descriptorNode,
        attrs: const <String, Object?>{
          'targetType': 'Insight',
          'query': 'nonexistentsalientterm',
          'fromType': 'Claim',
        },
      );

      final outcome = await runRestructure(
        await engineFor(store: store, substrate: _AgentSubstrate()),
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result?.outputs['reclassified'], 0,
          reason: 'no candidate matched the descriptor query');

      final backlog = await store.stacks.peek('restructure_backlog', k: 16);
      expect(backlog.map((e) => e.nodeId), isNot(contains(descriptorNode)),
          reason: 'an exhausted descriptor is retired from the backlog');
    });
  }, skip: skipNoBinary);
}

// ── A deterministic embedding substrate stub ────────────────────────────
//
// restructure_tree_v1 is LLM-free: it only calls `sub.embed`. The stub embeds
// a string to a 768-dim vector keyed by the string's length, so a candidate of
// the same length as the one whose embedding seeded the centroid re-embeds to
// that centroid. Everything else routes through `noSuchMethod` (unused here).
class _AgentSubstrate implements TomBrainSubstrateClient {
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
