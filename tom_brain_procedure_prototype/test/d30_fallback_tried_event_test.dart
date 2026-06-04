// D.30 — `FallbackTried` event emission tests.
//
// Covers the event the `FallbackExecutor` emits on every fallback-class
// failure (PE-6, def § 6: "Every fallback emits a fallback event"):
//
//   - the `FallbackTried` event shape — `kind`, `payloadJson`,
//     `surfaced`, `toJson` (base-field threading, UTC assertion);
//   - the executor emits exactly one event per fallback-class failure: a
//     step-down carries `toVersion` (`surfaced: false`); a fallback-class
//     failure on the oldest version surfaces (`toVersion: null`,
//     `surfaced: true`) — the only shape the singleton prototype chain
//     produces;
//   - non-fallback failures (environmental / outside the four classes) and
//     successes emit nothing;
//   - no sink wired is a no-op (no crash);
//   - `runId` / `causedBy` thread onto every emitted event, and an injected
//     clock stamps `occurredAt`.
//
// `FallbackTried` is the single fallback event — both the executor's
// `FallbackEventSink` emission and the closed-taxonomy `DispatcherEvent`
// variant (the earlier duplicate `ProcedureFallback` + its copy factory were
// collapsed away, Q-D.30.1 / Q-D.49.2).
//
// As in the D.29 tests, the executor's *what-a-version-does* is a synthetic
// `VersionAttempt`, so these tests stay independent of the engine.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

/// A typed failure carrying an explicit [failureKind].
final class _ClassifiedError implements Exception, ClassifiedFailure {
  const _ClassifiedError(this.failureKind);
  @override
  final String failureKind;
}

/// A failure caused by the environment (substrate-down, network, billing).
final class _EnvError implements Exception, EnvironmentalFailure {
  const _EnvError();
}

/// A plain, unmarked error — an uncaught crash mid-run.
final class _PlainError implements Exception {
  const _PlainError();
}

LoadedProcedure _loaded(String id, int version) => LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: ProcedureHeader(
        id: id,
        version: version,
        summary: 'summary of $id v$version',
        successCriterion: 'it works',
        budget: ProcedureBudget(const {'wallClockMs': 1000}),
      ),
      source: '/// @procedure\n/// id: $id\n/// version: $version\n// body',
    );

ProcedureResolver _resolver(String id, List<int> versions) =>
    ProcedureResolver([for (final v in versions) _loaded(id, v)]);

