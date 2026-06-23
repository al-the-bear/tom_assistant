// dream_procedure_metrics_v1 — the procedure metrics / promotion-demotion pass
// (Todo 7 G-PR5; `procedure_specification.md` § 6.4, § 7.1).
//
// The Synthesizer-cadence agent that turns a Procedure's immutable ProcedureRun
// history into the derived metric/status cache and the active⇄preferred stage,
// and demotes a repeatedly-failing procedure through the shared node-lifecycle
// `demote`. This suite drives the shipped `scripts/system/dream_procedure_metrics_v1.dart`
// through `ProcedureEngine.invoke` against a *real* on-disk `SqliteTomBrainMemory`
// and a no-op substrate (the agent calls no LLM) and asserts:
//
//   - Promotion: an `active` procedure with enough `accepted` finished runs is
//     promoted to `preferred`, and its cached `successRate` / `runCount` /
//     `lastRunAt` reflect only the *finished* runs (the `running` start marker
//     is excluded).
//   - Demotion: an `active` procedure whose finished runs are mostly failures
//     leaves default retrieval via `mem.demote` — the node-lifecycle demote, so
//     `stats.nodeCountByType['Procedure']` drops — while every immutable
//     ProcedureRun record is retained (hard principle 6).
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
    show AgentRegistration, NodeDraft, NodeId, Scope, Vec, WriteBudget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector; the Procedure embedding source is
/// `[name, summary]` (non-`none`), so a seeded Procedure carries one.
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

/// A budget wide enough never to interfere — the per-run *header* budget bounds
/// the run.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

