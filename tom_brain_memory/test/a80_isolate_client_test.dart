// A.80 — TomBrainMemoryIsolateClient.
//
// Exercises the thin client that wraps a `TomBrainMemoryIsolateHost`
// and implements `TomBrainMemoryClient`. Three layers of assertions:
//
//   1. Conformance — the client is a `TomBrainMemoryClient` and
//      compiles against the interface without `noSuchMethod` or
//      dynamic dispatch.
//   2. Wired surface — methods whose envelope exists in A.79's
//      skeleton (`open`, `close`, `stats`) round-trip through a
//      real isolate and a top-level fake `TomBrainMemory`.
//   3. Unwired surface — every other method throws
//      `EnvelopeNotWiredError` with the right method name. Tested
//      for the methods whose signatures take primitive arguments;
//      methods with rich argument types (`persist`, `edge`,
//      `registerNodeType`, `recall`, `openTrail`, `appendTrail`,
//      `closeTrail`) are covered by the catalogue test once A.81
//      ships their envelopes — pulling those into A.80 would couple
//      this test to schemas owned by other modules. Stream-returning
//      methods (`stream`, `readTrail`, `events`) surface the error
//      on the stream itself; the proxy-returned sub-APIs (`stacks`,
//      `migrations`) raise the same error on every method.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, Vec, WriteBudget;
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

  group('A.80 TomBrainMemoryIsolateClient — unwired surface', () {
    late TomBrainMemoryIsolateHost host;
    late TomBrainMemoryIsolateClient client;

    setUp(() async {
      host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA80);
      client = TomBrainMemoryIsolateClient(host);
      await host.spawn();
      // The unwired methods must throw `EnvelopeNotWiredError`
      // regardless of memory state — they never reach the host. We
      // open memory so any accidental dispatch would surface as a
      // different error (which the test would catch as a type
      // mismatch).
      await client.open(_fakeConfig());
    });

    tearDown(() async {
      await host.shutdown();
    });

    Matcher throwsEnvelopeNotWired(String method, {String step = 'A.82'}) {
      return throwsA(
        isA<EnvelopeNotWiredError>()
            .having((e) => e.method, 'method', method)
            .having((e) => e.step, 'step', step),
      );
    }

    Matcher streamErrorsEnvelopeNotWired(String method) {
      return emitsError(
        isA<EnvelopeNotWiredError>().having((e) => e.method, 'method', method),
      );
    }

    // ─── Future-returning methods with primitive arguments ───────
    //
    // Methods whose signatures take rich types (`persist`, `edge`,
    // `registerNodeType`, `recall`, `openTrail`, `appendTrail`,
    // `closeTrail`) are covered when A.81 lands their envelopes —
    // see the file header for the rationale.

    test('checkpoint()', () {
      expect(client.checkpoint(), throwsEnvelopeNotWired('checkpoint'));
    });

    test('beginRun()', () {
      expect(
        client.beginRun(
          runId: 'r',
          budget: WriteBudget(maxNodes: 1, maxEdges: 1, maxStackEntries: 1),
        ),
        throwsEnvelopeNotWired('beginRun'),
      );
    });

    test('endRun()', () {
      expect(client.endRun('r'), throwsEnvelopeNotWired('endRun'));
    });

    test('remainingBudget()', () {
      expect(
        client.remainingBudget('r'),
        throwsEnvelopeNotWired('remainingBudget'),
      );
    });

    test('get()', () {
      expect(client.get(NodeId.generate()), throwsEnvelopeNotWired('get'));
    });

    test('getMany()', () {
      expect(
        client.getMany(const <NodeId>[]),
        throwsEnvelopeNotWired('getMany'),
      );
    });

    test('demote()', () {
      expect(
        client.demote(NodeId.generate(), DemotionReason.retentionHorizon),
        throwsEnvelopeNotWired('demote'),
      );
    });

    test('forget()', () {
      expect(
        client.forget(NodeId.generate(), ForgetReason.userRequested),
        throwsEnvelopeNotWired('forget'),
      );
    });

    test('edgesOf()', () {
      expect(
        client.edgesOf(NodeId.generate()),
        throwsEnvelopeNotWired('edgesOf'),
      );
    });

    test('listNodeTypes()', () {
      expect(client.listNodeTypes(), throwsEnvelopeNotWired('listNodeTypes'));
    });

    test('getNodeType()', () {
      expect(client.getNodeType('x'), throwsEnvelopeNotWired('getNodeType'));
    });

    test('classify()', () {
      expect(
        client.classify(Vec.fromList(const <double>[0.1, 0.2])),
        throwsEnvelopeNotWired('classify'),
      );
    });

    test('updateCentroid()', () {
      expect(
        client.updateCentroid('x', Vec.fromList(const <double>[0.1, 0.2])),
        throwsEnvelopeNotWired('updateCentroid'),
      );
    });

    test('findUncertain()', () {
      expect(
        client.findUncertain(forKey: 'x', low: 0.1, high: 0.5),
        throwsEnvelopeNotWired('findUncertain'),
      );
    });

    // ─── Stream-returning methods ────────────────────────────────
    //
    // `readTrail()` and `events()` were unwired at A.80; A.81 wires
    // them end-to-end (backpressure proof + cancellation proof
    // respectively). The remaining stream-returning methods
    // (`stream`, `stacks.streamArchived`, `stacks.events`) stay
    // unwired until A.82.

    test('stream() surfaces error on the stream itself', () {
      expect(
        client.stream(
          const StreamQuery(filter: SymbolicFilter()),
        ),
        streamErrorsEnvelopeNotWired('stream'),
      );
    });

    // ─── Stack proxy ─────────────────────────────────────────────

    test('stacks getter returns a usable proxy', () {
      final stacks = client.stacks;
      expect(stacks, isA<StackApi>());
      // The same proxy is returned on subsequent calls (lazy cache).
      expect(identical(client.stacks, stacks), isTrue);
    });

    test('stacks.list()', () {
      expect(client.stacks.list(), throwsEnvelopeNotWired('stacks.list'));
    });

    test('stacks.push()', () {
      expect(
        client.stacks.push('s', NodeId.generate()),
        throwsEnvelopeNotWired('stacks.push'),
      );
    });

    test('stacks.events() surfaces error on the stream itself', () {
      expect(
        client.stacks.events('s'),
        streamErrorsEnvelopeNotWired('stacks.events'),
      );
    });

    // ─── Migration proxy ─────────────────────────────────────────

    test('migrations getter returns a usable proxy', () {
      final migrations = client.migrations;
      expect(migrations, isA<MigrationApi>());
      expect(identical(client.migrations, migrations), isTrue);
    });

    test('migrations.listInProgress()', () {
      expect(
        client.migrations.listInProgress(),
        throwsEnvelopeNotWired('migrations.listInProgress'),
      );
    });
  });
}
