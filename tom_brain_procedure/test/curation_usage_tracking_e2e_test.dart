// §16 — curation wired into the answer flow, end-to-end against the real store
// (memory_optimization_plan.md § 16; memory_specification.md § 6.7).
//
// §16's done-condition, verbatim:
//   "Done when an end-to-end run shows the answer sees only curated nodes and
//    the used nodes' `access_count` rises while merely-surfaced nodes' does
//    not."
//
// This suite proves exactly that against the production `SqliteTomBrainMemory`
// through real D4rt execution of `answer_with_memory_v1`:
//
//   - Four Claims are seeded so the recall conductor surfaces all four.
//   - The scripted substrate plays the conductor's cheap-LLM role (`recaller`)
//     and KEEPs only two of the four; for every other role it returns the
//     answer (and the completion check, returning a non-CONTINUE reply, ends
//     the loop in one pass).
//   - With `curate: true`, the answer prompt is shown ONLY the two curated
//     nodes, so the Conclusion is `derived_from` exactly those two — never the
//     four surfaced — and the body's `recordAccess` bumps exactly those two.
//
// Verify (read back from the real store):
//   * the two curated nodes' `accessCount == 1` — the answer marked them used;
//   * the two merely-surfaced nodes' `accessCount == 0` — surfacing is not use;
//   * the Conclusion has exactly two `derived_from` edges — the answer saw only
//     the curated set.
//
// Like p2_24 these cases open the real on-disk store, which refuses to boot
// without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, Scope, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. The properties under test ride on BM25
/// recall + the store's usage columns, not embedding values, so a deterministic
/// vector is sufficient.
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

  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_curate_');
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

  /// Builds an engine running the shipped `answer_with_memory_v1` over the real
  /// [store] and the [substrate] stub, with the parity prompt resolver (which
  /// resolves the `.curate` conductor prompt to the `recaller` role so the
  /// substrate can detect the curation turn).
  Future<ProcedureEngine> engineFor({
    required SqliteTomBrainMemory store,
    required TomBrainSubstrateClient substrate,
  }) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    final parity = AnswerParityPrompts();
    return ProcedureEngine(
      resolver: ProcedureResolver(system.ids.map(system.resolve).toList()),
      memory: store,
      memoryBridge: MemoryBridge(store),
      substrateBridge: SubstrateBridge(
        substrate,
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
      ),
      now: () => DateTime.utc(2026, 6, 16, 12, 0, 0),
    );
  }

  /// Seeds [count] Claims whose `statement` shares the query keyword so BM25
  /// surfaces them all, returning their ids in seed order.
  Future<List<NodeId>> seedClaims(
    SqliteTomBrainMemory store, {
    required int count,
  }) async {
    final ids = <NodeId>[];
    for (var i = 1; i <= count; i++) {
      final id = await store.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{
            'statement': 'bomber backup automation fact number $i',
          },
          embedding: _v768(seed: i),
        ),
        scope: Scope(producer: 'curate:seed', idempotencyKey: 'seed-$i'),
      );
      ids.add(id);
    }
    return ids;
  }

  group('§16 curation wired into the answer flow (needs vec0)', () {
    test('the answer sees only curated nodes; used nodes\' access_count rises, '
        'merely-surfaced nodes\' does not', () async {
      final store = await openStore();

      // Four candidate Claims; the conductor will surface all four.
      final seeded = await seedClaims(store, count: 4);
      // Every seed starts un-accessed.
      for (final id in seeded) {
        expect((await store.get(id))!.accessCount, 0);
      }

      // The conductor KEEPs only the first two; the other two are surfaced but
      // not curated.
      final kept = <NodeId>[seeded[0], seeded[1]];
      final dropped = <NodeId>[seeded[2], seeded[3]];

      final substrate = _CuratingSubstrate(
        answer: 'Automate the bomber backups via the nightly provisioning job.',
        keepIds: kept.map((n) => n.value).toList(),
      );
      final engine = await engineFor(store: store, substrate: substrate);

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: <String, Object?>{
              'text': 'how do I automate the bomber backups?',
              'curate': true,
            },
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted,
          reason: 'the curated run must land its writes in the real store: '
              '${outcome.error}');
      // The conductor actually ran its cheap-LLM curation turn (recaller role).
      expect(substrate.curationTurns, greaterThanOrEqualTo(1),
          reason: 'the conductor curation prompt must have been dispatched');

      // The answer saw ONLY the curated set: the Conclusion is derived_from
      // exactly the two kept Claims — not the four surfaced.
      final stats = await store.stats();
      expect(stats.edgeCountByType['derived_from'] ?? 0, kept.length,
          reason: 'derived_from edges trace exactly the curated nodes the '
              'answer was shown');

      // The used (curated) nodes were marked: access_count rose to 1.
      for (final id in kept) {
        expect((await store.get(id))!.accessCount, 1,
            reason: 'a curated node the answer cited is marked used');
      }
      // The merely-surfaced (dropped) nodes were never used: access_count
      // stayed at 0.
      for (final id in dropped) {
        expect((await store.get(id))!.accessCount, 0,
            reason: 'surfacing a node is not using it — its counters stay put');
      }
    }, skip: skipNoBinary);

    test('without curate the usage signal is untouched (no recordAccess)',
        () async {
      final store = await openStore();
      final seeded = await seedClaims(store, count: 4);

      final substrate = _CuratingSubstrate(
        answer: 'Automate the bomber backups via the nightly provisioning job.',
        keepIds: const <String>[],
      );
      final engine = await engineFor(store: store, substrate: substrate);

      final outcome = await engine
          .invoke(ProcedureInvocation(
            procedureId: 'answer_with_memory_v1',
            arguments: <String, Object?>{
              'text': 'how do I automate the bomber backups?',
              // curate omitted → default off.
            },
          ))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted, reason: '${outcome.error}');
      // No curation turn ran, and no node's access_count moved.
      expect(substrate.curationTurns, 0);
      for (final id in seeded) {
        expect((await store.get(id))!.accessCount, 0,
            reason: 'the default (non-curated) path never calls recordAccess');
      }
    }, skip: skipNoBinary);
  });
}

// ── A scripted substrate that plays the conductor + the answer ──────────────
//
// `completeStream` branches on the resolved `roleId`: the `recaller` role is
// the recall conductor's curation turn, so it returns a KEEP block over
// [keepIds] (ending the conductor loop in one round); every other role gets the
// fixed [answer] (the answer prompt and the DONE/CONTINUE completion check —
// the answer text is not "CONTINUE", so the loop finishes in one pass).
class _CuratingSubstrate implements TomBrainSubstrateClient {
  _CuratingSubstrate({required this.answer, required this.keepIds});

  final String answer;
  final List<String> keepIds;

  /// How many times the conductor's curation prompt (the `recaller` role) was
  /// dispatched — the proof that curation actually ran.
  int curationTurns = 0;

  String _textFor(LlmCall call) {
    if (call.roleId == 'recaller') {
      curationTurns++;
      final lines = <String>['SUFFICIENT: yes'];
      for (final id in keepIds) {
        lines.add('KEEP: $id | relevant to the request');
      }
      return lines.join('\n');
    }
    return answer;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    final text = _textFor(call);
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: text),
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