/// Registers a cognitive agent whose id equals [name] with the given write
/// [scopes]. The metrics agent demotes / updates-metrics through the shared
/// node-lifecycle writes that carry no Scope (mirrors the Pruner), so it needs
/// no node/edge write scope.
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
    final root = Directory.systemTemp.createTempSync('tbm_dpm_');
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

  /// Seeds a `Procedure` node (logical id [name], lifecycle [status]), unscoped
  /// (the authoring/system write path). Returns its stable node id.
  Future<NodeId> seedProcedure(
    SqliteTomBrainMemory store, {
    required String name,
    required String status,
  }) =>
      store.persist(
        NodeDraft(
          typeName: 'Procedure',
          values: <String, Object?>{
            'name': name,
            'summary': 'A test procedure named $name.',
            'code': '// $name body',
            'status': status,
            'revision': 1,
            'requires': const <String>[],
          },
          embedding: _v768(seed: name.length),
        ),
        scope: Scope(producer: 'dpm:seed', idempotencyKey: 'proc-$name'),
      );

  /// Seeds one *finished* `ProcedureRun` record for [procedureId] (the
  /// authoritative record the recorder writes at `complete()`), with the given
  /// terminal [status] and a [day]-stamped finish timestamp so the newest is
  /// the largest `day`.
  Future<void> seedFinishedRun(
    SqliteTomBrainMemory store, {
    required String procedureId,
    required String status,
    required int day,
    required int runIndex,
  }) async {
    final started = '2026-06-${day.toString().padLeft(2, '0')}T10:00:00.000Z';
    final finished = '2026-06-${day.toString().padLeft(2, '0')}T10:00:05.000Z';
    await store.persist(
      NodeDraft(
        typeName: 'ProcedureRun',
        values: <String, Object?>{
          'procedureId': procedureId,
          'version': 1,
          'runId': 'engine:$procedureId:r$runIndex',
          'status': status,
          'summary': 'run $runIndex of $procedureId ended $status',
          'startedAt': started,
          'finishedAt': finished,
          'trailId': 'trail:$procedureId:r$runIndex',
        },
      ),
      scope: Scope(producer: 'dpm:seed', idempotencyKey: 'run-$procedureId-$runIndex'),
    );
  }

  /// Seeds a `running` start marker for [procedureId] (the lightweight first
  /// record the recorder writes at `start()`). The metrics pass must NOT count
  /// it as a finished run.
  Future<void> seedRunningMarker(
    SqliteTomBrainMemory store, {
    required String procedureId,
    required int runIndex,
  }) =>
      store.persist(
        NodeDraft(
          typeName: 'ProcedureRun',
          values: <String, Object?>{
            'procedureId': procedureId,
            'version': 1,
            'runId': 'engine:$procedureId:r$runIndex',
            'status': 'running',
            'startedAt': '2026-06-09T10:00:00.000Z',
            'trailId': 'trail:$procedureId:r$runIndex',
          },
        ),
        scope: Scope(
            producer: 'dpm:seed', idempotencyKey: 'marker-$procedureId-$runIndex'),
      );

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
      now: () => DateTime.utc(2026, 6, 10, 12, 0, 0),
    );
  }

  Future<ProcedureOutcome> runMetrics(SqliteTomBrainMemory store) async {
    store.registerAgent(_agent('dream_procedure_metrics_v1', const <String>{}));
    final engine = await engineFor(
      store: store,
      substrate: _NoopSubstrate(),
      agentName: 'dream_procedure_metrics_v1',
    );
    return engine
        .invoke(ProcedureInvocation(
          procedureId: 'dream_procedure_metrics_v1',
        ))
        .outcome;
  }

  group('dream_procedure_metrics_v1 through the engine against real memory '
      '(needs vec0)', () {
    test('promotes a reliable active procedure to preferred and caches its '
        'rolling metrics over finished runs only', () async {
      final store = await openStore();
      final procId = await seedProcedure(store,
          name: 'reliable_proc_v1', status: 'active');
      // Five finished, all accepted → successRate 1.0 over 5 runs.
      for (var i = 0; i < 5; i++) {
        await seedFinishedRun(store,
            procedureId: 'reliable_proc_v1',
            status: 'accepted',
            day: i + 1,
            runIndex: i);
      }
      // A still-running marker for a sixth run: must NOT count toward runCount.
      await seedRunningMarker(store, procedureId: 'reliable_proc_v1', runIndex: 5);

      final outcome = await runMetrics(store);
      expect(outcome.status, TrailOutcomeStatus.accepted);

      final node = await store.get(procId);
      expect(node, isNotNull);
      final values = node!.values;
      expect(values['status'], 'preferred',
          reason: 'earned trust: ≥promoteSuccessRate over ≥promoteMinRuns');
      expect((values['successRate'] as num).toDouble(), 1.0);
      expect(values['runCount'], 5,
          reason: 'the running start marker is excluded from the run count');
      expect(values['lastRunAt'], '2026-06-05T10:00:05.000Z',
          reason: 'newest finished run timestamp');
    });

    test('demotes a repeatedly-failing active procedure through node-lifecycle '
        'demote while retaining its immutable run history', () async {
      final store = await openStore();
      await seedProcedure(store, name: 'flaky_proc_v1', status: 'active');
      // One accepted + four errored → successRate 0.2 over 5 runs (≤ demote bar).
      await seedFinishedRun(store,
          procedureId: 'flaky_proc_v1',
          status: 'accepted',
          day: 1,
          runIndex: 0);
      for (var i = 1; i < 5; i++) {
        await seedFinishedRun(store,
            procedureId: 'flaky_proc_v1',
            status: 'errored',
            day: i + 1,
            runIndex: i);
      }

      final before = await store.stats();
      expect(before.nodeCountByType['Procedure'] ?? 0, 1);

      final outcome = await runMetrics(store);
      expect(outcome.status, TrailOutcomeStatus.accepted);

      final after = await store.stats();
      expect(after.nodeCountByType['Procedure'] ?? 0, 0,
          reason: 'the failing procedure was demoted out of default retrieval');
      // HP6: demotion never deletes — the flaky procedure's immutable run
      // history is still fully readable by id (the metrics pass adds its own
      // run records, so the global ProcedureRun count is not a stable check).
      final retained =
          await const ProcedureRunsOf('flaky_proc_v1').execute(store);
      expect(retained.length, 5,
          reason: 'every immutable ProcedureRun record is retained (HP6)');
    });

    test('lapses a preferred procedure back to active when its rolling rate '
        'has fallen below the promotion bar', () async {
      final store = await openStore();
      final procId = await seedProcedure(store,
          name: 'slipping_proc_v1', status: 'preferred');
      // Four finished, two accepted → successRate 0.5: below promoteSuccessRate
      // (0.8) so trust lapses, but above demoteSuccessRate (0.3) and only four
      // runs (< demoteMinRuns 5), so it is not demoted — it returns to active.
      for (var i = 0; i < 2; i++) {
        await seedFinishedRun(store,
            procedureId: 'slipping_proc_v1',
            status: 'accepted',
            day: i + 1,
            runIndex: i);
      }
      for (var i = 2; i < 4; i++) {
        await seedFinishedRun(store,
            procedureId: 'slipping_proc_v1',
            status: 'errored',
            day: i + 1,
            runIndex: i);
      }

      final outcome = await runMetrics(store);
      expect(outcome.status, TrailOutcomeStatus.accepted);

      final node = await store.get(procId);
      expect(node, isNotNull);
      final values = node!.values;
      expect(values['status'], 'active',
          reason: 'trust is not permanent — a slipped preferred proc lapses');
      expect((values['successRate'] as num).toDouble(), 0.5);
      expect(values['runCount'], 4);
    });

    test('recomputes from the full immutable history every pass — a procedure '
        'that grows past the promotion threshold is promoted on a later pass',
        () async {
      final store = await openStore();
      final procId = await seedProcedure(store,
          name: 'growing_proc_v1', status: 'active');

      // First pass: three accepted runs — strong (rate 1.0) but below
      // promoteMinRuns (5), so the stage holds at active while the counters are
      // still refreshed from the finished history.
      for (var i = 0; i < 3; i++) {
        await seedFinishedRun(store,
            procedureId: 'growing_proc_v1',
            status: 'accepted',
            day: i + 1,
            runIndex: i);
      }
      final first = await runMetrics(store);
      expect(first.status, TrailOutcomeStatus.accepted);

      final afterFirst = (await store.get(procId))!;
      expect(afterFirst.values['status'], 'active',
          reason: 'three runs is below the promotion threshold');
      expect(afterFirst.values['runCount'], 3);

      // Two more accepted runs land in the immutable history (distinct
      // runIndex → distinct idempotency keys). A second pass recomputes over
      // all five and now clears the threshold.
      for (var i = 3; i < 5; i++) {
        await seedFinishedRun(store,
            procedureId: 'growing_proc_v1',
            status: 'accepted',
            day: i + 1,
            runIndex: i);
      }
      final second = await runMetrics(store);
      expect(second.status, TrailOutcomeStatus.accepted);

      final afterSecond = (await store.get(procId))!;
      expect(afterSecond.values['status'], 'preferred',
          reason: 'the grown run set now clears the promotion threshold');
      expect(afterSecond.values['runCount'], 5);
      expect(afterSecond.values['lastRunAt'], '2026-06-05T10:00:05.000Z',
          reason: 'newest finished run timestamp across both passes');
    });
  }, skip: skipNoBinary);
}

/// A no-op substrate: the metrics agent calls no LLM/embed/web, so every method
/// routes through `noSuchMethod` and is never invoked.
class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
