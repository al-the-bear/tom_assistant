// P2.21 — cognitive/dream agents as D4rt scripts (extraction + connection),
// end-to-end through the procedure engine against the real memory store.
//
// prototype_implementation_plan_2.md #21:
//   "Cognitive/dream agents as D4rt scripts — extraction + connection.
//    Implement `dream_extract_v1` (Extractor) and `dream_connect_v1`
//    (Connector) as D4rt procedure scripts over the bridged primitive API,
//    using the substrate LLM for extraction/linking. Test: run each script
//    through the procedure engine against the real memory + a stub LLM;
//    assert nodes/edges written within scope and budget. Verify: running
//    Extractor over a seeded trail produces Claim nodes; Connector adds
//    `derived_from`/`mentions` edges."
//
// ── What this suite proves ──────────────────────────────────────────────
//
// The two dream scripts are shipped artifacts under `scripts/system/`. This
// suite loads them through the production resolver path
// (`DiskProcedureStore` + `ProcedureResolver.fromStore`) and drives each one
// through `ProcedureEngine.invoke` against a *real* on-disk
// `SqliteTomBrainMemory` (not a fake) and a *stub* substrate (deterministic
// extraction text and link verdict, plus a 768-dim embedding). The store is
// the seam the cognitive agents actually call, so this is the first proof the
// dreaming pipeline runs against the production memory stack.
//
//   Extractor (the Verify) — over a seeded episodic trail, one atomic `Claim`
//     is persisted per recalled `Event`. The run is accepted (so it stayed
//     within its declared header budget), the returned `claimIds` are
//     non-empty, and the real store reports the Claim rows.
//   Connector (the Verify) — over the Claims the Extractor produced (and the
//     Events they came from), `derived_from` edges tie affirmed Claims back to
//     their Events and `mentions` edges tie consecutive Claims together. Both
//     edge kinds appear in the real store's edge counts.
//   Within scope — the engine binds each agent's identity onto the memory
//     bridge (#20), so every write the body issues carries it and the store's
//     `AgentRegistry` confines the run. An agent registered *without* the
//     `node:Claim` write scope has its Claim write refused with
//     `AgentScopeViolation`: the run errors and no Claim row is written.
//
// Like p2_15 – p2_20 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

// @Timeout — heavy end-to-end d4rt integration test (real store / vec0 / full
// procedure). Under the default parallel runner (one isolate per core) the box
// is oversubscribed and this test can exceed the 30s package:test default from
// CPU starvation alone; it passes in isolation. The generous ceiling removes the
// false TimeoutException and only ever bites a genuine hang.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, NodeDraft, Scope, Vec, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// The shared salient term every seeded Event summary (and every extracted
/// Claim) carries, so BM25 recall surfaces the whole seeded trail from a
/// single-term query. Vector mode degrades without a query embedding (the
/// store does not embed the query on behalf of the caller), so recall here
/// rides on BM25 — the query and the seeded text must share this term.
const _salientTerm = 'project';

