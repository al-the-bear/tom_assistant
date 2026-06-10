// A.81 — Message protocol: envelope catalogue + cancellation tokens
// for `recall` / `stream` + backpressure for `readTrail`.
//
// Per Q-A.81.2 the step ships:
//
//   * The protocol *shape* for every stream-returning method
//     (open envelope + chunk envelope + control envelopes).
//   * End-to-end wiring for `readTrail` (backpressure proof) and
//     `events` (cancellation proof) through a real isolate.
//
// The generic mechanism unit tests (`IsolateCancellationRegistry`,
// `IsolateCancellationToken`, `BackpressureTracker`, …) moved to
// `tom_core_agentic/test/isolate_streaming_test.dart` when that
// machinery was promoted to `tom_core_agentic` (Tom Brain
// completion-plan item 7). This file keeps the memory-coupled envelope
// shapes and the isolate round-trip proofs.
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
  group('A.81 StreamIdAllocator', () {
    test('hands out monotonic ids', () {
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

    test('StreamId value equality', () {
      expect(const StreamId(7), equals(const StreamId(7)));
      expect(const StreamId(7), isNot(equals(const StreamId(8))));
    });
  });
}
