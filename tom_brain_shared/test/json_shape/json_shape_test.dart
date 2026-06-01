// Unit tests for `JsonShape` (Plan step B.44).
//
// `JsonShape` is the pure-function namespace extracted at the B.44
// reuse-extraction pass. The tests pin every helper against the
// three relevant shape buckets:
//
//   1. correct shape  -> returns the typed value
//   2. missing key    -> returns the documented fallback / null
//   3. wrong type     -> returns the documented fallback / null
//                        (never throws, except for the `require*`
//                        helpers which do throw `JsonShapeException`)
//
// The substrate's HTTP clients consume these helpers at the LLM
// wire layer; B.14 and B.15 integration tests already exercise the
// real wire paths, so the responsibility here is purely the
// function semantics — not the substrate-side decode flow.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('JsonShape (B.44 — reuse extraction)', () {
    group('readString', () {
      test('returns the string when present', () {
        expect(JsonShape.readString({'k': 'hello'}, 'k'), 'hello');
      });
      test('returns the empty-string default on missing key', () {
        expect(JsonShape.readString(<String, Object?>{}, 'k'), '');
      });
      test('returns the caller fallback on missing key', () {
        expect(
          JsonShape.readString(<String, Object?>{}, 'k', fallback: '<none>'),
          '<none>',
        );
      });
      test('returns the fallback when the value is null', () {
        expect(
          JsonShape.readString(<String, Object?>{'k': null}, 'k', fallback: 'x'),
          'x',
        );
      });
      test('returns the fallback when the value is the wrong type', () {
        expect(JsonShape.readString({'k': 42}, 'k', fallback: 'x'), 'x');
        expect(JsonShape.readString({'k': true}, 'k', fallback: 'y'), 'y');
        expect(JsonShape.readString({'k': <Object?>[]}, 'k', fallback: 'z'), 'z');
      });
    });

    group('readStringN', () {
      test('returns the string when present', () {
        expect(JsonShape.readStringN({'k': 'hi'}, 'k'), 'hi');
      });
      test('returns null on missing key', () {
        expect(JsonShape.readStringN(<String, Object?>{}, 'k'), isNull);
      });
      test('returns null on wrong type', () {
        expect(JsonShape.readStringN({'k': 42}, 'k'), isNull);
        expect(JsonShape.readStringN({'k': null}, 'k'), isNull);
      });
    });

    group('readIntN', () {
      test('returns int unchanged', () {
        expect(JsonShape.readIntN({'k': 7}, 'k'), 7);
      });
      test('truncates a double', () {
        expect(JsonShape.readIntN({'k': 3.7}, 'k'), 3);
      });
      test('returns null on missing key', () {
        expect(JsonShape.readIntN(<String, Object?>{}, 'k'), isNull);
      });
      test('returns null on non-numeric value', () {
        expect(JsonShape.readIntN({'k': '7'}, 'k'), isNull);
        expect(JsonShape.readIntN({'k': true}, 'k'), isNull);
        expect(JsonShape.readIntN({'k': null}, 'k'), isNull);
      });
    });

    group('readInt', () {
      test('returns the int when present', () {
        expect(JsonShape.readInt({'k': 7}, 'k'), 7);
      });
      test('returns 0 by default on missing key', () {
        expect(JsonShape.readInt(<String, Object?>{}, 'k'), 0);
      });
      test('returns the caller fallback on wrong type', () {
        expect(JsonShape.readInt({'k': 'x'}, 'k', fallback: -1), -1);
      });
    });

    group('readDoubleN', () {
      test('returns double unchanged', () {
        expect(JsonShape.readDoubleN({'k': 1.5}, 'k'), 1.5);
      });
      test('widens an int', () {
        expect(JsonShape.readDoubleN({'k': 7}, 'k'), 7.0);
      });
      test('returns null on missing / wrong type', () {
        expect(JsonShape.readDoubleN(<String, Object?>{}, 'k'), isNull);
        expect(JsonShape.readDoubleN({'k': 'x'}, 'k'), isNull);
      });
    });

    group('readDouble', () {
      test('returns the double when present', () {
        expect(JsonShape.readDouble({'k': 1.5}, 'k'), 1.5);
      });
      test('returns 0.0 by default on missing key', () {
        expect(JsonShape.readDouble(<String, Object?>{}, 'k'), 0.0);
      });
      test('returns the caller fallback on wrong type', () {
        expect(
          JsonShape.readDouble({'k': 'x'}, 'k', fallback: -1.0),
          -1.0,
        );
      });
    });

    group('readBool / readBoolN', () {
      test('readBool returns the bool when present', () {
        expect(JsonShape.readBool({'k': true}, 'k'), isTrue);
        expect(JsonShape.readBool({'k': false}, 'k'), isFalse);
      });
      test('readBool returns the fallback on missing / wrong type', () {
        expect(JsonShape.readBool(<String, Object?>{}, 'k'), isFalse);
        expect(
          JsonShape.readBool(<String, Object?>{}, 'k', fallback: true),
          isTrue,
        );
        expect(JsonShape.readBool({'k': 1}, 'k'), isFalse);
        expect(JsonShape.readBool({'k': 'true'}, 'k'), isFalse);
      });
      test('readBoolN returns null on missing / wrong type', () {
        expect(JsonShape.readBoolN({'k': true}, 'k'), isTrue);
        expect(JsonShape.readBoolN(<String, Object?>{}, 'k'), isNull);
        expect(JsonShape.readBoolN({'k': 1}, 'k'), isNull);
      });
    });

    group('readMap / readMapN', () {
      test('readMapN returns the nested map', () {
        final inner = <String, Object?>{'a': 1};
        expect(JsonShape.readMapN({'k': inner}, 'k'), same(inner));
      });
      test('readMapN returns null on missing / wrong type', () {
        expect(JsonShape.readMapN(<String, Object?>{}, 'k'), isNull);
        expect(JsonShape.readMapN({'k': 'x'}, 'k'), isNull);
      });
      test('readMap returns the empty const map by default', () {
        expect(JsonShape.readMap(<String, Object?>{}, 'k'), isEmpty);
      });
      test('readMap returns the caller fallback on wrong type', () {
        final fb = <String, Object?>{'fallback': true};
        expect(
          JsonShape.readMap({'k': 'wrong'}, 'k', fallback: fb),
          same(fb),
        );
      });
    });

    group('readList / readListN / readMapList / readDoubleListN', () {
      test('readList returns a List<Object?> when present', () {
        final r = JsonShape.readList({
          'k': <Object?>[1, 'two', null],
        }, 'k');
        expect(r, hasLength(3));
        expect(r[0], 1);
        expect(r[1], 'two');
        expect(r[2], isNull);
      });
      test('readList returns a fresh empty list on missing / wrong type', () {
        final r1 = JsonShape.readList(<String, Object?>{}, 'k');
        expect(r1, isEmpty);
        // Returned list is mutable (fresh).
        r1.add('x');
        expect(r1, hasLength(1));

        final r2 = JsonShape.readList({'k': 'oops'}, 'k');
        expect(r2, isEmpty);
      });
      test('readListN distinguishes missing from empty', () {
        expect(JsonShape.readListN(<String, Object?>{}, 'k'), isNull);
        expect(JsonShape.readListN({'k': <Object?>[]}, 'k'), isEmpty);
      });
      test('readMapList filters out non-map elements', () {
        final r = JsonShape.readMapList({
          'k': <Object?>[
            <String, Object?>{'id': 1},
            'noise',
            42,
            <String, Object?>{'id': 2},
            null,
          ],
        }, 'k');
        expect(r, hasLength(2));
        expect(r[0]['id'], 1);
        expect(r[1]['id'], 2);
      });
      test('readMapList returns empty on missing / non-list', () {
        expect(JsonShape.readMapList(<String, Object?>{}, 'k'), isEmpty);
        expect(JsonShape.readMapList({'k': 7}, 'k'), isEmpty);
      });
      test('readDoubleListN converts mixed int/double arrays', () {
        final r =
            JsonShape.readDoubleListN({'k': <Object?>[1, 2.5, 3]}, 'k')!;
        expect(r, [1.0, 2.5, 3.0]);
      });
      test('readDoubleListN skips non-numeric elements', () {
        final r =
            JsonShape.readDoubleListN({'k': <Object?>[1, 'two', 3]}, 'k')!;
        expect(r, [1.0, 3.0]);
      });
      test('readDoubleListN returns null on missing / wrong type', () {
        expect(JsonShape.readDoubleListN(<String, Object?>{}, 'k'), isNull);
        expect(JsonShape.readDoubleListN({'k': 'x'}, 'k'), isNull);
      });
    });

    group('requireMap / requireList', () {
      test('requireMap returns the typed map when correct', () {
        final inner = <String, Object?>{'a': 1};
        expect(
          JsonShape.requireMap(inner, where: 'test'),
          same(inner),
        );
      });
      test('requireMap throws JsonShapeException on wrong type', () {
        expect(
          () => JsonShape.requireMap('oops', where: 'test'),
          throwsA(
            isA<JsonShapeException>()
                .having((e) => e.where, 'where', 'test')
                .having((e) => e.expected, 'expected', 'Map<String, Object?>')
                .having(
                  (e) => e.actualType,
                  'actualType',
                  String,
                ),
          ),
        );
      });
      test('requireMap throws on null', () {
        expect(
          () => JsonShape.requireMap(null, where: 'null-site'),
          throwsA(isA<JsonShapeException>()),
        );
      });
      test('requireList returns the list when correct', () {
        final r = JsonShape.requireList(<Object?>[1, 2], where: 'test');
        expect(r, [1, 2]);
      });
      test('requireList throws on wrong type', () {
        expect(
          () => JsonShape.requireList(<String, Object?>{}, where: 'test'),
          throwsA(
            isA<JsonShapeException>()
                .having((e) => e.expected, 'expected', 'List<Object?>'),
          ),
        );
      });
      test('JsonShapeException.toString carries the localising label', () {
        final ex = JsonShapeException(
          where: 'Ollama.chat body',
          expected: 'Map<String, Object?>',
          actualType: String,
        );
        expect(
          ex.toString(),
          'JsonShapeException at Ollama.chat body: '
          'expected Map<String, Object?>, got String',
        );
      });
    });

    group('barrel export', () {
      test('JsonShape and JsonShapeException are exported via tom_brain_shared',
          () {
        // Compile-time check: if these symbols were not exported via the
        // package barrel, this file would fail to compile.
        expect(JsonShape.readString({}, 'k'), '');
        expect(
          () => JsonShape.requireMap(7, where: 'export-check'),
          throwsA(isA<JsonShapeException>()),
        );
      });
    });
  });
}
