// memory_optimization_plan § 8 — `countsAsAccess` wired through recall.
//
// Plan § 8:
//   "Wire `countsAsAccess` through the recall path so a recall with
//    `countsAsAccess: true` calls `recordAccess` on its returned ids, and
//    the default (`false`) never bumps. Done when an integration test
//    shows a `countsAsAccess:true` recall raises `access_count` /
//    `last_access_ms` while a default recall leaves them unchanged."
//
// Surface under test: `SqliteTomBrainMemory.recall` /
// `recallMulti`. The store owns both `_recallExecutor` (read) and
// `_accessRecorder` (the sole usage-column writer, see
// `NodeAccessRecorder`), so the `countsAsAccess` side effect is wired at
// the store level — between the read-only executor returning and the
// result handed back. The isolate transport inherits this for free
// because `IsolateExecutor` calls the real store's `recall` /
// `recallMulti` (isolate_executor.dart).
//
// `countsAsAccess` defaults to `false`: most recalls are read-only
// inspections that must not perturb the recency / frequency signal the
// `RecallRanking` strategies read (§ 6.6). Usage reflects *use*, not
// inspection.
//
// The returned `RecallResult` is the *pre-bump* materialised snapshot —
// the usage write is a side effect, so the raised values are observed on
// a *subsequent* `get(id)`, not on the returned nodes.
//
// Like p2_13 – p2_17, these cases need the packaged vec0 binary (the
// store refuses to boot without it — P1.1) and are skipped, not failed,
// when the running platform has no binary under
// `tom_binaries/sqlite_vec/<platform>/`.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, RecallMode, RecallQuery, Vec;

/// The bootstrap embedding model dims (Event embeds under it). Mirrors
/// p2_16.
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 `_v768`.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors p2_16.
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

  /// Opens a fresh store rooted in a unique temp dir, registers teardown
  /// for both the store and the directory, and returns the open store.
  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_counts_access_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(
      root: root.path,
      binariesRoot: vecRoot!,
    ));
    return store;
  }

  /// Persists an Event whose `summary` carries [text] and whose
  /// embedding is `_v768(seed:)`. Returns the assigned node id.
  Future<NodeId> persistEvent(
    SqliteTomBrainMemory store, {
    required String text,
    required int seed,
    required String key,
  }) {
    return store.persist(
      NodeDraft(
        typeName: 'Event',
        values: <String, Object?>{
          'summary': text,
          'payload': const <String, Object?>{},
          'occurred_at': '2026-06-05T10:00:00.000Z',
        },
        embedding: _v768(seed: seed),
      ),
      scope: Scope(producer: 'counts_as_access:test', idempotencyKey: key),
    );
  }

  group('SqliteTomBrainMemory.recall — countsAsAccess (needs vec0)', () {
    test('countsAsAccess:true raises access_count / last_access_ms on the '
        'returned ids', () async {
      final store = await openStore();
      final hit = await persistEvent(store,
          text: 'alpha bravo charlie distinctive', seed: 1, key: 'ev-hit');

      // A freshly persisted node has no usage: access_count 0 and
      // last_access defaults (COALESCE) to created_at.
      final before = await store.get(hit);
      expect(before, isNotNull);
      expect(before!.accessCount, equals(0));
      expect(before.lastAccess, equals(before.createdAt));

      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'distinctive',
        k: 10,
        countsAsAccess: true,
      ));
      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(hit));
      // The returned result is the PRE-bump snapshot — the raised values
      // are observed on a subsequent read, not on the returned nodes.
      expect(result.nodes.first.accessCount, equals(0));

      final after = await store.get(hit);
      expect(after, isNotNull);
      expect(after!.accessCount, equals(1),
          reason: 'countsAsAccess:true bumps access_count by one');
      expect(
        after.lastAccess.isBefore(before.lastAccess),
        isFalse,
        reason: 'last_access_ms is stamped to the access instant, '
            'never moves backward',
      );
    });

    test('a default recall (countsAsAccess unset) leaves usage unchanged',
        () async {
      final store = await openStore();
      final hit = await persistEvent(store,
          text: 'alpha bravo charlie distinctive', seed: 1, key: 'ev-hit');

      final before = await store.get(hit);
      expect(before!.accessCount, equals(0));

      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'distinctive',
        k: 10,
        // countsAsAccess defaults to false.
      ));
      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(hit));

      final after = await store.get(hit);
      expect(after!.accessCount, equals(0),
          reason: 'a read-only recall must not bump access_count');
      expect(after.lastAccess, equals(before.lastAccess),
          reason: 'a read-only recall must not move last_access');
    });

    test('an empty-result countsAsAccess recall is a harmless no-op',
        () async {
      final store = await openStore();
      final hit = await persistEvent(store,
          text: 'alpha bravo charlie', seed: 1, key: 'ev-hit');

      // A query that matches nothing returns no nodes; recording access
      // over an empty id set must not throw and must not touch the
      // unrelated seeded node.
      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'zzzznomatchterm',
        k: 10,
        countsAsAccess: true,
      ));
      expect(result.nodes, isEmpty);

      final unchanged = await store.get(hit);
      expect(unchanged!.accessCount, equals(0));
    });
  }, skip: skipNoBinary);
}
