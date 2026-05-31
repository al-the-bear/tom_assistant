// `BrainVersion` — monotonic version value type for Tom Brain
// (Plan step A.16).
//
// What versions are used for in the brain:
//
//   * Procedure revisions. Each new revision of a procedure (authored,
//     promoted, demoted) takes the next [BrainVersion]; the revision
//     chain in memory is wired via `superseded_by` edges between nodes
//     carrying ascending [BrainVersion] values. The procedure runtime
//     selects "the highest-version procedure satisfying the predicate"
//     by an ordering query — total order on [BrainVersion] is what
//     makes that query well-defined.
//   * Memory schema migrations. `memory_specification.md` § 12 records
//     each migration as a row in `migrations` with a `BrainVersion`
//     column. The migrator selects the highest applied version and
//     replays everything strictly greater.
//   * Node-type registry. Each `NodeTypeDecl` revision (additive
//     attribute changes, centroid updates) advances its
//     [BrainVersion]; classification re-uses centroids only for the
//     current registry version.
//   * Stack policy revisions. Stack retention / priority policies can
//     be reconfigured; the active configuration carries a
//     [BrainVersion] so historical decisions can be attributed to the
//     policy that was in force at the time.
//
// What [BrainVersion] is NOT:
//
//   * Not a semver triple. Procedure revisions, schema migrations, and
//     node-type updates only need a total order. Adding major / minor
//     / patch components would invite consumers to attach informal
//     compatibility semantics that the brain does not enforce; the
//     brain enforces "this version is newer than that one" and
//     nothing else. If a future consumer needs semantic semver, it can
//     wrap [BrainVersion] in three-of-them; the underlying primitive
//     remains a single integer.
//   * Not a "version 0 = no version yet" sentinel. The "no version
//     yet" state is represented by `Maybe<BrainVersion>` (see
//     `result/maybe.dart`). [BrainVersion] is always ≥ 1; the type
//     system carries the optionality where it actually exists. Using
//     `fromInt(0)` as a sentinel would smuggle null-as-int into a
//     range-checked value type — exactly the kind of "implicit
//     invariant" the value-type discipline exists to prevent.
//   * Not a clock. Versions are advanced by explicit `next()` (or by
//     the migration writer setting an exact value); time has nothing
//     to do with it. Two procedures can be at the same version
//     created days apart; one stack-policy version may live for
//     months. Reading "what is the current version" is a query
//     against the relevant table, not a call to a clock.
//
// Why the upper bound is `2^53 - 1` (the JavaScript-safe integer
// limit) rather than the full Dart `int` range:
//
//   * Versions cross the wire as JSON: through the MCP server's tool
//     responses, through the OpenAI-format gateway's metadata, into
//     the Forge UI's web frontend, and out to any TypeScript / web
//     consumer. JSON numbers above `2^53 - 1` lose precision in
//     JavaScript's IEEE-754 representation; a brain that minted
//     `9_007_199_254_740_993` would see it round-trip as
//     `9_007_199_254_740_992` and the "latest version" predicate
//     would silently misclassify. Capping at the JS-safe limit keeps
//     the round-trip lossless across every consumer the brain plans
//     to feed. The cap leaves room for ~9 × 10^15 versions, far
//     beyond any realistic procedure-revision or schema-migration
//     count.

/// Monotonic version value type used across Tom Brain.
///
/// Immutable. Wraps a single positive integer (≥ 1). Equality and
/// `hashCode` are by value. Total ordering is provided via
/// [compareTo] and the standard comparison operators.
///
/// Versions are advanced by [next], which returns the successor (or
/// throws at the [maxValue] ceiling). The "no version yet" state is
/// modelled outside this type as `Maybe<BrainVersion>` — see
/// `result/maybe.dart`.
///
/// The class is structurally immutable (`final class`, single `final`
/// field, no setters). The `@immutable` annotation from `package:meta`
/// is deliberately *not* applied here because A.9 locked the package
/// dependency set to `tom_basics` only; the `final` keyword on the
/// class carries the same semantic in a way the analyzer understands.
final class BrainVersion implements Comparable<BrainVersion> {
  /// The wrapped integer value. Always ≥ 1 and ≤ [maxValue].
  final int value;

  /// Private constructor; callers reach this through the validated
  /// factories ([fromInt], [parse]) or via [next] / [initial].
  const BrainVersion._(this.value);

  /// The first version a freshly-minted versioned entity carries.
  ///
  /// Equivalent to `BrainVersion.fromInt(1)`. Provided as a named
  /// constant so initialisation sites read declaratively
  /// (`version: BrainVersion.initial`).
  static const BrainVersion initial = BrainVersion._(1);

  /// Inclusive upper bound on [value].
  ///
  /// Equal to `2^53 - 1 = 9007199254740991`, the largest integer that
  /// round-trips losslessly through a JSON `number` in IEEE-754
  /// double-precision. The brain emits versions into JSON payloads
  /// over MCP, OpenAI-format SSE, and the Forge UI bridge; choosing
  /// the JS-safe limit keeps the round-trip lossless across every
  /// consumer.
  static const int maxValue = 9007199254740991; // 2^53 - 1