/// A deterministic 768-dim vector. The dream-agent properties under test
/// (extraction, linking, scope) ride on BM25 recall and the stub substrate,
/// not on embedding *values*, so a deterministic vector is sufficient.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_20.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
      '${dir.path}${Platform.pathSeparator}tom_binaries'
      '${Platform.pathSeparator}sqlite_vec',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Builds an Event [NodeDraft] (requires an embedding; `summary` is the
/// embedding + FTS source). Every summary carries [_salientTerm] so the
/// dream scripts' BM25 recall surfaces it.
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

/// A budget that permits every store-side write — the per-run *header* budget
/// (the procedure script's own `budget:` block) is what bounds the run; this
/// agent budget only has to be wide enough not to interfere.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers the Extractor agent with the given write [scopes]. The happy
/// path passes `{node:Claim}`; the scope-enforcement case passes a deliberately
/// wrong scope so the Claim write is refused.
AgentRegistration _extractorAgent(Set<String> scopes) => AgentRegistration(
  agentName: 'dream_extract_v1',
  procedureId: 'dream_extract_v1',
  defaultBudget: _unboundedBudget(),
  readScopes: const <String>{AgentRegistration.globalWildcard},
  writeScopes: scopes,
);

/// Registers the Connector agent. It draws only `derived_from` and `mentions`
/// edges, so those two edge scopes are its whole write surface.
AgentRegistration _connectorAgent() => AgentRegistration(
  agentName: 'dream_connect_v1',
  procedureId: 'dream_connect_v1',
  defaultBudget: _unboundedBudget(),
  readScopes: const <String>{AgentRegistration.globalWildcard},
  writeScopes: <String>{
    AgentRegistration.edgeScope('derived_from'),
    AgentRegistration.edgeScope('mentions'),
  },
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

  /// A fresh real-store config rooted in a unique temp dir, with teardown
  /// registered for the directory.
  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_21_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  /// Opens a fresh real store with teardown registered.
  Future<SqliteTomBrainMemory> openStore() async {
    final store = SqliteTomBrainMemory();
    await store.open(freshConfig());
    addTearDown(store.close);
    return store;
  }

  /// Seeds three episodic Events sharing [_salientTerm], unscoped (no agent),
  /// so they bypass scope enforcement — this is the bootstrap/system write
  /// path, not a cognitive-agent write.
  Future<void> seedTrail(SqliteTomBrainMemory store) async {
    const summaries = <String>[
      'The project build was deployed to the bomber server.',
      'The project backup synced nightly to the NAS device.',
      'The project roadmap meeting set the quarterly goals.',
    ];
    for (var i = 0; i < summaries.length; i++) {
      await store.persist(
        _eventDraft(summary: summaries[i], seed: 100 + i),
        scope: Scope(producer: 'p2.21:seed', idempotencyKey: 'seed-$i'),
      );
    }
  }

  /// Builds an engine that runs the dream procedure named [agentName] (the
  /// dream procedures' id equals their agent name) under that agent identity,
  /// wired over the real [store] and the [substrate] stub. The memory bridge
  /// carries [agentName], so the store's `AgentRegistry` scopes every write the
  /// body issues (#20 / memory § 9).
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
    required String agentName,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    // Each migrated dream agent reaches the substrate through `sub.run`, which
    // delegates the send loop to the shared `tool_loop_v1` script via
    // `runProcedure` and resolves its prompt through the host `PromptResolver`
    // (the [StubPromptResolver], `tools: none` → one send returns the canned
    // text). Both that script and the resolver must be wired in.
    final prompts = StubPromptResolver();
    return ProcedureEngine(
      resolver: ProcedureResolver(<LoadedProcedure>[
        system.resolve(agentName),
        system.resolve('tool_loop_v1'),
      ]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: agentName),
      substrateBridge: SubstrateBridge(
        substrate,
        promptResolver: prompts.resolver,
        routeChainOf: prompts.routeChainOf,
      ),
      now: () => DateTime.utc(2026, 6, 5, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runDream({
    required ProcedureEngine engine,
    required String procedureId,
  }) => engine
      .invoke(
        ProcedureInvocation(
          procedureId: procedureId,
          arguments: <String, Object?>{'source': _salientTerm},
        ),
      )
      .outcome;

  group(
    'dream agents through the engine against real memory (needs vec0)',
    () {
      test('Extractor over a seeded trail produces Claim nodes', () async {
        final store = await openStore();
        await seedTrail(store);
        store.registerAgent(
          _extractorAgent(<String>{AgentRegistration.nodeScope('Claim')}),
        );

        final engine = await engineFor(
          store: store,
          substrate: _DreamSubstrate(
            llmText: 'The project claim was extracted.',
          ),
          agentName: 'dream_extract_v1',
        );
        final outcome = await runDream(
          engine: engine,
          procedureId: 'dream_extract_v1',
        );

        // Accepted ⇒ the run stayed within its declared header budget (a budget
        // breach would close it `budgetExceeded`, not `accepted`) — the "within
        // budget" half of #21.
        expect(outcome.status, TrailOutcomeStatus.accepted);

        // The body returns the ids it persisted as `claimIds`.
        final claimIds = outcome.result!.output<List<Object?>>('claimIds');
        expect(claimIds, isNotNull);
        expect(claimIds, isNotEmpty);

        // The Verify: Claim rows exist in the real store, one per recalled Event.
        final stats = await store.stats();
        expect(stats.nodeCountByType['Claim'] ?? 0, greaterThan(0));
        expect(stats.nodeCountByType['Claim'], claimIds!.length);
      });

      test(
        'Connector adds derived_from and mentions edges over extracted Claims',
        () async {
          final store = await openStore();
          await seedTrail(store);

          // First the Extractor distils the trail into Claims.
          store.registerAgent(
            _extractorAgent(<String>{AgentRegistration.nodeScope('Claim')}),
          );
          final extractOutcome = await runDream(
            engine: await engineFor(
              store: store,
              substrate: _DreamSubstrate(
                llmText: 'The project claim was extracted.',
              ),
              agentName: 'dream_extract_v1',
            ),
            procedureId: 'dream_extract_v1',
          );
          expect(extractOutcome.status, TrailOutcomeStatus.accepted);

          // Then the Connector weaves them into the graph. Its verdict stub affirms
          // every Claim ("yes"), so each links back to the recalled Events.
          store.registerAgent(_connectorAgent());
          final connectOutcome = await runDream(
            engine: await engineFor(
              store: store,
              substrate: _DreamSubstrate(
                llmText: 'yes, it derives from an event.',
              ),
              agentName: 'dream_connect_v1',
            ),
            procedureId: 'dream_connect_v1',
          );

          expect(connectOutcome.status, TrailOutcomeStatus.accepted);
          final edgeIds = connectOutcome.result!.output<List<Object?>>(
            'edgeIds',
          );
          expect(edgeIds, isNotNull);
          expect(edgeIds, isNotEmpty);

          // The Verify: both edge kinds are present in the real store.
          final stats = await store.stats();
          expect(
            stats.edgeCountByType['derived_from'] ?? 0,
            greaterThan(0),
            reason: 'affirmed Claims link back to the Events they derived from',
          );
          expect(
            stats.edgeCountByType['mentions'] ?? 0,
            greaterThan(0),
            reason: 'consecutive Claims mention one another',
          );
        },
      );

      test('an out-of-scope Extractor write is refused with AgentScopeViolation '
          'and writes no Claim', () async {
        final store = await openStore();
        await seedTrail(store);

        // The Extractor is registered with the WRONG write scope (Concept, not
        // Claim): its first `mem.persist('Claim', …)` is rejected by the store's
        // AgentRegistry before any row is written — the "within scope" half.
        store.registerAgent(
          _extractorAgent(<String>{AgentRegistration.nodeScope('Concept')}),
        );

        final outcome = await runDream(
          engine: await engineFor(
            store: store,
            substrate: _DreamSubstrate(
              llmText: 'The project claim was extracted.',
            ),
            agentName: 'dream_extract_v1',
          ),
          procedureId: 'dream_extract_v1',
        );

        // The refusal surfaces as a run error carrying the typed violation.
        expect(outcome.status, isNot(TrailOutcomeStatus.accepted));
        expect(outcome.error, isA<AgentScopeViolation>());

        // A scope-denied write must not create a row.
        final stats = await store.stats();
        expect(
          stats.nodeCountByType['Claim'] ?? 0,
          equals(0),
          reason: 'the Claim write was refused, so no Claim row exists',
        );
      });
    },
    skip: skipNoBinary,
  );
}

// ── A deterministic dream-substrate stub ────────────────────────────────
//
// Drives both dream scripts: the Extractor reads `llmText` as the extracted
// claim statement; the Connector reads it as the link verdict (it affirms when
// the text contains "yes"). `embed` returns a 768-dim vector so the Claim the
// Extractor persists carries a dimension the store accepts. Mirrors the D.42 /
// D.54 substrate double, with the embedding widened to the bootstrap dims.
class _DreamSubstrate implements TomBrainSubstrateClient {
  _DreamSubstrate({required this.llmText});

  /// The single completion every `sub.llm(...)` returns.
  final String llmText;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(llmText),
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
    vec: _v768(seed: text.length),
    modelIdentity: const EmbeddingModelIdentity(
      providerId: 'p',
      modelId: 'nomic-embed-text',
      dims: _bootstrapDims,
      normalized: true,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
