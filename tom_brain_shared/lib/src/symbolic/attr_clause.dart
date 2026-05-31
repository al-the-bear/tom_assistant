// AttrClause — one ANDed clause inside a `SymbolicFilter`.
//
// Pure value type. The compiler in `tom_brain_memory` is responsible for
// validating that `value` matches `op` (e.g. a `List` for `inList` /
// `notInList`); we keep the runtime check out of shared because the
// validation message is most useful in the compiler's error context.

import 'symbolic_op.dart';

/// One attribute clause in a [SymbolicFilter].
///
/// `(field, op, value)` triple. Clauses combine via AND inside a
/// `SymbolicFilter`. Equality is structural — two `AttrClause`s are
/// equal iff field, op, and value all match.
final class AttrClause {
  /// The node-attribute column being compared.
  final String field;

  /// The comparator operator.
  final SymbolicOp op;

  /// The right-hand side of the comparison. For [SymbolicOp.inList] /
  /// [SymbolicOp.notInList] this must be a `List`; for the scalar
  /// operators it is a primitive (`String`, `int`, `double`, `bool`)
  /// or `null` (only meaningful with [SymbolicOp.eq] / [SymbolicOp.ne],
  /// which the compiler turns into `IS NULL` / `IS NOT NULL`).
  final Object? value;

  const AttrClause(this.field, this.op, this.value);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AttrClause) return false;
    if (field != other.field) return false;
    if (op != other.op) return false;
    return _valueEquals(value, other.value);
  }

  @override
  int get hashCode => Object.hash(field, op, _valueHash(value));

  @override
  String toString() => 'AttrClause($field ${op.name} $value)';
}

bool _valueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_valueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _valueHash(Object? v) {
  if (v == null) return 0;
  if (v is List) return Object.hashAll(v);
  return v.hashCode;
}
