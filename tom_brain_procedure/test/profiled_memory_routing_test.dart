// Step 6 — `ProfiledMemory` per-profile memory routing
// (`memory_session_profiles.md` § 8, decision D-4 / MSPP-23).
//
// Done-when (plan step 6): "two requests with different memory selectors write
// disjoint nodes; a recall in profile A never sees profile B's nodes."
//
// ── What this proves ────────────────────────────────────────────────────
//
// The load-bearing claim of memory profiles (MSP-1) is that a `memoryProfile`
// selects a *separate database* — not merely a log label. The realised wiring
// (MSPP-23, Option B) puts a [ProfiledMemory] router *in front of* the memory
// transport: the engine resolves a run's client once per run from
// `invocation.memoryProfile`, and each non-default profile is provisioned as its
// own transport (its own in-process store here; its own isolate in production).
//
// This suite drives the real shipped `answer_with_memory_v1` body through the
// engine twice — once under profile `alpha`, once under profile `beta` — with
// the engine's `memoryForProfile` bound to a [ProfiledMemory] whose provision
// callback opens a fresh real `SqliteTomBrainMemory` per profile. It then
// asserts the two runs wrote into *disjoint* stores (each holds exactly its own
// inbound-prompt Event; the boot default store stays empty), and that a BM25
// recall inside profile `alpha` cannot see profile `beta`'s node — the strongest
// possible isolation, because the two databases share no connection at all.
//
// Like p2_24 these cases open the real on-disk store, which refuses to boot
// without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

// @Timeout — two full real-store / vec0 / d4rt runs back to back; the generous
// ceiling removes the false TimeoutException under the oversubscribed parallel
// runner and only ever bites a genuine hang (mirrors p2_24).
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show RecallMode, RecallQuery, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text), so the
/// store's embedding-policy check accepts the persisted Event / Conclusion /
/// InterestItem (mirrors p2_24).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector — the properties under test ride on the
/// *presence* of a dimension-correct embedding, not on its values.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_24.
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

  group('ProfiledMemory routes runs to disjoint per-profile stores (needs '
      'vec0)', () {
    test('two runs under different memory selectors write disjoint nodes; a '
        'recall in profile alpha never sees profile beta\'s node', () async {
      // One shared root: profile-bound configs scope everything under
      // `<root>/profiles/<name>/`, so two profiles over the same root are still
      // physically separate databases (MSP-1).
      final root = Directory.systemTemp.createTempSync('tbm_profiled_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final baseConfig =
          MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);

      // The boot default store — the client every default-profile run reuses.
      // The two profiled runs below must NOT touch it.
      final defaultStore = SqliteTomBrainMemory();
      await defaultStore.open(baseConfig);
      addTearDown(defaultStore.close);

      // Per-profile in-process provision: open a fresh real store per profile,
      // capture it by profile name so the test can inspect each store directly.
      // ProfiledMemory owns each ProvisionedMemory and disposes it on dispose().
      final profileStores = <String, SqliteTomBrainMemory>{};
      Future<ProvisionedMemory> provisionInProcess(MemoryConfig config) async {
        final store = SqliteTomBrainMemory();
        profileStores[config.profile!] = store;
        return MemoryProvisioner(
          MemoryProvisioningConfig.inProcess(
            client: store,
            memoryConfig: config,
          ),
        ).provision();
      }

      final profiled = ProfiledMemory(
        baseConfig: baseConfig,
        defaultClient: defaultStore,
        provision: provisionInProcess,
      );
      addTearDown(profiled.dispose);

      // The full system set: `answer_with_memory_v1` step-1 recall dispatches
      // the `retrieve_for_prompt_v1` conductor and its `recall_*` sub-procedures,
      // so they must all be resolvable (mirrors p2_24).
      final system = await ProcedureResolver.fromStore(
        DiskProcedureStore(systemDir: Directory('scripts/system')),
      );
      final parity = AnswerParityPrompts();
      final engine = ProcedureEngine(
        resolver: ProcedureResolver(
          system.ids.map(system.resolve).toList(),
        ),
        memory: defaultStore,
        memoryBridge: MemoryBridge(defaultStore),
        memoryForProfile: profiled.forProfile,
        substrateBridge: SubstrateBridge(
          _AnswerSubstrate(answer: 'A routed answer.'),
          promptResolver: parity.resolver,
          routeChainOf: parity.routeChainOf,
        ),
        now: () => DateTime.utc(2026, 6, 22, 12, 0, 0),
      );

      // Two prompts that share no salient tokens, so a cross-profile BM25 recall
      // would be unambiguous if isolation leaked.
      const alphaPrompt = 'how do I configure the alpha widget?';
      const betaPrompt = 'what is the beta gadget release schedule?';

      final alphaOutcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: const <String, Object?>{'text': alphaPrompt},
            memoryProfile: 'alpha',
          ))
          .outcome;
      expect(alphaOutcome.status, TrailOutcomeStatus.accepted,
          reason: 'alpha run must persist into its own store: '
              '${alphaOutcome.error}');

      final betaOutcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: const <String, Object?>{'text': betaPrompt},
            memoryProfile: 'beta',
          ))
          .outcome;
      expect(betaOutcome.status, TrailOutcomeStatus.accepted,
          reason: 'beta run must persist into its own store: '
              '${betaOutcome.error}');

      // Both profiles were provisioned as their own transport.
      expect(profileStores.keys, containsAll(<String>['alpha', 'beta']));
      final alphaStore = profileStores['alpha']!;
      final betaStore = profileStores['beta']!;

      // Disjoint writes: each profile store holds exactly its own inbound Event;
      // the default store stayed empty (under the pre-routing behaviour it would
      // hold BOTH Events and the profile stores none).
      final alphaStats = await alphaStore.stats();
      final betaStats = await betaStore.stats();
      final defaultStats = await defaultStore.stats();
      expect(alphaStats.nodeCountByType['Event'], 1,
          reason: 'alpha\'s prompt becomes one Event in alpha\'s store');
      expect(betaStats.nodeCountByType['Event'], 1,
          reason: 'beta\'s prompt becomes one Event in beta\'s store');
      expect(defaultStats.nodeCountByType['Event'] ?? 0, 0,
          reason: 'neither profiled run may write to the default store');

      // A recall inside profile alpha cannot see profile beta's node: BM25 over
      // beta's exact prompt text returns nothing whose summary is beta's prompt.
      final crossRecall = await alphaStore.recall(
        const RecallQuery(modes: {RecallMode.bm25}, text: betaPrompt, k: 20),
      );
      final leaked = crossRecall.nodes
          .where((n) => n.values['summary'] == betaPrompt)
          .toList();
      expect(leaked, isEmpty,
          reason: 'a recall in alpha must never surface beta\'s Event');

      // Sanity: alpha CAN recall its own node (so the empty cross-recall is
      // isolation, not a broken BM25 index).
      final selfRecall = await alphaStore.recall(
        const RecallQuery(modes: {RecallMode.bm25}, text: alphaPrompt, k: 20),
      );
      expect(
        selfRecall.nodes.where((n) => n.values['summary'] == alphaPrompt),
        isNotEmpty,
        reason: 'alpha must recall its own Event from its own store',
      );
    }, skip: skipNoBinary);
  });
}

// ── A deterministic answer-substrate stub (mirrors p2_24) ────────────────
class _AnswerSubstrate implements TomBrainSubstrateClient {
  _AnswerSubstrate({required this.answer});

  final String answer;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: answer),
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
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
