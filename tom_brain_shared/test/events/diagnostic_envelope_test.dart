// Tests for `DiagnosticEnvelope` (Plan step A.14).
//
// Surface under test:
//   * Construction with required event/source/sequence + defaulted
//     severity (info) + defaulted tags (empty).
//   * Generic narrowing: `DiagnosticEnvelope<_FixtureEvent>` keeps the
//     event statically typed.
//   * Negative `sequence` is rejected by assert.
//   * Empty `source` is rejected by assert.
//   * `tags` getter returns an unmodifiable view; mutation attempts throw.
//   * `toJson` includes source/sequence/severity/event; omits empty tags;
//     includes non-empty tags as a fresh map.
//   * Tags passed at construction are reflected through the getter.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

final class _FixtureEvent extends BrainEvent {
  final String label;

  _FixtureEvent({
    required this.label,
    required super.occurredAt,
  });

  @override
  String get kind => 'fixture.test-event';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{'label': label};
}

DiagnosticEnvelope<_FixtureEvent> _envelope({
  String source = 'tom_brain_memory',
  int sequence = 0,
  DiagnosticSeverity severity = DiagnosticSeverity.info,
  Map<String, String> tags = const {},
}) =>
    DiagnosticEnvelope<_FixtureEvent>(
      event: _FixtureEvent(
        label: 'fx',
        occurredAt: DateTime.utc(2026, 5, 30, 14, 22, 33, 123),
      ),
      source: source,
      sequence: sequence,
      severity: severity,
      tags: tags,
    );

void main() {
  group('DiagnosticEnvelope construction', () {
    test('required fields flow through', () {
      final env = _envelope(source: 'tom_brain_substrate', sequence: 42);

      expect(env.source, equals('tom_brain_substrate'));
      expect(env.sequence, equals(42));
      expect(env.event.kind, equals('fixture.test-event'));
    });

    test('severity defaults to info', () {
      final env = _envelope();
      expect(env.severity, equals(DiagnosticSeverity.info));
    });

    test('tags default to empty', () {
      final env = _envelope();
      expect(env.tags, isEmpty);
    });

    test('generic preserves event subtype statically', () {
      final env = _envelope();
      // Compile-time check: event is a _FixtureEvent, not just BrainEvent.
      // ignore: unnecessary_type_check
      expect(env.event is _FixtureEvent, isTrue);
      expect(env.event.label, equals('fx'));
    });

    test('non-default severity carries through', () {
      final env = _envelope(severity: DiagnosticSeverity.warning);
      expect(env.severity, equals(DiagnosticSeverity.warning));
    });
  });

  group('DiagnosticEnvelope validation', () {
    test('rejects negative sequence', () {
      expect(
        () => _envelope(sequence: -1),
        throwsArgumentError,
      );
    });

    test('rejects empty source', () {
      expect(
        () => _envelope(source: ''),
        throwsArgumentError,
      );
    });

    test('accepts zero sequence', () {
      final env = _envelope(sequence: 0);
      expect(env.sequence, equals(0));
    });
  });

  group('DiagnosticEnvelope.tags', () {
    test('returns an unmodifiable view', () {
      final env = _envelope(tags: {'host': 'bomber'});
      expect(
        () => env.tags['host'] = 'mutated',
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('reflects the constructor tags', () {
      final env = _envelope(tags: {'host': 'bomber', 'shard': 'a'});
      expect(env.tags['host'], equals('bomber'));
      expect(env.tags['shard'], equals('a'));
      expect(env.tags, hasLength(2));
    });
  });

  group('DiagnosticEnvelope.toJson', () {
    test('includes source, sequence, severity name, and event', () {
      final env = _envelope(
        source: 'tom_brain_memory',
        sequence: 7,
        severity: DiagnosticSeverity.warning,
      );

      final json = env.toJson();

      expect(json['source'], equals('tom_brain_memory'));
      expect(json['sequence'], equals(7));
      expect(json['severity'], equals('warning'));
      expect(json['event'], isA<Map<String, Object?>>());
    });

    test('omits tags when empty', () {
      final env = _envelope();
      expect(env.toJson().containsKey('tags'), isFalse);
    });

    test('includes tags when non-empty', () {
      final env = _envelope(tags: {'host': 'bomber', 'shard': 'a'});
      final json = env.toJson();

      expect(json['tags'], equals({'host': 'bomber', 'shard': 'a'}));
    });

    test('tags in json are a copy — mutating json does not affect envelope',
        () {
      final env = _envelope(tags: {'host': 'bomber'});
      final json = env.toJson();
      final jsonTags = json['tags'] as Map<String, String>;

      jsonTags['host'] = 'mutated';
      // Envelope's view remains the original.
      expect(env.tags['host'], equals('bomber'));
    });

    test('event payload is delegated to the event itself', () {
      final env = _envelope();
      final json = env.toJson();
      final eventJson = json['event'] as Map<String, Object?>;

      expect(eventJson['kind'], equals('fixture.test-event'));
      expect(
        (eventJson['payload'] as Map<String, Object?>)['label'],
        equals('fx'),
      );
    });
  });
}
