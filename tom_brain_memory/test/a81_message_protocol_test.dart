// A.81 — Message protocol: envelope catalogue + cancellation tokens
// for `recall` / `stream` + backpressure for `readTrail`.
//
// Per Q-A.81.2 the step ships:
//
//   * The protocol *shape* for every stream-returning method
//     (open envelope + chunk envelope + control envelopes).
//   * End-to-end wiring for `readTrail` (backpressure proof) and
//     `events` (cancellation proof) through a real isolate.
//   * Mechanism unit tests for `CancellationRegistry` and
//     `BackpressureTracker`.
//
// The remaining streams (`stream`, `stacks.streamArchived`,
// `stacks.events`) and every non-streaming non-primitive method
// land at A.82. The A.80 unwired-surface test already pins them.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show TrailId;
import 'package:test/test.dart';

// ─── Top-level fake + factory (must be top-level to be sendable) ──

/// Per the dispatcher-test convention used at A.80, the
/// in-isolate fake is constructed by a top-level factory so that
/// `Isolate.spawn` can capture it.
Future<TomBrainMemory> spawnFakeMemoryForA81() async {
  return _IsolateSideFakeMemoryA81();
}

final class _IsolateSideFakeMemoryA81 implements TomBrainMemory {
  // A short, deterministic trail (5 entries) so the backpressure
  // proof can reason about pauses with low credit budgets.
  static final List<TrailEntry> _trail = <TrailEntry>[
    TrailEntry.invocation(const <String, Object?>{'i': 0}),
    TrailEntry.note('one'),
    TrailEntry.note('two'),
    TrailEntry.note('three'),
    TrailEntry.note('four'),
  ];

  // The events stream is *unbounded*: we emit one TrailOpened
  // every 5 ms until cancelled. This is the cancellation proof —
  // the test cancels after seeing N events and asserts the stream
  // closes.
  final StreamController<MemoryEvent> _eventsController =
      StreamController<MemoryEvent>.broadcast();
  Timer? _ticker;

  _IsolateSideFakeMemoryA81() {
    _ticker = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (_eventsController.isClosed) return;
      _eventsController.add(
        TrailOpened(
          trailId: TrailId.generate(),
          runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r'),
          jsonlPath: '/tmp/fake',
          openedAt: DateTime.now().toUtc(),
          occurredAt: DateTime.now().toUtc(),
        ),
      );
    });
  }

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {
    _ticker?.cancel();
    if (!_eventsController.isClosed) await _eventsController.close();
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) async* {
    for (final e in _trail) {
      yield e;
    }
  }

  @override
  Stream<MemoryEvent> events() => _eventsController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_IsolateSideFakeMemoryA81.${invocation.memberName}: '
        'not used by A.81 (only readTrail/events/open/close are wired).',
      );
}

MemoryConfig _fakeConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a81_fake_unused',
    );

// ─── Tests ────────────────────────────────────────────────────────

