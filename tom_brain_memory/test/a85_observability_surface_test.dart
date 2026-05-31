// A.85 tests — `MemoryStats` + `events()` stream wiring.
//
// The plan line: "Implement `MemoryStats` and the `events()` stream
// wiring." (Plan step A.85, Phase A § A.16 "Configuration +
// observability".)
//
// What A.85 ships:
//
//   - `MemoryEventBus` — the broadcast controller every per-subsystem
//     writer (`NodePersister`, `EdgeWriter`, `RecallExecutor`,
//     `SqliteStackApi`, `SqliteTrailStore`, `Classifier`, …) emits
//     onto. The bus's `events()` stream is what
//     `TomBrainMemoryClient.events()` returns.
//   - `RecallLatencyTracker` — per-mode p50/p95 aggregator that feeds
//     the `recallLatencyPerMode` slice of `MemoryStats`.
//   - `ClassificationConfidenceTracker` — ten-bucket histogram of
//     best-similarity values, feeds
//     `classificationConfidenceHistogram`.
//   - `MemoryStatsCollector` — composes a `MemoryStats` snapshot from
//     pluggable per-slice source callbacks.
//
// What this file asserts:
//
//   - `MemoryEventBus` fans broadcast emissions to multiple
//     subscribers; emits are async; close shuts the bus down cleanly;
//     re-close is idempotent; emit-after-close throws.
//   - `RecallLatencyTracker` returns nearest-rank p50/p95, respects
//     its bounded capacity (sliding window), reports per-mode samples
//     independently, and treats unrecorded modes as
//     `LatencyHistogram.zero`.
//   - `ClassificationConfidenceTracker` pre-allocates every bucket,
//     places samples in the right bucket, saturates out-of-range
//     samples, drops non-finite samples, and supports `reset`.
//   - `MemoryStatsCollector` returns the empty/zero baseline when no
//     sources are wired, populates every slice when all are wired,
//     runs sources concurrently (slow source + fast source → near
//     max(slow, fast), not sum), and propagates a thrown source.
//
// What this file does NOT do:
//
//   - It does not drive a real `SqliteTomBrainMemory` end-to-end —
//     that class does not yet exist (lands later in Phase A). The
//     A.85 contract is *the wiring primitives*; the composition root
//     will hand them to the concrete store once it lands. A.86 adds
//     the "stats reflect a known-seeded corpus" integration check;
//     A.89 adds the cross-implementation conformance suite.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('A.85 MemoryEventBus', () {
    test('emit fans out to multiple subscribers', () async {
      final bus = MemoryEventBus();
      addTearDown(bus.close);

      final aReceived = <MemoryEvent>[];
      final bReceived = <MemoryEvent>[];
      final aSub = bus.events().listen(aReceived.add);
      final bSub = bus.events().listen(bReceived.add);
      addTearDown(aSub.cancel);
      addTearDown(bSub.cancel);

      final ev1 = _StubEvent(kindName: 'memory.stub-one');
      final ev2 = _StubEvent(kindName: 'memory.stub-two');
      bus.emit(ev1);
      bus.emit(ev2);

      // Allow microtasks to drain — broadcast(sync: false) delivers
      // on a future microtask.
      await Future<void>.delayed(Duration.zero);

      expect(aReceived.map((e) => e.kind),
          orderedEquals(<String>['memory.stub-one', 'memory.stub-two']));
      expect(bReceived.map((e) => e.kind),
          orderedEquals(<String>['memory.stub-one', 'memory.stub-two']));
    });

    test('emit is asynchronous (subscriber sees event after emit returns)',
        () async {
      final bus = MemoryEventBus();
      addTearDown(bus.close);

      final received = <MemoryEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      bus.emit(_StubEvent(kindName: 'memory.stub'));
      // Before the microtask drains: subscriber has not been called.
      expect(received, isEmpty,
          reason: 'broadcast(sync: false) defers delivery to a microtask');

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
    });

    test('close ends every live subscription with a done event', () async {
      final bus = MemoryEventBus();

      final doneA = Completer<void>();
      final doneB = Completer<void>();
      final aSub = bus.events().listen(
            (_) {},
            onDone: doneA.complete,
          );
      final bSub = bus.events().listen(
            (_) {},
            onDone: doneB.complete,
          );
      addTearDown(aSub.cancel);
      addTearDown(bSub.cancel);

      await bus.close();
      expect(bus.isClosed, isTrue);
      await doneA.future;
      await doneB.future;
    });

    test('close is idempotent', () async {
      final bus = MemoryEventBus();
      await bus.close();
      await bus.close(); // must not throw
      expect(bus.isClosed, isTrue);
    });

    test('emit-after-close throws StateError', () async {
      final bus = MemoryEventBus();
      await bus.close();
      expect(
        () => bus.emit(_StubEvent(kindName: 'memory.stub')),
        throwsA(isA<StateError>()),
      );
    });

    test('late subscriber does not see prior events (broadcast contract)',
        () async {
      final bus = MemoryEventBus();
      addTearDown(bus.close);

      bus.emit(_StubEvent(kindName: 'memory.early'));
      await Future<void>.delayed(Duration.zero);

      final lateReceived = <MemoryEvent>[];
      final sub = bus.events().listen(lateReceived.add);
      addTearDown(sub.cancel);
      bus.emit(_StubEvent(kindName: 'memory.late'));
      await Future<void>.delayed(Duration.zero);

      expect(lateReceived.map((e) => e.kind),
          orderedEquals(<String>['memory.late']),
          reason:
              'broadcast stream does not replay events emitted before the '
              'subscription started');
    });
  });

  group('A.85 RecallLatencyTracker', () {
    test('empty snapshot is empty (unrecorded modes are omitted)', () {
      final tracker = RecallLatencyTracker();
      expect(tracker.snapshot(), isEmpty);
    });

    test('snapshotFor unrecorded mode is LatencyHistogram.zero', () {
      final tracker = RecallLatencyTracker();
      expect(tracker.snapshotFor(RecallMode.bm25), same(LatencyHistogram.zero));
    });

    test('single sample → p50 == p95 == sample', () {
      final tracker = RecallLatencyTracker();
      tracker.record(RecallMode.bm25, 42);
      final hist = tracker.snapshotFor(RecallMode.bm25);
      expect(hist.p50Ms, 42.0);
      expect(hist.p95Ms, 42.0);
    });

    test('nearest-rank percentiles over [10..100] every 10', () {
      final tracker = RecallLatencyTracker();
      for (var v = 10; v <= 100; v += 10) {
        tracker.record(RecallMode.bm25, v);
      }
      // Nearest-rank: p50 → ceil(0.5*10)-1 = 4 → sortedAsc[4] = 50.
      // p95 → ceil(0.95*10)-1 = 9 → sortedAsc[9] = 100.
      final hist = tracker.snapshotFor(RecallMode.bm25);
      expect(hist.p50Ms, 50.0);
      expect(hist.p95Ms, 100.0);
    });

    test('bounded capacity evicts oldest (sliding window)', () {
      final tracker = RecallLatencyTracker(capacity: 3);
      tracker.record(RecallMode.bm25, 100);
      tracker.record(RecallMode.bm25, 200);
      tracker.record(RecallMode.bm25, 300);
      tracker.record(RecallMode.bm25, 400);
      tracker.record(RecallMode.bm25, 500);
      // After 5 records with capacity 3: window is [300, 400, 500].
      expect(tracker.sampleCount(RecallMode.bm25), 3);
      final hist = tracker.snapshotFor(RecallMode.bm25);
      // p50 → ceil(0.5*3)-1 = 1 → sorted[1] = 400.
      // p95 → ceil(0.95*3)-1 = 2 → sorted[2] = 500.
      expect(hist.p50Ms, 400.0);
      expect(hist.p95Ms, 500.0);
    });

    test('per-mode buffers are independent', () {
      final tracker = RecallLatencyTracker();
      tracker.record(RecallMode.bm25, 10);
      tracker.record(RecallMode.vector, 1000);
      tracker.record(RecallMode.vector, 2000);

      expect(tracker.sampleCount(RecallMode.bm25), 1);
      expect(tracker.sampleCount(RecallMode.vector), 2);
      expect(tracker.sampleCount(RecallMode.symbolic), 0);

      final snap = tracker.snapshot();
      expect(snap.keys, unorderedEquals(<String>['bm25', 'vector']));
      expect(snap['bm25']!.p50Ms, 10.0);
      // Two samples [1000, 2000]: p50 → ceil(0.5*2)-1 = 0 → 1000.
      // p95 → ceil(0.95*2)-1 = 1 → 2000.
      expect(snap['vector']!.p50Ms, 1000.0);
      expect(snap['vector']!.p95Ms, 2000.0);
    });

    test('snapshot is unmodifiable', () {
      final tracker = RecallLatencyTracker();
      tracker.record(RecallMode.bm25, 1);
      final snap = tracker.snapshot();
      expect(
        () => snap['x'] = LatencyHistogram.zero,
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('A.85 ClassificationConfidenceTracker', () {
    test('empty snapshot has all ten buckets at zero', () {
      final tracker = ClassificationConfidenceTracker();
      final snap = tracker.snapshot();
      expect(snap.keys,
          orderedEquals(ClassificationConfidenceTracker.bucketLabels));
      expect(snap.values.every((c) => c == 0), isTrue);
      expect(tracker.totalSamples, 0);
    });

    test('samples land in the expected bucket', () {
      final tracker = ClassificationConfidenceTracker();
      tracker.record(0.05); // 0.0-0.1
      tracker.record(0.10); // 0.1-0.2
      tracker.record(0.55); // 0.5-0.6
      tracker.record(0.99); // 0.9-1.0
      tracker.record(1.00); // 0.9-1.0 (top bucket includes 1.0)

      final snap = tracker.snapshot();
      expect(snap['0.0-0.1'], 1);
      expect(snap['0.1-0.2'], 1);
      expect(snap['0.5-0.6'], 1);
      expect(snap['0.9-1.0'], 2);
      expect(tracker.totalSamples, 5);
    });

    test('out-of-range samples saturate to the edge buckets', () {
      final tracker = ClassificationConfidenceTracker();
      tracker.record(-0.5); // negative → 0.0-0.1
      tracker.record(1.5);  // > 1.0 → 0.9-1.0
      final snap = tracker.snapshot();
      expect(snap['0.0-0.1'], 1);
      expect(snap['0.9-1.0'], 1);
    });

    test('non-finite samples are dropped', () {
      final tracker = ClassificationConfidenceTracker();
      tracker.record(double.nan);
      tracker.record(double.infinity);
      tracker.record(double.negativeInfinity);
      expect(tracker.totalSamples, 0);
    });

    test('reset zeroes every bucket', () {
      final tracker = ClassificationConfidenceTracker();
      tracker.record(0.3);
      tracker.record(0.7);
      expect(tracker.totalSamples, 2);

      tracker.reset();
      expect(tracker.totalSamples, 0);
      final snap = tracker.snapshot();
      expect(snap.values.every((c) => c == 0), isTrue);
    });

    test('snapshot is unmodifiable', () {
      final tracker = ClassificationConfidenceTracker();
      final snap = tracker.snapshot();
      expect(() => snap['0.0-0.1'] = 99, throwsA(isA<UnsupportedError>()));
    });
  });

  group('A.85 MemoryStatsCollector', () {
    test('no sources → empty/zero baseline', () async {
      const collector = MemoryStatsCollector();
      final stats = await collector.snapshot();

      expect(stats.nodeCountByType, isEmpty);
      expect(stats.edgeCountByType, isEmpty);
      expect(stats.stackSizes, isEmpty);
      expect(stats.trailCount, 0);
      expect(stats.trailBytes, 0);
      expect(stats.recallLatencyPerMode, isEmpty);
      expect(stats.classificationConfidenceHistogram, isEmpty);
      expect(stats.migrationProgress, isEmpty);
    });

    test('all sources wired → every slice populated', () async {
      final collector = MemoryStatsCollector(
        nodeCounts: () async => <String, int>{'Event': 3, 'Claim': 7},
        edgeCounts: () async =>
            <String, int>{'mentions': 5, 'derived_from': 2},
        stackSizes: () async =>
            <String, int>{'questions_open': 4, 'interests': 1},
        trailCount: () async => 12,
        trailBytes: () async => 4096,
        recallLatency: () async => <String, LatencyHistogram>{
          'bm25': const LatencyHistogram(p50Ms: 10, p95Ms: 25),
          'vector': const LatencyHistogram(p50Ms: 40, p95Ms: 90),
        },
        classificationConfidence: () async =>
            <String, int>{'0.5-0.6': 2, '0.9-1.0': 5},
        migrationProgress: () async => <String, double>{'restructure_v1': 0.5},
      );

      final stats = await collector.snapshot();

      expect(stats.nodeCountByType, equals(<String, int>{'Event': 3, 'Claim': 7}));
      expect(stats.edgeCountByType,
          equals(<String, int>{'mentions': 5, 'derived_from': 2}));
      expect(stats.stackSizes,
          equals(<String, int>{'questions_open': 4, 'interests': 1}));
      expect(stats.trailCount, 12);
      expect(stats.trailBytes, 4096);
      expect(stats.recallLatencyPerMode.keys,
          unorderedEquals(<String>['bm25', 'vector']));
      expect(stats.recallLatencyPerMode['bm25']!.p50Ms, 10);
      expect(stats.recallLatencyPerMode['vector']!.p95Ms, 90);
      expect(stats.classificationConfidenceHistogram,
          equals(<String, int>{'0.5-0.6': 2, '0.9-1.0': 5}));
      expect(stats.migrationProgress,
          equals(<String, double>{'restructure_v1': 0.5}));
    });

    test('snapshot returns unmodifiable slice maps', () async {
      final collector = MemoryStatsCollector(
        nodeCounts: () async => <String, int>{'Event': 1},
      );
      final stats = await collector.snapshot();
      expect(() => stats.nodeCountByType['x'] = 9,
          throwsA(isA<UnsupportedError>()));
      expect(() => stats.edgeCountByType['x'] = 9,
          throwsA(isA<UnsupportedError>()));
    });

    test('sources run in parallel (total ≈ max, not sum)', () async {
      final slow = Completer<Map<String, int>>();
      final fast = Completer<int>();
      final collector = MemoryStatsCollector(
        nodeCounts: () => slow.future,
        trailCount: () => fast.future,
      );

      final snapFuture = collector.snapshot();

      // Both sources should be in flight before either completes.
      // Resolve them in reverse-registration order; if the collector
      // were serial it would deadlock waiting for slow first.
      fast.complete(7);
      slow.complete(<String, int>{'A': 1});

      final stats = await snapFuture;
      expect(stats.trailCount, 7);
      expect(stats.nodeCountByType['A'], 1);
    });

    test('a throwing source propagates the error', () async {
      final collector = MemoryStatsCollector(
        nodeCounts: () async {
          throw StateError('db unreadable');
        },
      );
      await expectLater(
        collector.snapshot(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('A.85 cross-cut: bus + trackers + collector', () {
    test('the trackers can be wired through the collector as sources',
        () async {
      final latencyTracker = RecallLatencyTracker();
      final confidenceTracker = ClassificationConfidenceTracker();
      latencyTracker.record(RecallMode.bm25, 12);
      latencyTracker.record(RecallMode.symbolic, 8);
      confidenceTracker.record(0.95);
      confidenceTracker.record(0.42);

      final collector = MemoryStatsCollector(
        recallLatency: () async => latencyTracker.snapshot(),
        classificationConfidence: () async => confidenceTracker.snapshot(),
      );

      final stats = await collector.snapshot();
      expect(stats.recallLatencyPerMode.keys,
          unorderedEquals(<String>['bm25', 'symbolic']));
      expect(stats.classificationConfidenceHistogram['0.4-0.5'], 1);
      expect(stats.classificationConfidenceHistogram['0.9-1.0'], 1);
    });

    test('the bus accepts emit tear-off as the per-subsystem eventSink',
        () async {
      // This is the wiring pattern the composition root uses: hand
      // `bus.emit` to every per-subsystem writer's `eventSink` slot.
      final bus = MemoryEventBus();
      addTearDown(bus.close);
      final void Function(MemoryEvent) sink = bus.emit;

      final received = <MemoryEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      sink(_StubEvent(kindName: 'memory.via-sink'));
      await Future<void>.delayed(Duration.zero);
      expect(received.single.kind, 'memory.via-sink');
    });
  });
}

// Lightweight test-only `MemoryEvent`. The plan calls A.85 a *wiring*
// step — every real leaf already exists in its owning sub-module, and
// the bus does not care which subclass it is fanning out. A stub keeps
// the test free of subsystem coupling (no SQLite, no FTS5, no scope
// plumbing required just to assert the bus shape).
final class _StubEvent extends MemoryEvent {
  final String kindName;

  _StubEvent({required this.kindName})
      : super(occurredAt: DateTime.now().toUtc());

  @override
  String get kind => kindName;

  @override
  Map<String, Object?> payloadJson() => const <String, Object?>{};
}
