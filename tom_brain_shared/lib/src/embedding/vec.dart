// Vec — fixed-dimension `Float32List` wrapper used as the embedding type
// across all Tom Brain components.
//
// Why a wrapper rather than a raw `Float32List`?
//
//   * Type identity. Method signatures that take or return embeddings can say
//     `Vec` instead of `Float32List`. That distinguishes embeddings from
//     "any list of 32-bit floats" — useful at retrieval boundaries where the
//     same shape could otherwise mean either thing.
//   * Equality and hashing. `Float32List` inherits the standard `List`
//     equality (identity by default; structural via `ListEquality`), and
//     bundling those rules onto a value type keeps consumers from having to
//     remember which side handles it.
//   * Blob round-trip. Memory stores vectors in SQLite as a `blob` column
//     (see `memory_specification.md` § 12.3). `Vec` is the right place for
//     `toBlob` / `fromBlob` because the contract — float32, little-endian,
//     dimension implicit in payload length — lives with the type.
//
// What `Vec` deliberately is NOT:
//
//   * It is not a general-purpose linear-algebra type. Operations are limited
//     to what retrieval and classification actually use: cosine, dot, L2 and
//     element-wise mean.
//   * It does not own a normalisation step. Callers who want unit vectors
//     normalise explicitly. Retrieval code uses cosine, which is
//     scale-invariant by construction.
//   * It does not carry the embedding-model identity. That lives in a
//     sibling column on `vectors.db` (memory's concern, not the shared
//     type's).

import 'dart:math' as math;
import 'dart:typed_data';

/// A fixed-dimension embedding vector backed by a `Float32List`.
///
/// `Vec` is immutable from the outside: its dimension and element values are
/// fixed at construction. The wrapped `Float32List` is held privately so the
/// invariant is not subject to external mutation.
final class Vec {
  /// The underlying float32 storage. Private to keep `Vec` immutable from the
  /// outside; element access goes through [operator []].
  final Float32List _values;

