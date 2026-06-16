// A.80 — TomBrainMemoryIsolateClient.
//
// Exercises the thin client that wraps a `TomBrainMemoryIsolateHost`
// and implements `TomBrainMemoryClient`. Two layers of assertions:
//
//   1. Conformance — the client is a `TomBrainMemoryClient` and
//      compiles against the interface without `noSuchMethod` or
//      dynamic dispatch.
//   2. Wired surface (at A.80) — methods whose envelope exists in
//      A.79's skeleton (`open`, `close`, `stats`) round-trip
//      through a real isolate and a top-level fake `TomBrainMemory`.
//
// The "unwired surface" group that lived here at A.80 has been
// removed at A.82 along with `EnvelopeNotWiredError` — every method
// is now wired and the full round-trip is verified by
// `a82_full_catalogue_test.dart`.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:test/test.dart';

// ─── Top-level fake + factory (must be top-level to be sendable) ──

Future<TomBrainMemory> spawnFakeMemoryForA80() async {
  return _IsolateSideFakeMemory();
}

Future<TomBrainMemory> spawnRichFakeMemoryForA80() async {
  return _IsolateSideFakeMemory.rich();
}

final class _IsolateSideFakeMemory implements TomBrainMemory {
  final MemoryStats _statsPayload;

  _IsolateSideFakeMemory() : _statsPayload = MemoryStats.empty;

  _IsolateSideFakeMemory.rich()
      : _statsPayload = const MemoryStats(
          nodeCountByType: <String, int>{'Event': 11, 'Concept': 22},
          edgeCountByType: <String, int>{'mentions': 33},
          stackSizes: <String, int>{'questions_open': 4},
          trailCount: 5,
          trailBytes: 2048,
          recallLatencyPerMode: <String, LatencyHistogram>{},
          classificationConfidenceHistogram: <String, int>{},
          migrationProgress: <String, double>{},
          lifecycleEventCounts: <String, int>{
            'memory.node-persisted': 7,
            'memory.node-promoted': 2,
          },
          accessCountHistogram: <String, int>{'0': 6, '1-2': 3},
        );

  // Methods A.79 dispatches.
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<MemoryStats> stats() async => _statsPayload;

  // Everything else is unreachable from A.79's envelope skeleton, so
  // we route through `noSuchMethod` rather than re-implement each
  // method by hand.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
        '_IsolateSideFakeMemory.${invocation.memberName}: '
        'not used by A.80 (only open/close/stats are wired).',
      );
}

MemoryConfig _fakeConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a80_fake_unused',
    );

// ─── Tests ────────────────────────────────────────────────────────

void main() {
  group('A.80 TomBrainMemoryIsolateClient — conformance', () {
    test('implements TomBrainMemoryClient', () {
      final host =
          TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
      final client = TomBrainMemoryIsolateClient(host);
      // Compile-time + runtime check.
      expect(client, isA<TomBrainMemoryClient>());
      // Deliberately *not* a TomBrainMemory (the in-process marker).
      expect(client, isNot(isA<TomBrainMemory>()));
    });

    test('client does not own the host lifecycle', () async {
      // The host is constructed but never spawned; constructing the
      // client must not throw and must not spawn the host on the
      // caller's behalf.
      final host =
          TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
      final client = TomBrainMemoryIsolateClient(host);
      expect(host.isReady, isFalse);
      expect(host.isClosed, isFalse);
      // Calling a wired method without a spawned host must throw —
      // the client must not silently spawn behind the caller's back.
      expect(() => client.stats(), throwsStateError);
    });
  });

  group('A.80 TomBrainMemoryIsolateClient — wired surface', () {
    test('open() drives the in-isolate memory.open()', () async {
      final host =
          TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        expect(host.isMemoryOpen, isFalse);
        await client.open(_fakeConfig());
        expect(host.isMemoryOpen, isTrue);
      } finally {
        await host.shutdown();
      }
    });

    test('close() drives the in-isolate memory.close()', () async {
      final host =
          TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());
        expect(host.isMemoryOpen, isTrue);
        await client.close();
        expect(host.isMemoryOpen, isFalse);
      } finally {
        await host.shutdown();
      }
    });

    test('stats() round-trips the snapshot from the in-isolate memory',
        () async {
      final host =
          TomBrainMemoryIsolateHost(factory: spawnRichFakeMemoryForA80);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());
        final stats = await client.stats();
        expect(stats.nodeCountByType, equals({'Event': 11, 'Concept': 22}));
        expect(stats.edgeCountByType, equals({'mentions': 33}));
        expect(stats.stackSizes, equals({'questions_open': 4}));
        expect(stats.trailCount, equals(5));
        expect(stats.trailBytes, equals(2048));
        expect(
          stats.lifecycleEventCounts,
          equals({'memory.node-persisted': 7, 'memory.node-promoted': 2}),
        );
        expect(stats.accessCountHistogram, equals({'0': 6, '1-2': 3}));
      } finally {
        await host.shutdown();
      }
    });

    test(
      'stats() before open() surfaces the in-isolate StateError as '
      'IsolateBoundaryException',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
        final client = TomBrainMemoryIsolateClient(host);
        try {
          await host.spawn();
          await expectLater(
            client.stats(),
            throwsA(
              isA<IsolateBoundaryException>().having(
                (e) => e.exceptionType,
                'exceptionType',
                'StateError',
              ),
            ),
          );
        } finally {
          await host.shutdown();
        }
      },
    );
  });

}
