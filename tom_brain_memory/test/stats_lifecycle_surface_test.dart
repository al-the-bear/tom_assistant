// memory_optimization_plan § 17 — lifecycle + access stats on the
// real store's `stats()` surface.
//
// Plan § 17:
//   "Add `NodePromoted` to the `MemoryEvent` taxonomy and `stats()`
//    surface (and any usage histograms worth exposing to the
//    Observatory). Done when the event is emitted by `promote()` and
//    appears on the global `events()` feed."
//
// The taxonomy + `events()` half is proven by node_lifecycle_test.dart
// (`NodePromoted` is emitted by `promote()` and observed on the bus).
// § 17 also lands two `stats()` slices that ride those same events:
//
//   * `lifecycleEventCounts` — a synchronous tally of the four
//     node-lifecycle events (`node-persisted` / `-promoted` /
//     `-demoted` / `-forgotten`). The store feeds it inline via
//     `_emitLifecycleCounted` (the sink the two lifecycle producers
//     emit through), so the count is exact the instant `stats()` reads
//     it — no race against the async `events()` broadcast.
//
//   * `accessCountHistogram` — the live (active) corpus bucketed by the
//     `access_count` column `recordAccess` writes (§ 16).
//
// a85 unit-tests the counter and the collector wiring; node_lifecycle
// tests the collector against a real v2 DB. This file is the *store*
// proof: open a real `SqliteTomBrainMemory`, drive
// persist/demote/promote/recordAccess through the public API, and
// assert `store.stats()` reflects the transitions. It exercises the
// store's own tap (`_emitLifecycleCounted`) and tear-off wiring, which
// neither lower test can reach.
//
// Assertions are stated as before→after *deltas* so the store's
// bootstrap writes (Stack nodes, node-type registrations seeded during
// `open`) do not need to be enumerated — only the change this test
// causes is asserted.
//
// Like p2_13 – p2_17 and counts_as_access_recall_test.dart, these cases
// need the packaged vec0 binary (the store refuses to boot without it)
// and are skipped, not failed, when the running platform has no binary
// under `tom_binaries/sqlite_vec/<platform>/`.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        DemotionReason,
        NodeDraft,
        NodeId,
        PromotionReason,
        Scope,
        Vec;

const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 / counts_as_access.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors counts_as_access_recall_test.dart.
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

/// `(after[key] ?? 0) - (before[key] ?? 0)` — the change in a single
/// histogram bucket across the seeded operations.
int _delta(Map<String, int> after, Map<String, int> before, String key) =>
    (after[key] ?? 0) - (before[key] ?? 0);

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

  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_stats_lifecycle_');
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
      scope: Scope(producer: 'stats_lifecycle:test', idempotencyKey: key),
    );
  }

  group('SqliteTomBrainMemory.stats — § 17 lifecycle + access (needs vec0)',
      () {
    test('lifecycleEventCounts reflects persist + demote + promote deltas',
        () async {
      final store = await openStore();

      final before = await store.stats();

      await persistEvent(store, text: 'a', seed: 1, key: 'ev-a');
      await persistEvent(store, text: 'b', seed: 2, key: 'ev-b');
      final idC = await persistEvent(store, text: 'c', seed: 3, key: 'ev-c');

      await store.demote(idC, DemotionReason.prunerDecision);
      await store.promote(idC, PromotionReason.reconsolidation);

      final after = await store.stats();

      // Exactly the three persists + one demote + one promote this test
      // caused, regardless of bootstrap writes captured in `before`.
      expect(
        _delta(after.lifecycleEventCounts, before.lifecycleEventCounts,
            'memory.node-persisted'),
        equals(3),
      );
      expect(
        _delta(after.lifecycleEventCounts, before.lifecycleEventCounts,
            'memory.node-demoted'),
        equals(1),
      );
      expect(
        _delta(after.lifecycleEventCounts, before.lifecycleEventCounts,
            'memory.node-promoted'),
        equals(1),
      );
    });

    test('lifecycleEventCounts is exact immediately after promote (no race '
        'against the async events feed)', () async {
      final store = await openStore();
      final id = await persistEvent(store, text: 'x', seed: 9, key: 'ev-x');
      await store.demote(id, DemotionReason.prunerDecision);

      final beforePromote = await store.stats();
      await store.promote(id, PromotionReason.reconsolidation);
      // stats() read on the very next microtask — the synchronous tap
      // means the promote is already counted even though events() would
      // not yet have delivered it.
      final afterPromote = await store.stats();

      expect(
        _delta(afterPromote.lifecycleEventCounts,
            beforePromote.lifecycleEventCounts, 'memory.node-promoted'),
        equals(1),
      );
    });

    test('accessCountHistogram buckets the live corpus by access_count',
        () async {
      final store = await openStore();

      final before = await store.stats();

      final idA = await persistEvent(store, text: 'a', seed: 1, key: 'ev-a');
      final idB = await persistEvent(store, text: 'b', seed: 2, key: 'ev-b');
      // idC stays at access_count 0.
      await persistEvent(store, text: 'c', seed: 3, key: 'ev-c');

      // A accessed twice (→ count 2, bucket '1-2'), B once (→ '1-2').
      await store.recordAccess(<NodeId>[idA, idB], producer: 'answer:r1');
      await store.recordAccess(<NodeId>[idA], producer: 'answer:r2');

      final after = await store.stats();

      // Two nodes (A, B) entered the '1-2' bucket; one (C) entered '0'.
      expect(
        _delta(after.accessCountHistogram, before.accessCountHistogram, '1-2'),
        equals(2),
      );
      expect(
        _delta(after.accessCountHistogram, before.accessCountHistogram, '0'),
        equals(1),
      );
    });
  }, skip: skipNoBinary);
}
