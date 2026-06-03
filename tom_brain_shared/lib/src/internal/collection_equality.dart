// Internal collection-equality / hash helpers (review action A.2.2–A.2.3).
//
// Several value types in this package hand-rolled the same collection
// comparisons in their `==` / `hashCode`: `_mapEq` (twice, verbatim),
// `_setEq`, ordered list equality, and a deep scalar-or-nested-list
// `_valueEquals` / `_valueHash`. That is four-plus independent
// re-implementations of one idea — a rule-of-three extraction, already
// exceeded. They are centralised here so a single, tested implementation
// backs every value type's equality contract.
//
// Why `internal/` and not the public barrel: these are implementation
// support for this package's own value types, not part of the
// `tom_brain_shared` import surface. When the A.1 promotion to a generic
// `tom_basics` / `tom_core_agentic` collection utility lands, these move up
// already de-duplicated (the review's staging note: consolidate before
// promoting).
//
// No I/O, no side-effects — pure functions, consistent with the A.9
// dependency-discipline contract.

/// Order-insensitive equality for two sets: same size and same members.
bool setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

/// Key/value equality for two maps: same size, same keys, and `==`-equal
/// values. Value comparison is shallow (`==`); callers needing deep value
/// comparison should normalise first.
bool mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final MapEntry<K, V> entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

/// Ordered equality for two lists: same length and `==`-equal elements at
/// each index.
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Deep equality for an attribute value that may be a scalar or a nested
/// `List` of scalars/lists. Two `null`s are equal; a `null` and a non-`null`
/// are not; nested lists compare element-wise (recursively); every other
/// value falls back to `==`.
bool deepValueEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Hash companion to [deepValueEquals]: `null` hashes to 0, a `List` hashes
/// by its (ordered) elements, every other value uses its own `hashCode`.
int deepValueHash(Object? v) {
  if (v == null) return 0;
  if (v is List) return Object.hashAll(v);
  return v.hashCode;
}
