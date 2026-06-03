// D.29 — FallbackExecutor unit tests.
//
// Covers the version-chain walk (PE-6, def § 6):
//
//   - `FallbackTrigger.forKind` maps the four wire strings and rejects
//     anything else;
//   - `defaultFallbackClassifier` routes environmental / classified /
//     unmarked failures correctly, and recognises the real
//     `RunDeadlineExceeded` failure type;
//   - the executor's chain walk: success on the first version, stepping down
//     on fallback-class failures, surfacing on the oldest version, *not*
//     stepping on environmental / non-fallback failures, and the
//     unknown-id `ProcedureNotFound` branch;
//   - the `FallbackOutcome` shape: ordered attempts, `valueOrThrow`,
//     `fallbackFailures`.
//
// The executor's *what-a-version-does* is supplied by a synthetic
// `VersionAttempt`, so these tests stay independent of the engine; only the
// chain-walk policy is under test.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

/// A typed failure carrying an explicit [failureKind] (e.g. a contract
/// violation surfaced by a run).
final class _ClassifiedError implements Exception, ClassifiedFailure {
  const _ClassifiedError(this.failureKind);
  @override
  final String failureKind;
}

/// A failure caused by the environment (substrate-down, network, billing).
final class _EnvError implements Exception, EnvironmentalFailure {
  const _EnvError(this.message);
  final String message;
}

/// A plain, unmarked error — the kind an uncaught crash mid-run throws.
final class _PlainError implements Exception {
  const _PlainError();
}

/// Builds a [LoadedProcedure] with a minimal valid header for [id]/[version],
/// mirroring the resolver-test helper so the chain walk runs over real
/// `LoadedProcedure`s.
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

/// A resolver holding versions [versions] of [id].
ProcedureResolver _resolver(String id, List<int> versions) =>
    ProcedureResolver([for (final v in versions) _loaded(id, v)]);

