// dream_decay_v1 — the usage-recalibration pass (memory § 9.7, deep lane;
// memory-optimization plan § 13).
//
// The deep-lane Pruner-class agent that turns the read-time decay signal
// (§ 6.6) into persisted demotions. LLM-free: its verdict is pure arithmetic
// over the usage columns (`lastAccessMs` / `accessCount`) against the pass
// clock (`nowMs`) and the per-type half-life + demote knobs supplied as
// inputs. This suite drives the shipped
// `scripts/system/dream_decay_v1.dart` through `ProcedureEngine.invoke`
// against a *real* on-disk `SqliteTomBrainMemory` and a no-op substrate (the
// agent calls no LLM) and asserts:
//
//   - Only cold nodes demote — a node past its per-type half-life, accessed no
//     more than `minAccessCount` times, and older than `coldnessFloorDays` is
//     demoted; a frequently-accessed node and a node still inside its (longer)
//     per-type half-life are both left active.
//   - The floor protects a freshly-accessed store — when `nowMs` is inside
//     `coldnessFloorDays` of every node's last access, nothing is demoted.
//   - The budget is respected — with more eligible cold nodes than
//     `maxPerPass`, exactly `maxPerPass` are demoted (coldest first), the rest
//     left active.
//   - Demotion never deletes (hard principle 6) — a demoted node is gone from
//     default retrieval (`stats`) but still addressable by id.
//
// Like p2_15 – p2_23 these cases open the real on-disk store, which refuses to
// boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, NodeDraft, NodeId, NodeStatus, Scope, Vec,
        WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// One day in milliseconds — the unit the decay arithmetic is in.
const int _msPerDay = 86400000;

/// The shared salient term every seeded summary/statement carries so the
/// agent's BM25 recall surfaces the whole seeded set from a single-term query.
/// Vector mode degrades without a query embedding (the store does not embed the
/// query on the caller's behalf), so recall rides on BM25 — the query and the
/// seeded text must share this term (mirrors p2_21).
const _salientTerm = 'project';

/// A deterministic 768-dim vector; the dream-agent properties under test ride
/// on BM25 recall, not embedding *values*, so a deterministic vector suffices.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_23.
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

