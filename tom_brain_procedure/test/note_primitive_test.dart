// C.20 — engine-native `note` primitive (Dart-level unit tests).
//
// Drives `NotePrimitive` and the `TrailNote` value directly, off the d4rt
// boundary. The companion `native_primitives_installer_test.dart` proves
// the d4rt-facing half (a script calling `note(...)` reaches the sink).
//
// These tests pin: the primitive forwards a TrailNote carrying the call's
// category + payload to the injected sink; the payload is defensively
// copied (mutating the caller's map afterwards does not change the
// recorded note, and the recorded note itself is unmodifiable); the
// injected clock stamps `recordedAt`; an empty category is rejected; and
// the `automation_candidate` well-known category constant has the wire
// value the harvester keys on.

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('NotePrimitive', () {
    test('forwards a TrailNote with the call category + payload to the sink',
        () {
      final notes = <TrailNote>[];
      final primitive = NotePrimitive(sink: notes.add);

      primitive.note('automation_candidate', <String, Object?>{
        'why': 'repeated prompt',
        'count': 3,
      });

      expect(notes, hasLength(1));
      expect(notes.single.category, 'automation_candidate');
      expect(notes.single.payload['why'], 'repeated prompt');
      expect(notes.single.payload['count'], 3);
    });

    test('defensively copies the payload — mutating the source after the '
        'call does not change the recorded note', () {
      final notes = <TrailNote>[];
      final primitive = NotePrimitive(sink: notes.add);

      final payload = <String, Object?>{'n': 1};
      primitive.note('cat', payload);
      payload['n'] = 2;
      payload['extra'] = 'late';

      expect(notes.single.payload['n'], 1);
      expect(notes.single.payload.containsKey('extra'), isFalse);
    });

    test('stamps recordedAt from the injected clock', () {
      final notes = <TrailNote>[];
      final fixed = DateTime.utc(2026, 6, 1, 12, 30);
      final primitive = NotePrimitive(sink: notes.add, now: () => fixed);

      primitive.note('cat', const <String, Object?>{});

      expect(notes.single.recordedAt, fixed);
    });

    test('forwards notes to the sink in call order', () {
      final notes = <TrailNote>[];
      final primitive = NotePrimitive(sink: notes.add);

      primitive.note('first', const <String, Object?>{'n': 1});
      primitive.note('second', const <String, Object?>{'n': 2});

      expect(
        notes.map((n) => n.category).toList(),
        <String>['first', 'second'],
      );
    });

    test('rejects an empty category', () {
      final primitive = NotePrimitive(sink: (_) {});

      expect(
        () => primitive.note('', const <String, Object?>{}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('TrailNote', () {
    test('exposes an unmodifiable payload view', () {
      final note = TrailNote(
        category: 'cat',
        recordedAt: DateTime.utc(2026, 6, 1),
        payload: <String, Object?>{'a': 1},
      );

      expect(() => note.payload['b'] = 2, throwsUnsupportedError);
    });

    test('defaults to an empty payload', () {
      final note = TrailNote(
        category: 'cat',
        recordedAt: DateTime.utc(2026, 6, 1),
      );

      expect(note.payload, isEmpty);
    });

    test('rejects an empty category', () {
      expect(
        () => TrailNote(category: '', recordedAt: DateTime.utc(2026, 6, 1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toString names the category and payload keys', () {
      final note = TrailNote(
        category: 'automation_candidate',
        recordedAt: DateTime.utc(2026, 6, 1),
        payload: <String, Object?>{'why': 'x'},
      );

      expect(note.toString(), contains('automation_candidate'));
      expect(note.toString(), contains('why'));
    });
  });

  test('automationCandidateCategory has the harvester wire value', () {
    expect(automationCandidateCategory, 'automation_candidate');
  });
}