void main() {
  group('FallbackTrigger.forKind', () {
    test('maps the four fallback-class wire strings', () {
      expect(FallbackTrigger.forKind('procedure.contract.violation'),
          FallbackTrigger.contractViolation);
      expect(FallbackTrigger.forKind('procedure.critique.rejected'),
          FallbackTrigger.critiqueRejected);
      expect(FallbackTrigger.forKind('procedure.deadline.exceeded'),
          FallbackTrigger.deadlineExceeded);
      expect(FallbackTrigger.forKind('procedure.runtime.crash'),
          FallbackTrigger.runtimeCrash);
    });

    test('returns null for a non-fallback kind', () {
      expect(FallbackTrigger.forKind('procedure.budget.exceeded'), isNull);
      expect(FallbackTrigger.forKind('substrate.down'), isNull);
      expect(FallbackTrigger.forKind(''), isNull);
    });
  });

  group('defaultFallbackClassifier', () {
    test('an environmental failure never triggers fallback', () {
      expect(defaultFallbackClassifier(const _EnvError('substrate down')),
          isNull);
    });

    test('a classified fallback-class failure maps to its trigger', () {
      expect(
        defaultFallbackClassifier(
            const _ClassifiedError('procedure.contract.violation')),
        FallbackTrigger.contractViolation,
      );
      expect(
        defaultFallbackClassifier(
            const _ClassifiedError('procedure.critique.rejected')),
        FallbackTrigger.critiqueRejected,
      );
    });

    test('a classified non-fallback failure surfaces (null)', () {
      expect(
        defaultFallbackClassifier(
            const _ClassifiedError('procedure.budget.exceeded')),
        isNull,
      );
    });

    test('an unmarked error is a runtime crash', () {
      expect(defaultFallbackClassifier(const _PlainError()),
          FallbackTrigger.runtimeCrash);
    });

    test('a source-parse failure never triggers fallback (Q-C.46.1)', () {
      // A syntactically broken source is not a runtime crash: an older
      // version cannot repair the break, so the chain must not be stepped.
      expect(
        defaultFallbackClassifier(
            const ProcedureSourceParseException('parse error')),
        isNull,
      );
    });

    test('the real RunDeadlineExceeded classifies as deadlineExceeded', () {
      const error =
          RunDeadlineExceeded(RunSlot.foreground, Duration(seconds: 65));
      expect(error.failureKind, 'procedure.deadline.exceeded');
      expect(defaultFallbackClassifier(error), FallbackTrigger.deadlineExceeded);
    });
  });

  group('FallbackExecutor.run — single-version chain (prototype shape)', () {
    test('a version that succeeds ends the walk with its value', () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1]));
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          expect(version.header.version, 1);
          return 'answer';
        },
      );
      expect(outcome.isSuccess, isTrue);
      expect(outcome.value, 'answer');
      expect(outcome.valueOrThrow, 'answer');
      expect(outcome.versionsAttempted, 1);
      expect(outcome.attempts.single.succeeded, isTrue);
      expect(outcome.fallbackFailures, isEmpty);
    });

    test('a fallback-class failure on the only version surfaces (D.30 shape)',
        () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1]));
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (_) async =>
            throw const _ClassifiedError('procedure.contract.violation'),
      );
      expect(outcome.isSuccess, isFalse);
      expect(outcome.error, isA<_ClassifiedError>());
      expect(outcome.versionsAttempted, 1);
      // The failure was a fallback-class one — it had nowhere to step.
      final attempt = outcome.attempts.single;
      expect(attempt.succeeded, isFalse);
      expect(attempt.trigger, FallbackTrigger.contractViolation);
      expect(outcome.fallbackFailures, hasLength(1));
      expect(() => outcome.valueOrThrow, throwsA(isA<_ClassifiedError>()));
    });
  });

  group('FallbackExecutor.run — multi-version chain', () {
    test('steps down newest-first until a version succeeds', () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1, 2, 3]));
      final triedVersions = <int>[];
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          triedVersions.add(version.header.version);
          if (version.header.version == 3) {
            throw const _ClassifiedError('procedure.contract.violation');
          }
          if (version.header.version == 2) {
            throw const _PlainError(); // runtime crash
          }
          return 'from-v1';
        },
      );
      // Walked v3 → v2 → v1 in newest-first order.
      expect(triedVersions, [3, 2, 1]);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.value, 'from-v1');
      expect(outcome.versionsAttempted, 3);
      expect(
        outcome.attempts.map((a) => a.version).toList(),
        [3, 2, 1],
      );
      expect(outcome.attempts[0].trigger, FallbackTrigger.contractViolation);
      expect(outcome.attempts[1].trigger, FallbackTrigger.runtimeCrash);
      expect(outcome.attempts[2].succeeded, isTrue);
      expect(outcome.fallbackFailures, hasLength(2));
    });

    test('surfaces the oldest version\'s failure when the whole chain fails',
        () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1, 2]));
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          if (version.header.version == 2) {
            throw const _ClassifiedError('procedure.runtime.crash');
          }
          throw const _ClassifiedError('procedure.contract.violation');
        },
      );
      expect(outcome.isSuccess, isFalse);
      // The surfaced error is the *oldest* (v1) failure.
      expect((outcome.error as _ClassifiedError).failureKind,
          'procedure.contract.violation');
      expect(outcome.versionsAttempted, 2);
      expect(outcome.fallbackFailures, hasLength(2));
    });

    test('an environmental failure does NOT step down, even with older versions',
        () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1, 2, 3]));
      final triedVersions = <int>[];
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          triedVersions.add(version.header.version);
          throw const _EnvError('network down');
        },
      );
      // Only the newest version was attempted — the environment is not fixable
      // by an older procedure version.
      expect(triedVersions, [3]);
      expect(outcome.isSuccess, isFalse);
      expect(outcome.error, isA<_EnvError>());
      expect(outcome.versionsAttempted, 1);
      expect(outcome.attempts.single.trigger, isNull);
      expect(outcome.fallbackFailures, isEmpty);
    });

    test('a non-fallback classified failure does NOT step down', () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1, 2]));
      final triedVersions = <int>[];
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          triedVersions.add(version.header.version);
          throw const _ClassifiedError('procedure.budget.exceeded');
        },
      );
      expect(triedVersions, [2]);
      expect(outcome.isSuccess, isFalse);
      expect(outcome.versionsAttempted, 1);
      expect(outcome.attempts.single.trigger, isNull);
    });

    test('the first version succeeding short-circuits the chain', () async {
      final executor = FallbackExecutor(_resolver('answer_v', [1, 2, 3]));
      final triedVersions = <int>[];
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          triedVersions.add(version.header.version);
          return 'v3-answer';
        },
      );
      expect(triedVersions, [3]);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.value, 'v3-answer');
      expect(outcome.versionsAttempted, 1);
    });
  });

  group('FallbackExecutor.run — error branches', () {
    test('an unknown procedure id throws ProcedureNotFound', () {
      final executor = FallbackExecutor(_resolver('answer_v', [1]));
      expect(
        () => executor.run<String>(
          procedureId: 'nope_v',
          attempt: (_) async => 'never',
        ),
        throwsA(isA<ProcedureNotFound>()),
      );
    });

    test('a custom classifier overrides the default', () async {
      // A classifier that treats *everything* as non-fallback: even a runtime
      // crash surfaces immediately.
      final executor = FallbackExecutor(
        _resolver('answer_v', [1, 2]),
        classifier: (_) => null,
      );
      final triedVersions = <int>[];
      final outcome = await executor.run<String>(
        procedureId: 'answer_v',
        attempt: (version) async {
          triedVersions.add(version.header.version);
          throw const _PlainError();
        },
      );
      expect(triedVersions, [2]);
      expect(outcome.isSuccess, isFalse);
    });
  });
}
