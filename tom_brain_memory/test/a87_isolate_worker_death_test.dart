// A.87 — worker-death send-failure + per-request deadline on the
// memory isolate boundary (completion-plan item 10 / CS-003 D).
//
// What this file locks:
//
//   1. Killing the worker isolate mid-call fails the pending `send()`
//      with a typed `IsolateRequestFailure(workerDeath)` — the host no
//      longer hangs on the kernel worker's never-completed completer.
//      After the kill `host.isWorkerDead` is `true`.
//   2. A per-request deadline (`requestTimeout`) fails a hanging call
//      with `IsolateRequestFailure(timeout)` while the worker is still
//      alive — a slow worker does not hang the host either.
//   3. The guard is transparent on the happy path: a healthy call
//      round-trips normally and leaves the host reporting a live worker.
//
// The fakes hang inside `stats()` (a never-completing future) so the
// in-isolate dispatch genuinely blocks, exercising the real boundary
// rather than a host-side stub. The worker-death wiring under test is
// the `Isolate.addOnExitListener` installed by
// `TomBrainMemoryIsolateHost.spawn`.

import 'dart:async';
import 'dart:isolate';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateRequestFailure, IsolateRequestFailureReason;
import 'package:test/test.dart';

// ─── Top-level fakes + factories (must be top-level to be sendable) ──

Future<TomBrainMemory> spawnHangingMemoryForA87() async => _HangingFakeMemory();

Future<TomBrainMemory> spawnHealthyMemoryForA87() async => _HealthyFakeMemory();

/// A fake whose `stats()` never completes, so a `MemoryStatsRequest`
/// genuinely blocks inside the worker isolate.
final class _HangingFakeMemory implements TomBrainMemory {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<MemoryStats> stats() => Completer<MemoryStats>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_HangingFakeMemory.${invocation.memberName}: not used by A.87.',
      );
}

/// A fake whose `stats()` returns immediately — proves the guard is
/// transparent on the happy path.
final class _HealthyFakeMemory implements TomBrainMemory {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_HealthyFakeMemory.${invocation.memberName}: not used by A.87.',
      );
}

MemoryConfig _fakeConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a87_fake_unused',
    );

void main() {
  group('A.87 isolate worker-death send-failure', () {
    test(
      'killing the worker mid-call fails the pending send with workerDeath',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnHangingMemoryForA87);
        addTearDown(host.shutdown);
        await host.spawn();
        await host.openMemory(_fakeConfig());

        // Issue a call that blocks forever inside the isolate.
        final pending = host.send<MemoryStatsResponse>(
          const MemoryStatsRequest(),
        );
        // Let the command reach the isolate before we kill it.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(host.isWorkerDead, isFalse);

        host.workerIsolate!.kill(priority: Isolate.immediate);

        await expectLater(
          pending,
          throwsA(
            isA<IsolateRequestFailure>().having(
              (f) => f.reason,
              'reason',
              IsolateRequestFailureReason.workerDeath,
            ),
          ),
        );
        expect(host.isWorkerDead, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  group('A.87 per-request deadline', () {
    test(
      'a hanging call fails with timeout while the worker stays alive',
      () async {
        final host = TomBrainMemoryIsolateHost(
          factory: spawnHangingMemoryForA87,
          requestTimeout: const Duration(milliseconds: 150),
        );
        addTearDown(host.shutdown);
        await host.spawn();
        await host.openMemory(_fakeConfig());

        await expectLater(
          host.send<MemoryStatsResponse>(const MemoryStatsRequest()),
          throwsA(
            isA<IsolateRequestFailure>().having(
              (f) => f.reason,
              'reason',
              IsolateRequestFailureReason.timeout,
            ),
          ),
        );
        // A deadline is not a death — the worker is still alive.
        expect(host.isWorkerDead, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  group('A.87 guard transparency', () {
    test('a healthy call round-trips normally under the guard', () async {
      final host = TomBrainMemoryIsolateHost(
        factory: spawnHealthyMemoryForA87,
        requestTimeout: const Duration(seconds: 30),
      );
      addTearDown(host.shutdown);
      await host.spawn();
      await host.openMemory(_fakeConfig());

      final response =
          await host.send<MemoryStatsResponse>(const MemoryStatsRequest());
      expect(response.stats.trailCount, equals(0));
      expect(host.isWorkerDead, isFalse);
    });
  });
}