  /// Constructs a [BrainVersion] from a raw integer.
  ///
  /// Throws [ArgumentError] if [n] is below 1 or above [maxValue].
  ///
  /// Use [initial] for "version 1" and [next] to advance an existing
  /// version. Direct calls to `fromInt` are appropriate when loading
  /// a persisted version back from storage (where the integer is
  /// already in hand).
  factory BrainVersion.fromInt(int n) {
    if (n < 1) {
      throw ArgumentError.value(
        n,
        'n',
        'BrainVersion must be ≥ 1; "no version yet" is represented by '
            'Maybe<BrainVersion>.none(), not by version 0',
      );
    }
    if (n > maxValue) {
      throw ArgumentError.value(
        n,
        'n',
        'BrainVersion must be ≤ $maxValue (the JS-safe integer limit, '
            'so JSON round-trip through the MCP / SSE wire is lossless)',
      );
    }
    return BrainVersion._(n);
  }

  /// Parses a string form of a version.
  ///
  /// Accepts both `"v42"` and `"42"`. The leading `v` is the form
  /// emitted by [toString]; the bare integer form is accepted so
  /// versions read off a SQLite `INTEGER` column or out of a JSON
  /// `number` can be parsed without first re-formatting them.
  ///
  /// Throws [FormatException] on an unparseable string; throws
  /// [ArgumentError] on a parseable integer that falls outside the
  /// `[1, maxValue]` range.
  factory BrainVersion.parse(String s) {
    if (s.isEmpty) {
      throw const FormatException(
        'BrainVersion.parse: empty string is not a valid version',
      );
    }
    final body = s.startsWith('v') ? s.substring(1) : s;
    if (body.isEmpty) {
      throw FormatException(
        'BrainVersion.parse: "$s" has the "v" prefix but no digits',
      );
    }
    // Reject signed forms ("+42", "-3", "v-3") — versions are
    // unsigned by construction. `int.parse` would accept "+42" which
    // we want to refuse for shape clarity (the canonical form is
    // bare digits or "v"-prefixed bare digits).
    if (body.startsWith('-') || body.startsWith('+')) {
      throw FormatException(
        'BrainVersion.parse: "$s" carries an explicit sign; versions are '
            'unsigned',
      );
    }
    final n = int.tryParse(body);
    if (n == null) {
      throw FormatException(
        'BrainVersion.parse: "$s" is not a valid integer version',
      );
    }
    return BrainVersion.fromInt(n);
  }

  /// Returns the next version in sequence.
  ///
  /// Throws [StateError] if the current value is already at [maxValue]
  /// (a condition that should never be reachable in practice; the
  /// brain would have to mint ~9 × 10^15 versions of a single entity).
  /// Modelled as a [StateError] rather than an [ArgumentError] because
  /// the offending value is the receiver, not an argument.
  BrainVersion next() {
    if (value == maxValue) {
      throw StateError(
        'BrainVersion.next: already at the maximum value ($maxValue); '
            'the brain has exhausted the JS-safe version space, which '
            'should never happen for any realistic entity',
      );
    }
    return BrainVersion._(value + 1);
  }

  /// True when this version is the immediate successor of [other].
  ///
  /// Equivalent to `value == other.value + 1`. Provided so revision-
  /// chain consumers (the procedure layer's `superseded_by` edge
  /// builder, the schema migrator's "must apply v(N) then v(N+1)"
  /// guard) read declaratively at the call site.
  bool isImmediateSuccessorOf(BrainVersion other) =>
      value == other.value + 1;

  /// True when this version is the immediate predecessor of [other].
  ///
  /// Symmetric counterpart of [isImmediateSuccessorOf]. Equivalent to
  /// `value + 1 == other.value`.
  bool isImmediatePredecessorOf(BrainVersion other) =>
      value + 1 == other.value;

  @override
  int compareTo(BrainVersion other) => value.compareTo(other.value);

  /// Strictly-earlier comparator (`this.value < other.value`).
  bool operator <(BrainVersion other) => value < other.value;

  /// At-or-earlier comparator.
  bool operator <=(BrainVersion other) => value <= other.value;

  /// Strictly-later comparator.
  bool operator >(BrainVersion other) => value > other.value;

  /// At-or-later comparator.
  bool operator >=(BrainVersion other) => value >= other.value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BrainVersion && other.value == value);

  @override
  int get hashCode => value.hashCode;

  /// Canonical string form: `"v"` followed by the decimal integer.
  ///
  /// Round-trips through [BrainVersion.parse]. Suitable for log
  /// lines, debug prints, and any wire format that wants a textual
  /// version (otherwise prefer [value] directly).
  @override
  String toString() => 'v$value';
}
