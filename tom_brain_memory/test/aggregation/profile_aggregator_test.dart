// ProfileAggregator — the cross-profile global-aggregation engine
// (memory_specification.md § 2.6, GA-1…GA-11). I-3 Phase 1 Done-when.
//
// Two layers of test:
//
//   1. A pure off-by-default unit test over a fake registry — proves GA-11
//      (a disabled tier touches nothing). Always runs.
//   2. The load-bearing GA-INV isolation test against a REAL
//      SqliteTomBrainMemory with two real profiles. Skipped (not failed)
//      when no packaged vec0 binary is present, exactly like
//      `mcp_real_store_profile_isolation_test.dart` / `h27_*`.
//
// The real-store test asserts the I-3 Done-when set in one pass:
//   * one pass derives BOTH source profiles' Concepts into `global`, each
//     stamped with its source provenance (GA-3 / GA-4 / GA-6);
//   * an episodic `Event` in a source is NEVER aggregated (GA-3 allowlist);
//   * the source profiles are byte-for-byte untouched — same values, same
//     usage columns (a stream scan is access-neutral, GA-9);
//   * a second pass writes zero new nodes and does not re-stamp the existing
//     ones (GA-7 idempotent re-derive);
//   * `profiles.list` includes `global` once materialised (GA-10).

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        MemoryConfig,
        Node,
        NodeDraft,
        Scope,
        StreamQuery,
        SymbolicFilter,
        SystemClock,
        TomBrainMemoryClient,
        Vec,
        reservedGlobalProfile;

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
    final candidate = Directory('${dir.path}${Platform.pathSeparator}'
        'tom_binaries${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<List<Node>> _conceptsIn(TomBrainMemory store, String profile) =>
    store.profiles.readInProfile(
      profile,
      (c) async => c
          .stream(const StreamQuery(filter: SymbolicFilter(typeNames: {'Concept'})))
          .toList(),
    );

Future<List<Node>> _eventsIn(TomBrainMemory store, String profile) =>
    store.profiles.readInProfile(
      profile,
      (c) async => c
          .stream(const StreamQuery(filter: SymbolicFilter(typeNames: {'Event'})))
          .toList(),
    );

void main() {
  group('GA-11 off-by-default (no real store)', () {
    test('a disabled aggregator scans nothing and writes nothing', () async {
      final registry = _RecordingRegistry();
      final aggregator = ProfileAggregator(
        registry: registry,
        clock: const SystemClock(),
        // default config: enabled == false.
      );

      final result = await aggregator.runPass();

      expect(result.ran, isFalse);
      expect(result.nodesScanned, 0);
      expect(result.nodesDerived, 0);
      expect(registry.calls, isEmpty,
          reason: 'a disabled pass must not even enumerate profiles');
    });
  });

  group('GA-INV cross-profile aggregation — real SqliteTomBrainMemory', () {
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

    test(
        'one pass derives both profiles into global with provenance; events '
        'are not aggregated; sources untouched; second pass is idempotent; '
        'profiles.list includes global', () async {
      final root =
          Directory.systemTemp.createTempSync('tbm_aggregate_').path;
      addTearDown(() {
        final dir = Directory(root);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final store = SqliteTomBrainMemory();
      await store
          .open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!));
      addTearDown(store.close);

      const scope = Scope(producer: 'aggregator_test:seed');

      // Two real source profiles, each with a Concept; 'work' also holds an
      // episodic Event that must never aggregate.
      await store.profiles.createProfile('work');
      await store.profiles.seedProfile(
        'work',
        [
          _concept('kubernetes', 'container orchestration', seed: 1),
          // an Event — episodic, GA-3 excludes it.
        ],
        scope: scope,
      );
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

      // Snapshot the source Concepts before the pass (values + usage).
      final workBefore = (await _conceptsIn(store, 'work')).single;
      final homeBefore = (await _conceptsIn(store, 'home')).single;

      final aggregator = ProfileAggregator(
        registry: store.profiles,
        clock: const SystemClock(),
        config: const AggregationConfig(enabled: true),
      );

      final first = await aggregator.runPass();
      expect(first.ran, isTrue);
      expect(first.sourceProfiles, containsAll(<String>['work', 'home']));
      expect(first.sourceProfiles, isNot(contains(reservedGlobalProfile)));
      // Two Concepts scanned + derived; the Event is filtered out by the
      // type allowlist before it is ever streamed (GA-3).
      expect(first.nodesScanned, 2);
      expect(first.nodesDerived, 2);

      // GA-3/4/6: global holds both Concepts, each with source provenance.
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
      expect(byName['gardening']!.values[aggregationSourceNodeIdKey],
          homeBefore.id.value);
      // _aggregatedAt is a parseable UTC ISO-8601 instant.
      final stampedAt =
          byName['kubernetes']!.values[aggregationAtKey] as String;
      expect(DateTime.parse(stampedAt).isUtc, isTrue);

      // GA-3: no Event ever reached global.
      expect(await _eventsIn(store, reservedGlobalProfile), isEmpty);

      // GA-INV: the sources are byte-for-byte untouched — same semantic
      // values and same usage columns (a stream scan never bumps usage).
      final workAfter = (await _conceptsIn(store, 'work')).single;
      final homeAfter = (await _conceptsIn(store, 'home')).single;
      expect(workAfter.values, equals(workBefore.values));
      expect(homeAfter.values, equals(homeBefore.values));
      expect(workAfter.accessCount, workBefore.accessCount);
      expect(workAfter.lastAccess, workBefore.lastAccess);
      expect(homeAfter.accessCount, homeBefore.accessCount);
      // The sources never gained provenance fields.
      expect(workAfter.values.containsKey(aggregationSourceProfileKey),
          isFalse);

      // GA-7: a second pass writes zero new nodes and does not re-stamp the
      // existing ones (idempotent re-derive).
      final globalBeforeIds =
          globalConcepts.map((n) => n.id.value).toSet();
      final globalBeforeStamp =
          byName['kubernetes']!.values[aggregationAtKey];

      final second = await aggregator.runPass();
      expect(second.nodesDerived, 2, reason: 'derive count is per-scan');

      final globalConcepts2 = await _conceptsIn(store, reservedGlobalProfile);
      expect(globalConcepts2, hasLength(2),
          reason: 'idempotent: no new rows on the second pass');
      expect(globalConcepts2.map((n) => n.id.value).toSet(),
          equals(globalBeforeIds),
          reason: 'same node ids — persist was a no-op on the idempotency key');
      final kube2 = globalConcepts2
          .firstWhere((n) => n.values['name'] == 'kubernetes');
      expect(kube2.values[aggregationAtKey], globalBeforeStamp,
          reason: 'idempotent re-derive does not overwrite the first stamp');

      // GA-10: profiles.list includes the materialised global tier.
      expect(await store.profiles.list(), contains(reservedGlobalProfile));
    }, skip: skipNoBinary);
  });
}

/// A registry that records every method invocation, so the off-by-default
/// test can prove a disabled pass touches nothing. All data methods throw —
/// reaching them would itself be the failure.
final class _RecordingRegistry implements MemoryProfileRegistry {
  final List<String> calls = <String>[];

  Never _unexpected(String name) {
    calls.add(name);
    throw StateError('disabled aggregator called $name');
  }

  @override
  Future<List<String>> list() => _unexpected('list');

  @override
  Future<bool> exists(String name) => _unexpected('exists');

  @override
  Future<void> createProfile(String name) => _unexpected('createProfile');

  @override
  Future<void> seedProfile(String name, List<NodeDraft> drafts,
          {required Scope scope}) =>
      _unexpected('seedProfile');

  @override
  Future<void> dropProfile(String name) => _unexpected('dropProfile');

  @override
  Future<T> readInProfile<T>(
          String name, Future<T> Function(TomBrainMemoryClient body) body) =>
      _unexpected('readInProfile');

  @override
  Future<T> writeInProfile<T>(
          String name, Future<T> Function(TomBrainMemoryClient body) body) =>
      _unexpected('writeInProfile');
}
