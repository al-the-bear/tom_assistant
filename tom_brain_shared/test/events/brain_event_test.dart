// Tests for `BrainEvent` (Plan step A.14).
//
// Surface under test:
//   * Subclassing pattern: a concrete subclass can be declared with extra
//     payload fields and a stable `kind` discriminator.
//   * Base fields (`occurredAt`, `runId`, `causedBy`) flow through `super`
//     and are visible on subclass instances.
//   * `toJson` composition: `kind` + `occurredAt` (ISO 8601 UTC) +
//     conditional `runId` + conditional `causedBy` + `payload`.
//   * Null-omission rule for `runId` / `causedBy`.
//   * Subclass `payloadJson()` is the only source of payload contents.
//   * UTC assertion fires (in checked mode) for non-UTC `occurredAt`.
//   * `payloadJson()` returns a fresh map per call — mutating the result
//     does not affect a second call.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Minimal concrete subclass used as the test fixture. Mirrors the
/// pattern that `MemoryEvent` subclasses will use at A.38.
final class _FixtureEvent extends BrainEvent {
  final String message;
  final int count;

  _FixtureEvent({
    required this.message,
    required this.count,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'fixture.test-event';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'message': message,
        'count': count,
      };
}

void main() {
  group('BrainEvent subclassing', () {
    test('subclass exposes super-constructed base fields', () {
      final t = DateTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final e = _FixtureEvent(
        message: 'hello',
        count: 3,
        occurredAt: t,
        runId: 'r_01J',
        causedBy: 'ev_01J',
      );

      expect(e.occurredAt, equals(t));
      expect(e.runId, equals('r_01J'));
      expect(e.causedBy, equals('ev_01J'));
      expect(e.message, equals('hello'));
      expect(e.count, equals(3));
      expect(e.kind, equals('fixture.test-event'));
    });

    test('runId and causedBy are nullable on the base', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 1,
        occurredAt: DateTime.utc(2026, 1, 1),
      );

      expect(e.runId, isNull);
      expect(e.causedBy, isNull);
    });
  });

  group('BrainEvent.toJson', () {
    test('includes kind, ISO 8601 UTC timestamp, and payload', () {
      final t = DateTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final e = _FixtureEvent(
        message: 'hello',
        count: 3,
        occurredAt: t,
      );

      final json = e.toJson();

      expect(json['kind'], equals('fixture.test-event'));
      expect(
        json['occurredAt'],
        equals('2026-05-30T14:22:33.123Z'),
        reason: 'UTC ISO 8601 with trailing Z',
      );
      expect(
        json['payload'],
        equals(<String, Object?>{'message': 'hello', 'count': 3}),
      );
    });

    test('omits runId and causedBy when null', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
      );

      final json = e.toJson();

      expect(json.containsKey('runId'), isFalse);
      expect(json.containsKey('causedBy'), isFalse);
    });

    test('includes runId when set', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
        runId: 'r_01J',
      );

      expect(e.toJson()['runId'], equals('r_01J'));
      expect(e.toJson().containsKey('causedBy'), isFalse);
    });

    test('includes causedBy when set', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
        causedBy: 'ev_01J',
      );

      expect(e.toJson()['causedBy'], equals('ev_01J'));
      expect(e.toJson().containsKey('runId'), isFalse);
    });

    test('includes both runId and causedBy when both set', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
        runId: 'r_01J',
        causedBy: 'ev_01J',
      );

      final json = e.toJson();

      expect(json['runId'], equals('r_01J'));
      expect(json['causedBy'], equals('ev_01J'));
    });

    test('toJson rejects a non-UTC occurredAt', () {
      // A local-time instant must never ride the observability wire — it
      // corrupts cross-component trace ordering — so toJson throws (in
      // release builds too), not asserts.
      final localTime = DateTime(2026, 5, 30, 14, 22, 33);
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: localTime,
      );

      expect(() => e.toJson(), throwsArgumentError);
    });

    test('payloadJson returns a fresh map per call', () {
      final e = _FixtureEvent(
        message: 'm',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
      );

      final first = e.payloadJson();
      first['mutation'] = 'should-not-persist';

      final second = e.payloadJson();
      expect(second.containsKey('mutation'), isFalse);
      expect(
        second,
        equals(<String, Object?>{'message': 'm', 'count': 0}),
      );
    });

    test('toJson includes the subclass payload verbatim', () {
      final e = _FixtureEvent(
        message: 'subclass-data',
        count: 99,
        occurredAt: DateTime.utc(2026, 1, 1),
      );

      final json = e.toJson();
      final payload = json['payload'] as Map<String, Object?>;

      expect(payload['message'], equals('subclass-data'));
      expect(payload['count'], equals(99));
    });
  });

  group('kind discriminator', () {
    test('subclass declares a stable kind string', () {
      final e1 = _FixtureEvent(
        message: 'a',
        count: 0,
        occurredAt: DateTime.utc(2026, 1, 1),
      );
      final e2 = _FixtureEvent(
        message: 'b',
        count: 9,
        occurredAt: DateTime.utc(2026, 2, 1),
      );

      // Different instances, same kind.
      expect(e1.kind, equals(e2.kind));
      expect(e1.kind, equals('fixture.test-event'));
    });
  });
}
