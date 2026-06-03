// Internal argument-validation guards (review action A.2.5).
//
// `Persona`, `Session`, `ResolvedIdentity` (and others) each re-wrote the
// same `if (x.isEmpty) throw ArgumentError.value(x, name, 'must be
// non-empty')` guard. Centralised here so the guard and its message text are
// written once.
//
// Why `internal/`: a validation aid for this package's own constructors, not
// part of the public import surface.

/// Returns [value] unchanged when it is non-empty; otherwise throws an
/// [ArgumentError] naming [name]. Use in a constructor body to reject an
/// empty required string with a uniform message.
///
/// This checks emptiness only (length 0). A field that must also reject
/// whitespace-only input (e.g. a free-text prompt) keeps its own
/// `value.trim().isEmpty` check — the semantics differ.
String requireNonEmpty(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-empty');
  }
  return value;
}