void main() {
  group('A.81 CancellationRegistry', () {
    test('register then cancel flips the flag', () {
      final reg = CancellationRegistry();
      final tok = const CancellationToken(1);
      final h = reg.register(tok);
      expect(h.isCancelled, isFalse);
      reg.cancel(tok);
      expect(h.isCancelled, isTrue);
      expect(reg.isCancelled(tok), isTrue);
    });

    test('cancel-before-register is remembered (late-cancel race)', () {
      final reg = CancellationRegistry();
      final tok = const CancellationToken(2);
      reg.cancel(tok);
      expect(reg.pendingCancelCount, equals(1));
      final h = reg.register(tok);
      expect(h.isCancelled, isTrue,
          reason: 'register must consume the pending cancel');
      expect(reg.pendingCancelCount, equals(0));
    });

    test('throwIfCancelled raises CancellationException with the token', () {
      final reg = CancellationRegistry();
      final tok = const CancellationToken(3);
      final h = reg.register(tok);
      h.throwIfCancelled(); // does nothing
      reg.cancel(tok);
      expect(
        h.throwIfCancelled,
        throwsA(
          isA<CancellationException>()
              .having((e) => e.token.id, 'token.id', 3),
        ),
      );
    });

    test('dispose is idempotent and unregisters', () {
      final reg = CancellationRegistry();
      final tok = const CancellationToken(4);
      final h = reg.register(tok);
      expect(reg.inFlightCount, equals(1));
      h.dispose();
      expect(reg.inFlightCount, equals(0));
      h.dispose(); // idempotent
      expect(reg.inFlightCount, equals(0));
    });

    test('cancel on unknown then register elsewhere does not leak', () {
      final reg = CancellationRegistry();
      reg.cancel(const CancellationToken(10));
      reg.cancel(const CancellationToken(11));
      expect(reg.pendingCancelCount, equals(2));
      reg.register(const CancellationToken(10));
      expect(reg.pendingCancelCount, equals(1));
    });
  });

  group('A.81 BackpressureTracker', () {
    test('awaitCredit returns immediately when credits > 0', () async {
      final t = BackpressureTracker(initialCredits: 3);
      await t.awaitCredit();
      expect(t.credits, equals(3));
      t.consume();
      expect(t.credits, equals(2));
    });

    test('awaitCredit parks at zero and unblocks on grant', () async {
      final t = BackpressureTracker(initialCredits: 1);
      t.consume();
      expect(t.credits, equals(0));
      var unblocked = false;
      final f = t.awaitCredit().then((_) => unblocked = true);
      // Yield so the await actually parks.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(unblocked, isFalse);
      expect(t.waiterCount, equals(1));
      t.grant(1);
      await f;
      expect(unblocked, isTrue);
      expect(t.waiterCount, equals(0));
    });

    test('grant wakes parked waiters', () async {
      // The protocol's intended use is one producer per tracker, so
      // we never see more than one waiter at a time in production.
      // But the tracker is robust against being shared: a single
      // grant releases every parked waiter because credits stay
      // positive until the producer's `consume` call drains them.
      final t = BackpressureTracker(initialCredits: 0);
      final order = <int>[];
      final f1 = t.awaitCredit().then((_) => order.add(1));
      final f2 = t.awaitCredit().then((_) => order.add(2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(t.waiterCount, equals(2));
      t.grant(2);
      await Future.wait([f1, f2]);
      // FIFO wake order: f1 completed before f2.
      expect(order, equals(<int>[1, 2]));
      expect(t.waiterCount, equals(0));
    });

    test('consume rejects negative and over-consume', () {
      final t = BackpressureTracker(initialCredits: 1);
      expect(() => t.consume(-1), throwsArgumentError);
      expect(() => t.consume(2), throwsStateError);
    });

    test('close fails parked waiters', () async {
      final t = BackpressureTracker(initialCredits: 0);
      final f = t.awaitCredit();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      t.close();
      expect(t.isClosed, isTrue);
      await expectLater(f, throwsStateError);
    });
  });

  group('A.81 Allocators', () {
    test('CancellationTokenAllocator hands out monotonic ids', () {
      final a = CancellationTokenAllocator();
      expect(a.next().id, equals(1));
      expect(a.next().id, equals(2));
      expect(a.peekNext, equals(3));
    });

    test('StreamIdAllocator hands out monotonic ids', () {
      final a = StreamIdAllocator();
      expect(a.next().id, equals(1));
      expect(a.next().id, equals(2));
      expect(a.peekNext, equals(3));
    });
  });

  group('A.81 readTrail backpressure round-trip', () {
    test(
      'readTrail streams all entries with default initialCredits',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA81);
        final client = TomBrainMemoryIsolateClient(host);
        try {
          await host.spawn();
          await client.open(_fakeConfig());
          final entries = await client.readTrail(TrailId.generate()).toList();
          expect(entries, hasLength(5));
          expect(entries.first.kind, equals(TrailEntryKind.invocation));
          expect(entries.last.kind, equals(TrailEntryKind.note));
        } finally {
          await host.shutdown();
        }
      },
    );

    test(
      'low initialCredits forces the producer to pause and resume',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA81);
        try {
          await host.spawn();
          await host.openMemory(_fakeConfig());
          final streamId = host.streamIdAllocator.next();
          // Open with credits = 2; the fake has 5 entries. The
          // executor must push 2 then pause, and only resume once we
          // pull more credits.
          final raw = host.openStream<TrailEntry>(
            OpenReadTrailStreamRequest(
              streamId: streamId,
              trailId: TrailId.generate(),
              initialCredits: 2,
            ),
            streamId: streamId,
          );
          final received = <TrailEntry>[];
          final sub = raw.listen(received.add);
          // Give the executor time to push the credit budget.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(received.length, equals(2),
              reason:
                  'producer must pause at the credit ceiling — only the '
                  'initial 2 chunks should have arrived');
          // Pull two more — producer resumes, sends 2, pauses again.
          await host.pullCredits(streamId, 2);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(received.length, equals(4));
          // Pull the final one — producer drains and completes.
          await host.pullCredits(streamId, 1);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(received.length, equals(5));
          await sub.cancel();
        } finally {
          await host.shutdown();
        }
      },
    );
  });

  group('A.81 events cancellation round-trip', () {
    test(
      'events streams chunks then closes on consumer subscription cancel',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA81);
        final client = TomBrainMemoryIsolateClient(host);
        try {
          await host.spawn();
          await client.open(_fakeConfig());
          final received = <MemoryEvent>[];
          final completer = Completer<void>();
          late StreamSubscription<MemoryEvent> sub;
          sub = client.events().listen((e) async {
            received.add(e);
            if (received.length == 3) {
              await sub.cancel();
              completer.complete();
            }
          });
          await completer.future.timeout(const Duration(seconds: 5));
          expect(received.length, equals(3));
          // Allow the cancel-roundtrip to settle.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(host.liveStreamCount, equals(0),
              reason: 'host sink must be torn down after consumer cancel');
        } finally {
          await host.shutdown();
        }
      },
    );

    test(
      'host.cancel(token) on an open events stream terminates it',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA81);
        try {
          await host.spawn();
          await host.openMemory(_fakeConfig());
          final token = host.cancellationAllocator.next();
          final streamId = host.streamIdAllocator.next();
          final raw = host.openStream<MemoryEvent>(
            OpenEventsStreamRequest(
              streamId: streamId,
              cancellation: token,
            ),
            streamId: streamId,
          );
          final received = <MemoryEvent>[];
          final done = Completer<void>();
          raw.listen(received.add, onDone: done.complete);
          // Wait for a couple of chunks.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(received.length, greaterThan(0));
          // Fire cancellation — the producer should observe the flag
          // and emit the terminal envelope.
          await host.cancel(token);
          await done.future.timeout(const Duration(seconds: 5));
        } finally {
          await host.shutdown();
        }
      },
    );
  });

  group('A.81 envelope shapes (sendability surface)', () {
    test('StreamPullRequest rejects non-positive credits', () {
      expect(
        () => StreamPullRequest(
          streamId: const StreamId(1),
          credits: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('OpenReadTrailStreamRequest rejects non-positive initialCredits', () {
      expect(
        () => OpenReadTrailStreamRequest(
          streamId: const StreamId(1),
          trailId: TrailId.generate(),
          initialCredits: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('CancellationToken value equality', () {
      expect(const CancellationToken(7), equals(const CancellationToken(7)));
      expect(const CancellationToken(7),
          isNot(equals(const CancellationToken(8))));
    });

    test('StreamId value equality', () {
      expect(const StreamId(7), equals(const StreamId(7)));
      expect(const StreamId(7), isNot(equals(const StreamId(8))));
    });
  });
}
