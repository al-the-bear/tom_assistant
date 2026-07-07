// UB5 (the first real consumer of the deferred typed family, § 12.1 decision 4)
// — the shared creation vocabulary (`creation_specification.md` § 9.1).
//
// Pins the `CreationEvent` sealed family — twelve leaves, the `kind`
// discriminators match `creationEventKinds` in order, the UTC + payload
// contract, the `creationId` correlation, and the non-negative count guards.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('CreationEvent', () {
    final at = DateTime.utc(2026, 6, 1, 12);

    test('every leaf kind appears in creationEventKinds, in order', () {
      final leaves = <CreationEvent>[
        CreationRequested(
          occurredAt: at,
          intent: 'write a CSV exporter',
          successCriterion: 'golden test passes',
          target: 'lib/exporter.dart',
        ),
        EnvironmentObserved(occurredAt: at, targetCount: 2),
        TestDrafted(occurredAt: at, testTarget: 'test/exporter_test.dart'),
        TestRun(occurredAt: at, failedOrSkipped: true, outcome: 'failed'),
        DraftProduced(occurredAt: at, iteration: 0),
        DraftWritten(occurredAt: at, iteration: 0, target: 'lib/exporter.dart'),
        PostObservationCaptured(occurredAt: at, iteration: 0, targetCount: 2),
        SuccessChecked(occurredAt: at, iteration: 0, satisfied: true),
        CritiqueProduced(occurredAt: at, accepted: true, iteration: 0),
        CreationAccepted(
            occurredAt: at, target: 'lib/exporter.dart', iterations: 1),
        CreationRolledBack(occurredAt: at, iteration: 1, incomplete: false),
        ScopeViolation(
            occurredAt: at, tool: 'file.write', attemptedPath: '/etc/passwd'),
      ];
      expect(leaves.map((e) => e.kind).toList(), creationEventKinds);
    });

    test('creationEventKinds has twelve entries, all unique', () {
      expect(creationEventKinds, hasLength(12));
      expect(creationEventKinds.toSet(), hasLength(12));
    });

    test('toJson carries kind + payload and omits null correlation', () {
      final json = EnvironmentObserved(occurredAt: at, targetCount: 3).toJson();
      expect(json['kind'], 'creation.environment-observed');
      expect(json.containsKey('runId'), isFalse);
      expect((json['payload'] as Map)['targetCount'], 3);
      expect((json['payload'] as Map).containsKey('creationId'), isFalse);
    });

    test('creationId correlates events through the payload', () {
      final accepted = CreationAccepted(
        occurredAt: at,
        target: 'lib/x.dart',
        iterations: 2,
        creationId: 'ART-9',
      );
      expect((accepted.toJson()['payload'] as Map)['creationId'], 'ART-9');
    });

    test('CreationRequested carries intent + success criterion', () {
      final json = CreationRequested(
        occurredAt: at,
        intent: 'make a thing',
        successCriterion: 'it compiles',
      ).toJson();
      final payload = json['payload'] as Map;
      expect(payload['intent'], 'make a thing');
      expect(payload['successCriterion'], 'it compiles');
      expect(payload.containsKey('target'), isFalse);
    });

    test('rejects a non-UTC occurredAt on serialise', () {
      final local = DateTime(2026, 6, 1, 12);
      expect(
        () => CreationRequested(
          occurredAt: local,
          intent: 'x',
          successCriterion: 'y',
        ).toJson(),
        throwsArgumentError,
      );
    });

    test('EnvironmentObserved rejects a negative count', () {
      expect(
        () => EnvironmentObserved(occurredAt: at, targetCount: -1),
        throwsArgumentError,
      );
    });

    test('PostObservationCaptured rejects a negative count', () {
      expect(
        () => PostObservationCaptured(
            occurredAt: at, iteration: 0, targetCount: -1),
        throwsArgumentError,
      );
    });
  });
}
