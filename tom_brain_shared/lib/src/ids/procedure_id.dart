// ProcedureId — identifies a procedure (a d4rt script) by human-readable
// slug plus monotonic version.
//
// Shape: `p_<slug>_v<version>` — e.g. `p_author_new_procedure_v1`.
//
// Why this is a different shape from the other four IDs:
//
//   * Procedures are *authored* by the brain, often by humans first. A
//     ULID would be opaque in log lines and in the Forge module. A slug
//     reads.
//   * Procedures have *revisions*. The `_v<n>` suffix is the structural
//     hook that the procedure subsystem uses to thread `superseded-by`
//     edges in the memory graph without needing a separate column.
//   * Procedures need *equality across runs*: a re-discovered version 1 of
//     the same slug is the same procedure, no matter when the row was
//     materialised. ULIDs would defeat that.

/// Identifier of a procedure (slug + monotonic version).
///
/// Construction goes through either the named constructor (validates and
/// builds the canonical string) or `fromString` (parses and validates).
/// All other surfaces are read-only.
final class ProcedureId implements Comparable<ProcedureId> {
  /// Human-readable slug. Lowercase letters, digits and underscores;
  /// must start with a letter.
  final String slug;

  /// Monotonic version, starting at 1.
  final int version;

  /// Canonical full form: `p_<slug>_v<version>`.
  final String value;

  /// Slug rule: starts with a lowercase letter, body of `[a-z0-9_]`.
  /// Letters before digits/underscores rules out `1bad` and `_bad`.
  static final RegExp _slugRegex = RegExp(r'^[a-z][a-z0-9_]*$');

  /// Full-form rule used by `fromString`. The slug capture is greedy but
  /// the `_v` separator plus the trailing positive-integer anchor make it
  /// unambiguous: the last `_v<digits>$` wins.
  static final RegExp _fullRegex = RegExp(r'^p_([a-z][a-z0-9_]*)_v([1-9]\d*)$');

  const ProcedureId._raw(this.slug, this.version, this.value);

  /// Builds a `ProcedureId` from its parts.
  ///
  /// Throws [FormatException] when `slug` does not match the slug rule
  /// (lowercase letter, then `[a-z0-9_]*`).
  /// Throws [ArgumentError] when `version` is less than 1.
  factory ProcedureId({required String slug, required int version}) {
    if (!_slugRegex.hasMatch(slug)) {
      throw FormatException(
        'ProcedureId slug must match ${_slugRegex.pattern}',
        slug,
      );
    }
    if (version < 1) {
      throw ArgumentError.value(
        version,
        'version',
        'ProcedureId version must be >= 1',
      );
    }
    return ProcedureId._raw(slug, version, 'p_${slug}_v$version');
  }

  /// Parses a `ProcedureId` from its canonical string form.
  ///
  /// Throws [FormatException] on any structural problem.
  factory ProcedureId.fromString(String value) {
    final m = _fullRegex.firstMatch(value);
    if (m == null) {
      throw FormatException(
        'ProcedureId must match shape "p_<slug>_v<version>"',
        value,
      );
    }
    return ProcedureId._raw(m.group(1)!, int.parse(m.group(2)!), value);
  }

  /// Returns a new `ProcedureId` for the next version of the same slug.
  ProcedureId nextVersion() => ProcedureId(slug: slug, version: version + 1);

  /// Orders by slug, then by numeric version. `compareTo` on the full
  /// string would put `v10` before `v2` — that's the wrong order for our
  /// supersession traversal, so we sort numerically here.
  @override
  int compareTo(ProcedureId other) {
    final slugCmp = slug.compareTo(other.slug);
    if (slugCmp != 0) return slugCmp;
    return version.compareTo(other.version);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProcedureId && other.slug == slug && other.version == version);

  @override
  int get hashCode => Object.hash(slug, version);

  @override
  String toString() => value;
}