  /// Wraps the given `Float32List` *directly* — the buffer is shared with the
  /// caller. Use [Vec.copy] when you do not control the source list.
  ///
  /// This constructor is the right one for hot-path code (e.g. SQLite
  /// blob decode that produced a fresh `Float32List` and immediately hands it
  /// over). For caller-supplied lists with unknown lifetime, prefer [Vec.copy]
  /// or [Vec.fromList].
  Vec(Float32List values) : _values = values {
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'Vec dimension must be > 0; got empty Float32List',
      );
    }
  }

  /// Wraps a defensive copy of the given `Float32List`. Use this when the
  /// caller's buffer might be modified later.
  factory Vec.copy(Float32List values) =>
      Vec(Float32List.fromList(values));

  /// Builds a `Vec` from a `List<double>`. Each element is coerced to
  /// float32 — values that overflow are clamped per IEEE 754 round-half-even.
  factory Vec.fromList(List<double> values) =>
      Vec(Float32List.fromList(values));

  /// Builds a zero-filled `Vec` of the given dimension.
  ///
  /// Throws [ArgumentError] when [dimension] <= 0. A zero-dim vector would
  /// satisfy no useful operation downstream.
  factory Vec.zero(int dimension) {
    if (dimension <= 0) {
      throw ArgumentError.value(
        dimension,
        'dimension',
        'Vec dimension must be > 0',
      );
    }
    return Vec(Float32List(dimension));
  }

  /// Decodes a blob produced by [toBlob]. The blob is a little-endian
  /// float32 sequence; its length must be a multiple of 4. The dimension is
  /// `blob.lengthInBytes ~/ 4`.
  ///
  /// Little-endian is the canonical wire format across replicas
  /// (`memory_specification.md` § 11) — encoding host-byte-order would make
  /// vectors written on one machine unreadable on another.
  factory Vec.fromBlob(Uint8List blob) {
    if (blob.lengthInBytes == 0) {
      throw ArgumentError.value(
        blob,
        'blob',
        'Vec blob must be non-empty',
      );
    }
    if (blob.lengthInBytes % 4 != 0) {
      throw ArgumentError.value(
        blob,
        'blob',
        'Vec blob length must be a multiple of 4 (float32); '
            'got ${blob.lengthInBytes} bytes',
      );
    }
    final dimension = blob.lengthInBytes ~/ 4;
    final out = Float32List(dimension);
    final reader = ByteData.sublistView(blob);
    for (var i = 0; i < dimension; i++) {
      out[i] = reader.getFloat32(i * 4, Endian.little);
    }
    return Vec(out);
  }

  /// Encodes this vector as little-endian float32 bytes for blob storage.
  /// Round-trips through [Vec.fromBlob].
  Uint8List toBlob() {
    final out = ByteData(_values.lengthInBytes);
    for (var i = 0; i < _values.length; i++) {
      out.setFloat32(i * 4, _values[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// Number of components.
  int get dimension => _values.length;

  /// Element access. Throws [RangeError] when [index] is out of bounds.
  double operator [](int index) => _values[index];

  /// Iterable view over the components. Read-only — the underlying buffer
  /// is not exposed.
  Iterable<double> get values => _values;

  /// L2 norm of this vector — √Σ vᵢ².
  double norm() {
    var sumSq = 0.0;
    for (var i = 0; i < _values.length; i++) {
      final v = _values[i];
      sumSq += v * v;
    }
    // Note: returns 0.0 for the zero vector. Callers that care about the
    // zero case (e.g. cosine) check explicitly.
    //
    // We compute the sum in double precision and only sqrt once, which keeps
    // the rounding error tighter than a running-sum-of-magnitudes.
    return math.sqrt(sumSq);
  }

  /// Element-wise mean across [vectors]. Requires non-empty input with
  /// matching dimension.
  ///
  /// Used by `dream_recentroid_v1` to recompute per-type and per-procedure
  /// classification centroids (`memory_specification.md` § 7).
  static Vec mean(List<Vec> vectors) {
    if (vectors.isEmpty) {
      throw ArgumentError.value(
        vectors,
        'vectors',
        'Vec.mean requires at least one input vector',
      );
    }
    final dimension = vectors.first.dimension;
    for (var i = 1; i < vectors.length; i++) {
      if (vectors[i].dimension != dimension) {
        throw ArgumentError(
          'Vec.mean: dimension mismatch at index $i — '
          'expected $dimension, got ${vectors[i].dimension}',
        );
      }
    }
    // Accumulate in double precision; only narrow to float32 at the end so
    // the mean of a hundred float32 vectors does not lose its last bits.
    final acc = Float64List(dimension);
    for (final v in vectors) {
      for (var i = 0; i < dimension; i++) {
        acc[i] += v[i];
      }
    }
    final n = vectors.length;
    final out = Float32List(dimension);
    for (var i = 0; i < dimension; i++) {
      out[i] = acc[i] / n;
    }
    return Vec(out);
  }

  /// Equality is element-wise bit-identical comparison.
  ///
  /// Two `Vec`s are equal iff they have the same dimension and every element
  /// has the same float32 representation. This is the right contract for
  /// "is this the same vector I stored" but it is **not** the right contract
  /// for "are these vectors numerically close" — use [closeTo] for that.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Vec) return false;
    if (other._values.length != _values.length) return false;
    for (var i = 0; i < _values.length; i++) {
      if (other._values[i] != _values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // Combine length and a fold over the first few elements. Folding the
    // whole vector is unnecessary; combining length plus a stable prefix
    // gives enough entropy for hash buckets and avoids O(N) hashing on every
    // map lookup.
    final prefix = _values.length < 8 ? _values.length : 8;
    var h = _values.length;
    for (var i = 0; i < prefix; i++) {
      h = Object.hash(h, _values[i]);
    }
    return h;
  }

  /// Approximate equality, useful for tests where exact bit equality is too
  /// strict (e.g. centroid round-trips that pass through arithmetic).
  ///
  /// [tolerance] is an absolute tolerance on each component.
  bool closeTo(Vec other, {double tolerance = 1e-6}) {
    if (other._values.length != _values.length) return false;
    for (var i = 0; i < _values.length; i++) {
      if ((other._values[i] - _values[i]).abs() > tolerance) return false;
    }
    return true;
  }

  @override
  String toString() {
    // Don't dump every component for high-dimensional vectors; the
    // diagnostic value drops sharply after the first few and the log lines
    // become noise.
    const head = 4;
    if (_values.length <= head) {
      return 'Vec(dim=${_values.length}, values=${_values.toList()})';
    }
    final preview = _values.sublist(0, head).toList();
    return 'Vec(dim=${_values.length}, head=$preview, ...)';
  }
}

/// Dot product `a · b = Σ aᵢ·bᵢ`. Requires matching dimension.
double dot(Vec a, Vec b) {
  _requireSameDimension(a, b, 'dot');
  var sum = 0.0;
  for (var i = 0; i < a.dimension; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/// Cosine similarity `a · b / (|a| · |b|)` ∈ [-1, 1].
///
/// Requires matching dimension and non-zero norms on both sides. Cosine of
/// the zero vector is mathematically undefined; callers that want a
/// "no signal" sentinel should check for zero vectors before calling.
double cosine(Vec a, Vec b) {
  _requireSameDimension(a, b, 'cosine');
  final na = a.norm();
  final nb = b.norm();
  if (na == 0.0 || nb == 0.0) {
    throw ArgumentError(
      'cosine is undefined when either vector has zero norm',
    );
  }
  // Compute dot inline rather than calling `dot(a, b)` — we already have the
  // dimension check and we save a second function-call frame on the hot
  // retrieval path.
  var sum = 0.0;
  for (var i = 0; i < a.dimension; i++) {
    sum += a[i] * b[i];
  }
  final raw = sum / (na * nb);
  // Floating-point arithmetic can push a cosine of two identical vectors a
  // tiny amount past 1.0 (or two opposites past -1.0). Clamp so consumers
  // can rely on the mathematical bounds.
  if (raw > 1.0) return 1.0;
  if (raw < -1.0) return -1.0;
  return raw;
}

/// Euclidean (L2) distance `√Σ (aᵢ - bᵢ)²`. Requires matching dimension.
double l2(Vec a, Vec b) {
  _requireSameDimension(a, b, 'l2');
  var sumSq = 0.0;
  for (var i = 0; i < a.dimension; i++) {
    final d = a[i] - b[i];
    sumSq += d * d;
  }
  return math.sqrt(sumSq);
}

void _requireSameDimension(Vec a, Vec b, String op) {
  if (a.dimension != b.dimension) {
    throw ArgumentError(
      '$op: dimension mismatch — '
      'left=${a.dimension}, right=${b.dimension}',
    );
  }
}