void main() {
  group('FallbackTried event shape', () {
    final occurredAt = DateTime.utc(2026, 6, 2, 10, 30);

    test('a step-down event carries toVersion and is not surfaced', () {
      final event = FallbackTried(
        occurredAt: occurredAt,
        runId: 'r_1',
        causedBy: 'ev_0',
        procedureId: 'answer_v',
        fromVersion: 3,
        toVersion: 2,
        trigger: FallbackTrigger.contractViolation,
      );
      expect(event.surfaced, isFalse);
      expect(event.kind, 'dispatcher.fallback-tried');
      expect(event.payloadJson(), <String, Object?>{
        'procedureId': 'answer_v',
        'fromVersion': 3,
        'toVersion': 2,
        'trigger': 'procedure.contract.violation',
        'surfaced': false,
      });
    });

    test('a surfaced event omits toVersion and marks surfaced', () {
      final event = FallbackTried(
        occurredAt: occurredAt,
        procedureId: 'answer_v',
        fromVersion: 1,
        toVersion: null,
        trigger: FallbackTrigger.runtimeCrash,
      );
      expect(event.surfaced, isTrue);
      final payload = event.payloadJson();
      expect(payload.containsKey('toVersion'), isFalse);
      expect(payload['surfaced'], isTrue);
      expect(payload['trigger'], 'procedure.runtime.crash');
    });

    test('toJson threads the base fields and asserts UTC', () {
      final event = FallbackTried(
        occurredAt: occurredAt,
        runId: 'r_1',
        causedBy: 'ev_0',
        procedureId: 'answer_v',
        fromVersion: 2,
        toVersion: 1,
        trigger: FallbackTrigger.deadlineExceeded,
      );
      final json = event.toJson();
      expect(json['kind'], 'dispatcher.fallback-tried');
      expect(json['occurredAt'], occurredAt.toIso8601String());
      expect(json['runId'], 'r_1');
      expect(json['causedBy'], 'ev_0');
      expect(json['payload'], isA<Map<String, Object?>>());
    });
  });

  group('FallbackExecutor emission — single-version chain (prototype shape)',
      () {
    test('a fallback-class failure on v1 emits one surfaced event', () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1]),
        onFallback: events.add,
      );
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async =>
            throw const _ClassifiedError('procedure.contract.violation'),
      );
      expect(outcome.isSuccess, isFalse);
      expect(events, hasLength(1));
      final event = events.single;
      expect(event.procedureId, 'answer_v');
      expect(event.fromVersion, 1);
      expect(event.toVersion, isNull);
      expect(event.surfaced, isTrue);
      expect(event.trigger, FallbackTrigger.contractViolation);
    });

    test('a successful run emits no event', () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1]),
        onFallback: events.add,
      );
      await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async => 'ok',
      );
      expect(events, isEmpty);
    });

    test('an environmental failure emits no event', () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1]),
        onFallback: events.add,
      );
      await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async => throw const _EnvError(),
      );
      expect(events, isEmpty);
    });

    test('a non-fallback classified failure emits no event', () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1]),
        onFallback: events.add,
      );
      await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async =>
            throw const _ClassifiedError('procedure.budget.exceeded'),
      );
      expect(events, isEmpty);
    });

    test('no sink wired is a no-op (no crash)', () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1]));
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async => throw const _PlainError(),
      );
      expect(outcome.isSuccess, isFalse);
    });
  });

  group('FallbackExecutor emission — multi-version chain', () {
    test('each step-down emits a step event; the last surfaces', () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1, 2, 3]),
        onFallback: events.add,
      );
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          if (version.header.version == 3) {
            throw const _ClassifiedError('procedure.contract.violation');
          }
          if (version.header.version == 2) {
            throw const _PlainError(); // runtime crash
          }
          throw const _ClassifiedError('procedure.critique.rejected');
        },
      );
      expect(outcome.isSuccess, isFalse);
      expect(events, hasLength(3));

      // v3 → v2 (step-down)
      expect(events[0].fromVersion, 3);
      expect(events[0].toVersion, 2);
      expect(events[0].surfaced, isFalse);
      expect(events[0].trigger, FallbackTrigger.contractViolation);

      // v2 → v1 (step-down)
      expect(events[1].fromVersion, 2);
      expect(events[1].toVersion, 1);
      expect(events[1].surfaced, isFalse);
      expect(events[1].trigger, FallbackTrigger.runtimeCrash);

      // v1 → surfaced (oldest version, nowhere to step)
      expect(events[2].fromVersion, 1);
      expect(events[2].toVersion, isNull);
      expect(events[2].surfaced, isTrue);
      expect(events[2].trigger, FallbackTrigger.critiqueRejected);
    });

    test('a version that succeeds mid-chain emits only the prior step events',
        () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1, 2, 3]),
        onFallback: events.add,
      );
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          if (version.header.version == 3) {
            throw const _ClassifiedError('procedure.deadline.exceeded');
          }
          return 'from-v2';
        },
      );
      expect(outcome.isSuccess, isTrue);
      expect(outcome.value, 'from-v2');
      // Only the v3 → v2 step-down emitted; v2 succeeded so no surfaced event.
      expect(events, hasLength(1));
      expect(events.single.fromVersion, 3);
      expect(events.single.toVersion, 2);
      expect(events.single.surfaced, isFalse);
    });

    test('an environmental failure on the newest version emits no event',
        () async {
      final events = <FallbackTried>[];
      final executor = FallbackExecutor(
        _resolver('answer_v', [1, 2, 3]),
        onFallback: events.add,
      );
      await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async => throw const _EnvError(),
      );
      expect(events, isEmpty);
    });
  });

  group('FallbackExecutor emission — base-field threading', () {
    test('runId / causedBy and the injected clock stamp every event', () async {
      final events = <FallbackTried>[];
      final stamp = DateTime.utc(2026, 6, 2, 12);
      final executor = FallbackExecutor(
        _resolver('answer_v', [1, 2]),
        onFallback: events.add,
        clock: () => stamp,
      );
      await executor.run<String>(
        procedureId: 'answer_v',
        runId: 'run_42',
        causedBy: 'ev_root',
        attempt: (_) async =>
            throw const _ClassifiedError('procedure.runtime.crash'),
      );
      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.runId, 'run_42');
        expect(event.causedBy, 'ev_root');
        expect(event.occurredAt, stamp);
        expect(event.occurredAt.isUtc, isTrue);
      }
    });
  });
}
