// Tests for the `embedding/` module (Plan step A.11).
//
// Surface under test:
//   * `Vec` construction: raw Float32List, copy, fromList, zero, fromBlob
//   * `Vec.toBlob` <-> `Vec.fromBlob` round-trip
//   * Element access via operator [] and the read-only `values` view
//   * Equality, hashCode, closeTo
//   * `Vec.mean` — happy path, dimension mismatch, empty list
//   * `dot(a, b)` — happy path + dimension mismatch
//   * `cosine(a, b)` — identical / orthogonal / opposite / clamping at ±1
//                    / zero-norm rejection / dimension mismatch
//   * `l2(a, b)` — happy path + self-distance + symmetry + dim mismatch
//   * Property tests: `cosine(a, a) == 1`, `l2(a, a) == 0`, `dot(a, b) == dot(b, a)`

import 'dart:math';
import 'dart:typed_data';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Vec construction', () {
    test('raw Float32List constructor wraps the buffer directly', () {
      final raw = Float32List.fromList([1.0, 2.0, 3.0]);
      final v = Vec(raw);
      expect(v.dimension, equals(3));
      expect(v[0], equals(1.0));
      expect(v[1], equals(2.0));
      expect(v[2], equals(3.0));
    });

    test('Vec.copy is independent of the source buffer', () {
      final raw = Float32List.fromList([1.0, 2.0, 3.0]);
      final v = Vec.copy(raw);
      raw[0] = 99.0;
      expect(v[0], equals(1.0), reason: 'copy must not see later mutations');
    });

    test('Vec.fromList builds from List<double>', () {
      final v = Vec.fromList([0.5, -0.5, 1.5]);
      expect(v.dimension, equals(3));
      expect(v[0], closeTo(0.5, 1e-7));
      expect(v[1], closeTo(-0.5, 1e-7));
      expect(v[2], closeTo(1.5, 1e-7));
    });

    test('Vec.zero builds a zero-filled vector of the requested dimension',
        () {
      final v = Vec.zero(5);
      expect(v.dimension, equals(5));
      for (var i = 0; i < 5; i++) {
        expect(v[i], equals(0.0));
      }
    });

    test('Vec.zero rejects non-positive dimension', () {
      expect(() => Vec.zero(0), throwsA(isA<ArgumentError>()));
      expect(() => Vec.zero(-1), throwsA(isA<ArgumentError>()));
    });

    test('default constructor rejects an empty Float32List', () {
      expect(() => Vec(Float32List(0)), throwsA(isA<ArgumentError>()));
    });
  });

  group('Vec blob round-trip', () {
    test('toBlob then fromBlob recovers identical components', () {
      final original = Vec.fromList([0.0, 1.0, -1.0, 3.14159, 1e-30, 1e30]);
      final blob = original.toBlob();
      // Each float32 = 4 bytes
      expect(blob.lengthInBytes, equals(6 * 4));
      final restored = Vec.fromBlob(blob);
      expect(restored.dimension, equals(original.dimension));
      for (var i = 0; i < original.dimension; i++) {
        expect(restored[i], equals(original[i]),
            reason: 'component $i must round-trip bit-exact');
      }
    });

    test('fromBlob rejects an empty blob', () {
      expect(
        () => Vec.fromBlob(Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('fromBlob rejects blob length not divisible by 4', () {
      expect(
        () => Vec.fromBlob(Uint8List(5)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => Vec.fromBlob(Uint8List(7)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('blob encoding is little-endian and stable across calls', () {
      // 1.0f LE bytes are 00 00 80 3F. Verify the wire shape so this stays
      // portable across host byte orders.
      final v = Vec.fromList([1.0]);
      final blob = v.toBlob();
      expect(blob[0], equals(0x00));
      expect(blob[1], equals(0x00));
      expect(blob[2], equals(0x80));
      expect(blob[3], equals(0x3F));
    });
  });

  group('Vec element access and view', () {
    test('operator [] throws RangeError out of bounds', () {
      final v = Vec.fromList([1.0, 2.0]);
      expect(() => v[2], throwsA(isA<RangeError>()));
      expect(() => v[-1], throwsA(isA<RangeError>()));
    });

    test('values iterable yields the components in order', () {
      final v = Vec.fromList([1.0, 2.0, 3.0]);
      expect(v.values.toList(), equals(<double>[1.0, 2.0, 3.0]));
    });
  });

  group('Vec equality and hashing', () {
    test('two Vecs with identical components are equal', () {
      final a = Vec.fromList([0.1, 0.2, 0.3]);
      final b = Vec.fromList([0.1, 0.2, 0.3]);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different dimension: not equal', () {
      final a = Vec.fromList([0.1, 0.2, 0.3]);
      final b = Vec.fromList([0.1, 0.2]);
      expect(a, isNot(equals(b)));
    });

    test('one differing component: not equal', () {
      final a = Vec.fromList([0.1, 0.2, 0.3]);
      final b = Vec.fromList([0.1, 0.2, 0.4]);
      expect(a, isNot(equals(b)));
    });

    test('not equal to non-Vec types', () {
      final a = Vec.fromList([0.1, 0.2, 0.3]);
      expect(a, isNot(equals(<double>[0.1, 0.2, 0.3])));
      expect(a, isNot(equals(<Object>{})));
    });

    test('closeTo accepts small per-component drift', () {
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final b = Vec.fromList([1.0 + 1e-7, 2.0, 3.0 - 1e-7]);
      expect(a.closeTo(b), isTrue);
    });

    test('closeTo rejects drift over tolerance', () {
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final b = Vec.fromList([1.5, 2.0, 3.0]);
      expect(a.closeTo(b), isFalse);
    });

    test('closeTo rejects mismatched dimension', () {
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final b = Vec.fromList([1.0, 2.0]);
      expect(a.closeTo(b), isFalse);
    });
  });

  group('Vec.mean', () {
    test('mean of a single vector is that vector', () {
      final v = Vec.fromList([1.0, 2.0, 3.0]);
      final m = Vec.mean([v]);
      expect(m.dimension, equals(3));
      expect(m.closeTo(v), isTrue);
    });

    test('mean of three vectors computes component-wise average', () {
      final m = Vec.mean([
        Vec.fromList([1.0, 2.0, 3.0]),
        Vec.fromList([3.0, 4.0, 5.0]),
        Vec.fromList([5.0, 6.0, 7.0]),
      ]);
      expect(m.closeTo(Vec.fromList([3.0, 4.0, 5.0])), isTrue);
    });

    test('mean uses double-precision accumulation', () {
      // 100 copies of a tiny value. A naive float32 running-sum would lose
      // ULPs; the double accumulator must preserve the mean.
      final vectors = List<Vec>.generate(
        100,
        (_) => Vec.fromList([1e-7]),
      );
      final m = Vec.mean(vectors);
      expect(m[0], closeTo(1e-7, 1e-12));
    });

    test('mean rejects empty input', () {
      expect(
        () => Vec.mean(const <Vec>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('mean rejects dimension mismatch', () {
      expect(
        () => Vec.mean([
          Vec.fromList([1.0, 2.0]),
          Vec.fromList([1.0, 2.0, 3.0]),
        ]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('dot()', () {
    test('computes Σ aᵢ bᵢ', () {
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final b = Vec.fromList([4.0, -5.0, 6.0]);
      // 1*4 + 2*-5 + 3*6 = 4 - 10 + 18 = 12
      expect(dot(a, b), closeTo(12.0, 1e-5));
    });

    test('is symmetric: dot(a, b) == dot(b, a)', () {
      final a = Vec.fromList([0.5, -0.25, 1.25, 2.0]);
      final b = Vec.fromList([1.0, 2.0, -1.0, 0.5]);
      expect(dot(a, b), closeTo(dot(b, a), 1e-6));
    });

    test('zero-vector dot equals zero', () {
      final a = Vec.zero(4);
      final b = Vec.fromList([1.0, 2.0, 3.0, 4.0]);
      expect(dot(a, b), equals(0.0));
    });

    test('dimension mismatch throws ArgumentError', () {
      final a = Vec.fromList([1.0, 2.0]);
      final b = Vec.fromList([1.0, 2.0, 3.0]);
      expect(() => dot(a, b), throwsA(isA<ArgumentError>()));
    });
  });

  group('cosine()', () {
    test('cosine of identical vectors is 1.0', () {
      final a = Vec.fromList([0.3, -0.4, 0.5, 1.2]);
      expect(cosine(a, a), closeTo(1.0, 1e-6));
    });

    test('cosine of opposite vectors is -1.0', () {
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final b = Vec.fromList([-1.0, -2.0, -3.0]);
      expect(cosine(a, b), closeTo(-1.0, 1e-6));
    });

    test('cosine of orthogonal vectors is 0.0', () {
      final a = Vec.fromList([1.0, 0.0, 0.0]);
      final b = Vec.fromList([0.0, 1.0, 0.0]);
      expect(cosine(a, b), closeTo(0.0, 1e-6));
    });

    test('cosine is scale-invariant', () {
      // cosine(a, 7a) must equal 1.0; cosine(a, b) must equal cosine(a, 7b).
      final a = Vec.fromList([1.0, 2.0, 3.0]);
      final aTimes7 = Vec.fromList([7.0, 14.0, 21.0]);
      expect(cosine(a, aTimes7), closeTo(1.0, 1e-6));

      final b = Vec.fromList([4.0, -5.0, 6.0]);
      final bTimes7 = Vec.fromList([28.0, -35.0, 42.0]);
      expect(cosine(a, b), closeTo(cosine(a, bTimes7), 1e-6));
    });

    test('clamps to [-1.0, 1.0] under floating-point drift', () {
      // Build a 256-D vector and compute cosine against itself. With float32
      // accumulation this can land at 1.0000001 without the clamp.
      final rng = Random(1);
      final values = Float32List(256);
      for (var i = 0; i < values.length; i++) {
        values[i] = rng.nextDouble() * 2 - 1;
      }
      final a = Vec(values);
      final c = cosine(a, a);
      expect(c, lessThanOrEqualTo(1.0));
      expect(c, closeTo(1.0, 1e-5));
    });

    test('cosine rejects zero-norm input', () {
      final z = Vec.zero(3);
      final v = Vec.fromList([1.0, 2.0, 3.0]);
      expect(() => cosine(z, v), throwsA(isA<ArgumentError>()));
      expect(() => cosine(v, z), throwsA(isA<ArgumentError>()));
      expect(() => cosine(z, z), throwsA(isA<ArgumentError>()));
    });

    test('cosine dimension mismatch throws ArgumentError', () {
      final a = Vec.fromList([1.0, 2.0]);
      final b = Vec.fromList([1.0, 2.0, 3.0]);
      expect(() => cosine(a, b), throwsA(isA<ArgumentError>()));
    });

    test('cosine is symmetric: cos(a, b) == cos(b, a)', () {
      final a = Vec.fromList([0.5, -0.25, 1.25, 2.0]);
      final b = Vec.fromList([1.0, 2.0, -1.0, 0.5]);
      expect(cosine(a, b), closeTo(cosine(b, a), 1e-6));
    });
  });

  group('l2()', () {
    test('l2 of a vector with itself is 0', () {
      final a = Vec.fromList([0.3, -0.4, 0.5, 1.2]);
      expect(l2(a, a), equals(0.0));
    });

    test('l2 distance between known vectors', () {
      // l2((1,0), (0,1)) = sqrt(1 + 1) = sqrt(2)
      final a = Vec.fromList([1.0, 0.0]);
      final b = Vec.fromList([0.0, 1.0]);
      expect(l2(a, b), closeTo(sqrt(2), 1e-6));
    });

    test('l2 is symmetric', () {
      final a = Vec.fromList([1.0, 2.0, 3.0, 4.0]);
      final b = Vec.fromList([5.0, 6.0, 7.0, 8.0]);
      expect(l2(a, b), closeTo(l2(b, a), 1e-6));
    });

    test('l2 satisfies the triangle inequality on a small set', () {
      final a = Vec.fromList([1.0, 0.0, 0.0]);
      final b = Vec.fromList([0.0, 1.0, 0.0]);
      final c = Vec.fromList([0.0, 0.0, 1.0]);
      // d(a,c) <= d(a,b) + d(b,c)
      expect(l2(a, c), lessThanOrEqualTo(l2(a, b) + l2(b, c) + 1e-6));
    });

    test('l2 dimension mismatch throws ArgumentError', () {
      final a = Vec.fromList([1.0, 2.0]);
      final b = Vec.fromList([1.0, 2.0, 3.0]);
      expect(() => l2(a, b), throwsA(isA<ArgumentError>()));
    });
  });

  group('norm() and toString()', () {
    test('norm of zero vector is 0', () {
      expect(Vec.zero(7).norm(), equals(0.0));
    });

    test('norm of a unit vector is 1', () {
      final v = Vec.fromList([1.0, 0.0, 0.0]);
      expect(v.norm(), closeTo(1.0, 1e-6));
    });

    test('norm of (3,4) is 5', () {
      final v = Vec.fromList([3.0, 4.0]);
      expect(v.norm(), closeTo(5.0, 1e-6));
    });

    test('toString shows full components for short vectors', () {
      final v = Vec.fromList([1.0, 2.0, 3.0]);
      final s = v.toString();
      expect(s, contains('dim=3'));
      expect(s, contains('values='));
    });

    test('toString abbreviates components for long vectors', () {
      final v = Vec.fromList(List.generate(100, (i) => i.toDouble()));
      final s = v.toString();
      expect(s, contains('dim=100'));
      expect(s, contains('head='));
      expect(s, contains('...'));
    });
  });

  group('property: random vectors', () {
    test('cosine(a, a) == 1 for many random vectors', () {
      final rng = Random(42);
      for (var k = 0; k < 50; k++) {
        final dim = 8 + rng.nextInt(40);
        final values = Float32List(dim);
        for (var i = 0; i < dim; i++) {
          values[i] = rng.nextDouble() * 4 - 2;
          // Avoid the all-zeros edge case (cosine throws on zero norm).
          if (values[i] == 0.0) values[i] = 1e-3;
        }
        final a = Vec(values);
        expect(cosine(a, a), closeTo(1.0, 1e-5),
            reason: 'iteration $k (dim=$dim)');
      }
    });

    test('l2(a, a) == 0 for many random vectors', () {
      final rng = Random(7);
      for (var k = 0; k < 50; k++) {
        final dim = 8 + rng.nextInt(40);
        final values = Float32List(dim);
        for (var i = 0; i < dim; i++) {
          values[i] = rng.nextDouble() * 4 - 2;
        }
        final a = Vec(values);
        expect(l2(a, a), equals(0.0), reason: 'iteration $k (dim=$dim)');
      }
    });

    test('dot is symmetric over many random pairs', () {
      final rng = Random(123);
      for (var k = 0; k < 50; k++) {
        final dim = 8 + rng.nextInt(40);
        final av = Float32List(dim);
        final bv = Float32List(dim);
        for (var i = 0; i < dim; i++) {
          av[i] = rng.nextDouble() * 4 - 2;
          bv[i] = rng.nextDouble() * 4 - 2;
        }
        final a = Vec(av);
        final b = Vec(bv);
        expect(dot(a, b), closeTo(dot(b, a), 1e-5),
            reason: 'iteration $k (dim=$dim)');
      }
    });
  });
}
