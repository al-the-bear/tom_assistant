// dream_aggregate_v1 — the cross-profile global-aggregation agent (memory
// § 2.6, Phase 2; `tom_brain_completion_plan_2.md` item 1). I-3 Phase 2 Done-when.
//
// This is the procedure-level counterpart of the engine's GA-INV isolation test
// (`tom_brain_memory/test/aggregation/profile_aggregator_test.dart`). It drives
// the shipped `scripts/system/dream_aggregate_v1.dart` through `ProcedureEngine`
// against a *real* on-disk `SqliteTomBrainMemory` with two real source profiles
// and a no-op substrate (the agent calls no LLM), asserting the whole path:
//
//   procedure → `mem.aggregateProfilesIntoGlobal` bridge primitive →
//   `AggregatingMemory` engine seam → `ProfileAggregator` pass →
//   derived nodes land in `global` under the `aggregator` agent.
//
// Asserts:
//   * the procedure run is accepted and its declared outputs carry the engine
//     summary (`ran`, `sourceProfiles`, `nodesScanned`, `nodesDerived`);
//   * both source profiles' Concepts are derived into `global` with source
//     provenance (GA-3 / GA-4 / GA-6);
//   * an episodic `Event` is never aggregated (GA-3 allowlist);
//   * the source profiles are byte-for-byte untouched (GA-INV / GA-9).
//
// Like the other real-store suites this opens the on-disk store, which refuses
// to boot without the packaged vec0 binary (P1.1), so the group is skipped — not
// failed — when no binary is present for the platform.

// @Timeout — heavy end-to-end d4rt integration test (real store / vec0 / full
// procedure). The generous ceiling removes a false TimeoutException under an
// oversubscribed parallel runner and only ever bites a genuine hang.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        AgentRegistration,
        AggregationConfig,
        Node,
        NodeDraft,
        Scope,
        StreamQuery,
        SymbolicFilter,
        Vec,
        WriteBudget,
        reservedGlobalProfile;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

const _dims = 768;

Vec _v({required int seed}) {
  final values = Float32List(_dims);
  for (var i = 0; i < _dims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

NodeDraft _concept(String name, String description, {required int seed}) =>
    NodeDraft(
      typeName: 'Concept',
      values: <String, Object?>{'name': name, 'description': description},
      embedding: _v(seed: seed),
    );

NodeDraft _event(String summary, {required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': summary,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-07T10:00:00.000Z',
      },
      embedding: _v(seed: seed),
    );

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

Future<List<Node>> _conceptsIn(SqliteTomBrainMemory store, String profile) =>
    store.profiles.readInProfile(
      profile,
      (c) async => c
          .stream(const StreamQuery(
              filter: SymbolicFilter(typeNames: {'Concept'})))
          .toList(),
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
          'tom_binaries/sqlite_vec.'
      : null;

  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_dagg_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = SqliteTomBrainMemory();
    await store.open(MemoryConfig.forTesting(
      root: root.path,
      binariesRoot: vecRoot!,
      aggregation: const AggregationConfig(enabled: true),
    ));
    addTearDown(store.close);
    return store;
  }

  Future<ProcedureEngine> engineFor(SqliteTomBrainMemory store) async {
    final system = await ProcedureResolver.fromStore(
      DiskProcedureStore(systemDir: Directory('scripts/system')),
    );
    return ProcedureEngine(
      resolver: ProcedureResolver(
          <LoadedProcedure>[system.resolve('dream_aggregate_v1')]),
      memory: store,
      memoryBridge: MemoryBridge(store, agentName: 'dream_aggregate_v1'),
      substrateBridge: SubstrateBridge(_NoopSubstrate()),
      now: () => DateTime.utc(2026, 6, 10, 12, 0, 0),
    );
  }

  group('dream_aggregate_v1 through the engine against real memory (needs vec0)',
      () {
    test(
        'derives both source profiles into global with provenance, leaves the '
        'sources untouched, and returns the pass summary as outputs', () async {
      final store = await openStore();
      // The agent writes nothing under its own identity (the global writes are
      // issued by the in-engine `aggregator`), so an empty write-scope grant
      // mirrors the Pruner registration.
      store.registerAgent(AgentRegistration(
        agentName: 'dream_aggregate_v1',
        procedureId: 'dream_aggregate_v1',
        defaultBudget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0),
        readScopes: const <String>{AgentRegistration.globalWildcard},
        writeScopes: const <String>{},
      ));

      const scope = Scope(producer: 'dagg_test:seed');
      await store.profiles.createProfile('work');
      await store.profiles.seedProfile(
        'work',
        [_concept('kubernetes', 'container orchestration', seed: 1)],
        scope: scope,
      );
      // An episodic Event in a source — GA-3 must never aggregate it.
      await store.profiles.seedProfile(
        'work',
        [_event('deployed the cluster', seed: 11)],
        scope: scope,
      );
      await store.profiles.createProfile('home');
      await store.profiles.seedProfile(
        'home',
        [_concept('gardening', 'growing vegetables', seed: 2)],
        scope: scope,
      );

      final workBefore = (await _conceptsIn(store, 'work')).single;
      final homeBefore = (await _conceptsIn(store, 'home')).single;

      final engine = await engineFor(store);
      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'dream_aggregate_v1'))
          .outcome;

      // The run is accepted and its declared outputs carry the engine summary.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      final outputs = outcome.result!.outputs;
      expect(outputs['ran'], isTrue);
      expect(outputs['sourceProfiles'], isA<List<Object?>>());
      expect((outputs['sourceProfiles'] as List).toSet(),
          containsAll(<String>['work', 'home']));
      expect(outputs['nodesScanned'], 2);
      expect(outputs['nodesDerived'], 2);

      // GA-3 / GA-4 / GA-6: global holds both Concepts with source provenance.
      final globalConcepts = await _conceptsIn(store, reservedGlobalProfile);
      expect(globalConcepts, hasLength(2));
      final byName = {
        for (final n in globalConcepts) n.values['name'] as String: n,
      };
      expect(byName.keys, containsAll(<String>['kubernetes', 'gardening']));
      expect(byName['kubernetes']!.values[aggregationSourceProfileKey], 'work');
      expect(byName['kubernetes']!.values[aggregationSourceNodeIdKey],
          workBefore.id.value);
      expect(byName['gardening']!.values[aggregationSourceProfileKey], 'home');

      // GA-INV / GA-9: the sources are byte-for-byte untouched.
      final workAfter = (await _conceptsIn(store, 'work')).single;
      final homeAfter = (await _conceptsIn(store, 'home')).single;
      expect(workAfter.values, equals(workBefore.values));
      expect(homeAfter.values, equals(homeBefore.values));
      expect(workAfter.accessCount, workBefore.accessCount);
      expect(workAfter.lastAccess, workBefore.lastAccess);
    }, skip: skipNoBinary);
  });
}

/// A substrate that is never called — `dream_aggregate_v1` issues no LLM call.
final class _NoopSubstrate implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