/// A budget wide enough never to interfere — the per-run *header* budget bounds
/// the run.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers the decay agent (id `dream_decay_v1`) as a Pruner — read
/// everything, *empty* write scope. Demotion carries no Scope (it mutates
/// lifecycle, not the graph), so the empty write scope is exactly the spec's
/// "only demote" lane (memory § 9.5).
AgentRegistration _decayAgent() => AgentRegistration(
      agentName: 'dream_decay_v1',
      procedureId: 'dream_decay_v1',
      defaultBudget: _unboundedBudget(),
      readScopes: const <String>{AgentRegistration.globalWildcard},
      writeScopes: const <String>{},
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
    final root = Directory.systemTemp.createTempSync('tbm_decay_');
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

  /// Seeds one node of [typeName] carrying [_salientTerm]; unscoped (the
  /// bootstrap/system write path, no agent). Returns its stable node id.
  Future<NodeId> seedNode(
    SqliteTomBrainMemory store, {
    required String typeName,
    required Map<String, Object?> values,
    required String key,
    required int seed,
  }) =>
      store.persist(
        NodeDraft(
          typeName: typeName,
          values: values,
          embedding: _v768(seed: seed),
        ),
        scope: Scope(producer: 'decay:seed', idempotencyKey: key),
      );

  Future<NodeId> seedEvent(
    SqliteTomBrainMemory store, {
    required String summary,
    required String key,
    required int seed,
  }) =>
      seedNode(
        store,
        typeName: 'Event',
        values: <String, Object?>{
          'summary': summary,
          'payload': const <String, Object?>{},
          'occurred_at': '2026-01-01T10:00:00.000Z',
        },
        key: key,
        seed: seed,
      );

  Future<NodeId> seedClaim(
    SqliteTomBrainMemory store, {
    required String statement,
    required String key,
    required int seed,
  }) =>
      seedNode(
        store,
        typeName: 'Claim',
        values: <String, Object?>{'statement': statement},
        key: key,
        seed: seed,
      );

  /// The largest `last_access_ms` across [ids] — the base instant a pass clock
  /// is offset from, so every seeded node is at least the offset old (the
  /// store stamps last access at its own wall clock, which is what the decay
  /// arithmetic reads, not the engine clock).
  Future<int> latestAccessMs(
    SqliteTomBrainMemory store,
    List<NodeId> ids,
  ) async {
    var maxMs = 0;
    for (final id in ids) {
      final node = await store.get(id);
      final ms = node!.lastAccess.millisecondsSinceEpoch;
      if (ms > maxMs) maxMs = ms;
    }
    return maxMs;
  }

  Future<ProcedureEngine> engineFor(SqliteTomBrainMemory store) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    return ProcedureEngine(
      resolver: ProcedureResolver(
          <LoadedProcedure>[system.resolve('dream_decay_v1')]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: 'dream_decay_v1'),
      substrateBridge: SubstrateBridge(_NoopSubstrate()),
      now: () => DateTime.utc(2026, 6, 10, 12, 0, 0),
    );
  }

  /// Runs the decay pass with the given clock + knobs, returning its outcome.
  Future<ProcedureOutcome> runDecay(
    SqliteTomBrainMemory store, {
    required int nowMs,
    int? maxPerPass,
    int? coldnessFloorDays,
    int? minAccessCount,
    int? defaultHalfLifeDays,
    Map<String, int>? halfLifeDays,
  }) async {
    store.registerAgent(_decayAgent());
    final engine = await engineFor(store);
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'dream_decay_v1',
          arguments: <String, Object?>{
            'source': _salientTerm,
            'nowMs': nowMs,
            'maxPerPass': ?maxPerPass,
            'coldnessFloorDays': ?coldnessFloorDays,
            'minAccessCount': ?minAccessCount,
            'defaultHalfLifeDays': ?defaultHalfLifeDays,
            'halfLifeDays': ?halfLifeDays,
          },
        ))
        .outcome;
  }

  List<String> demotedIdsOf(ProcedureOutcome outcome) =>
      outcome.result!.output<List<Object?>>('demotedIds')!.cast<String>();

  group('dream_decay_v1 through the engine against real memory (needs vec0)',
      () {
    test('demotes only the cold, rarely-used, past-half-life node', () async {
      final store = await openStore();

      // A cold Event (never accessed) — eligible once aged past the 90-day
      // default half-life.
      final cold = await seedEvent(store,
          summary: 'The project build shipped to bomber.',
          key: 'cold',
          seed: 1);
      // A warm Event — same age, but accessed once, so excluded by the
      // access-count gate (minAccessCount: 0).
      final warm = await seedEvent(store,
          summary: 'The project backup synced to the NAS.',
          key: 'warm',
          seed: 2);
      // A long-lived Claim — same age, but its per-type half-life (1000 d) is
      // far longer than the pass age, so it is not yet due.
      final longLived = await seedClaim(store,
          statement: 'The project mission statement is durable.',
          key: 'longlived',
          seed: 3);

      // Warm the second Event once (bumps access_count 0 → 1, last access → now).
      await store.recordAccess(<NodeId>[warm], producer: 'decay:test');

      final beforeStats = await store.stats();
      expect(beforeStats.nodeCountByType['Event'], 2);
      expect(beforeStats.nodeCountByType['Claim'], 1);

      // The pass clock is 200 days past the latest access, so every node is
      // comfortably past the 30-day floor.
      final base = await latestAccessMs(store, <NodeId>[cold, warm, longLived]);
      final nowMs = base + 200 * _msPerDay;

      final outcome = await runDecay(
        store,
        nowMs: nowMs,
        minAccessCount: 0,
        coldnessFloorDays: 30,
        defaultHalfLifeDays: 90,
        halfLifeDays: <String, int>{'Claim': 1000},
      );
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // Only the cold Event was demoted.
      expect(demotedIdsOf(outcome), <String>[cold.value]);

      // The Verify (HP6): the cold Event left default retrieval but stays
      // addressable by id; the warm Event and the Claim remain active.
      final afterStats = await store.stats();
      expect(afterStats.nodeCountByType['Event'], 1,
          reason: 'the cold Event was demoted out of default retrieval');
      expect(afterStats.nodeCountByType['Claim'], 1,
          reason: 'the long-lived Claim is still inside its half-life');

      expect((await store.get(cold))!.status, NodeStatus.demoted,
          reason: 'demoted, not deleted — still addressable by id (HP6)');
      expect((await store.get(warm))!.status, NodeStatus.active,
          reason: 'a frequently-accessed node is never decayed');
      expect((await store.get(longLived))!.status, NodeStatus.active,
          reason: 'a node inside its per-type half-life is not due');
    }, skip: skipNoBinary);

    test('demotes nothing on a freshly-accessed store (inside the floor)',
        () async {
      final store = await openStore();

      final a = await seedEvent(store,
          summary: 'The project planning note A.', key: 'a', seed: 11);
      final b = await seedEvent(store,
          summary: 'The project planning note B.', key: 'b', seed: 12);

      // The pass clock is only 5 days past the latest access — inside the
      // 30-day coldness floor, so no node is eligible regardless of age vs
      // half-life or access count.
      final base = await latestAccessMs(store, <NodeId>[a, b]);
      final nowMs = base + 5 * _msPerDay;

      final outcome = await runDecay(
        store,
        nowMs: nowMs,
        minAccessCount: 0,
        coldnessFloorDays: 30,
        defaultHalfLifeDays: 1,
      );
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // Even with an aggressive 1-day half-life, the floor protects every node.
      expect(demotedIdsOf(outcome), isEmpty);
      final afterStats = await store.stats();
      expect(afterStats.nodeCountByType['Event'], 2,
          reason: 'the floor protects a freshly-accessed store');
    }, skip: skipNoBinary);

    test('respects the maxPerPass budget — demotes only the coldest N',
        () async {
      final store = await openStore();

      final ids = <NodeId>[
        await seedEvent(store,
            summary: 'The project cold one.', key: 'c1', seed: 21),
        await seedEvent(store,
            summary: 'The project cold two.', key: 'c2', seed: 22),
        await seedEvent(store,
            summary: 'The project cold three.', key: 'c3', seed: 23),
      ];

      // All three are cold, never accessed, and well past the half-life.
      final base = await latestAccessMs(store, ids);
      final nowMs = base + 200 * _msPerDay;

      final outcome = await runDecay(
        store,
        nowMs: nowMs,
        maxPerPass: 2,
        minAccessCount: 0,
        coldnessFloorDays: 30,
        defaultHalfLifeDays: 90,
      );
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // Exactly the budget was spent, on a subset of the eligible cold nodes.
      final demoted = demotedIdsOf(outcome);
      expect(demoted, hasLength(2),
          reason: 'the per-pass budget caps demotions at maxPerPass');
      final allIds = ids.map((i) => i.value).toSet();
      expect(allIds.containsAll(demoted), isTrue);

      // One eligible Event remains active — recalibration is gradual.
      final afterStats = await store.stats();
      expect(afterStats.nodeCountByType['Event'], 1,
          reason: 'the third cold node waits for the next pass');
    }, skip: skipNoBinary);
  });
}

/// A no-op substrate: the decay agent calls no LLM/embed/web, so every method
/// routes through `noSuchMethod` and is never invoked.
class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
