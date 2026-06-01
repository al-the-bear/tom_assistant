// Pure JSON shape helpers (Plan step B.44).
//
// These helpers extract typed values out of a `Map<String, Object?>`
// decoded by `dart:convert`'s `jsonDecode`, with safe fallbacks on
// shape mismatch (missing key, null value, wrong runtime type).
//
// They are pure functions: no I/O, no allocation beyond the return
// type, no exceptions raised on shape mismatch. The caller decides
// whether a missing key is a hard error (raise their own typed
// exception) or a soft fallback (use the helper's default).
//
// Numeric helpers accept `num` and narrow to the requested type.
// `dart:convert` produces `int` for integer literals and `double`
// for fractional literals; using `num` keeps the helper resilient
// to either.
//
// Origin: extracted from the duplicated shape-read patterns across
// `tom_brain_substrate`'s `ollama_http_client.dart`,
// `openai_http_client.dart`, and several decode sites in the web /
// MCP layers. The rule-of-three was reached at B.43; B.44 is the
// extraction step. See `prototype_implementation_details.md` § B.44
// for the full extraction inventory.

/// Static-only namespace for pure JSON shape helpers.
///
/// The class itself is non-constructible. Every helper is a static
/// function on `Map<String, Object?>`, the canonical shape returned
/// by `dart:convert`'s `jsonDecode` when the top-level token is a
/// JSON object.
///
/// Used by every Tom Brain component that decodes JSON from an
/// external system:
///
///   * substrate — LLM HTTP clients, web search / fetch JSON
///     responses, MCP envelopes.
///   * memory — MCP server payload parsing, snapshot deserialization.
///   * planning / creation / procedure stores — on-disk JSON.
///
/// The helpers never throw on shape mismatch. Either:
///   * the helper has a `fallback` parameter, and the caller passes
///     the value to use when the key is missing / wrong-shaped, or
///   * the helper returns a nullable type, and the caller decides
///     what `null` means in context.
///
/// Two helpers (`requireMap`, `requireList`) bridge the predicate
/// pattern when the caller already validated the shape upstream
/// and wants a typed value without re-checking — they cast and
/// throw `JsonShapeException` if the cast fails. These exist
/// because the substrate's HTTP clients already check the shape
/// of the top-level response and only need the typed handle to
/// dispatch on; an extra `is` test at every read site is dead
/// weight there.
final class JsonShape {
  /// Suppresses the implicit public constructor; the class is a
  /// static-only namespace.
  JsonShape._();

  // --- Strings -------------------------------------------------------------

  /// Reads `json[key]` as a `String`. Returns [fallback] when the key
  /// is missing, the value is null, or the value is not a string.
  static String readString(
    Map<String, Object?> json,
    String key, {
    String fallback = '',
  }) {
    final v = json[key];
    return v is String ? v : fallback;
  }

  /// Reads `json[key]` as a nullable `String`. Returns `null` when
  /// the key is missing, the value is null, or the value is not a
  /// string.
  static String? readStringN(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is String ? v : null;
  }

  // --- Numerics ------------------------------------------------------------

  /// Reads `json[key]` as an `int`. Accepts any numeric value and
  /// truncates doubles via `num.toInt`. Returns `null` when missing
  /// or non-numeric.
  static int? readIntN(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is num ? v.toInt() : null;
  }

  /// Reads `json[key]` as an `int` with a non-null fallback.
  /// Truncates doubles. Returns [fallback] when missing or
  /// non-numeric.
  static int readInt(
    Map<String, Object?> json,
    String key, {
    int fallback = 0,
  }) {
    final v = json[key];
    return v is num ? v.toInt() : fallback;
  }

  /// Reads `json[key]` as a `double`. Returns `null` when missing
  /// or non-numeric.
  static double? readDoubleN(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is num ? v.toDouble() : null;
  }

  /// Reads `json[key]` as a `double` with a non-null fallback.
  /// Returns [fallback] when missing or non-numeric.
  static double readDouble(
    Map<String, Object?> json,
    String key, {
    double fallback = 0.0,
  }) {
    final v = json[key];
    return v is num ? v.toDouble() : fallback;
  }

  // --- Booleans ------------------------------------------------------------

  /// Reads `json[key]` as a `bool`. Returns [fallback] when missing
  /// or not a bool. Does *not* coerce strings or numerics — JSON's
  /// only bool spelling is `true` / `false`.
  static bool readBool(
    Map<String, Object?> json,
    String key, {
    bool fallback = false,
  }) {
    final v = json[key];
    return v is bool ? v : fallback;
  }

  /// Reads `json[key]` as a nullable `bool`. Returns `null` when
  /// missing or not a bool.
  static bool? readBoolN(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is bool ? v : null;
  }

  // --- Nested objects ------------------------------------------------------

  /// Reads `json[key]` as a `Map<String, Object?>`. Returns `null`
  /// when missing or not a map.
  static Map<String, Object?>? readMapN(
    Map<String, Object?> json,
    String key,
  ) {
    final v = json[key];
    return v is Map<String, Object?> ? v : null;
  }

  /// Reads `json[key]` as a `Map<String, Object?>`. Returns
  /// [fallback] (defaults to an empty const map) when missing or
  /// not a map.
  static Map<String, Object?> readMap(
    Map<String, Object?> json,
    String key, {
    Map<String, Object?> fallback = const <String, Object?>{},
  }) {
    final v = json[key];
    return v is Map<String, Object?> ? v : fallback;
  }

  // --- Lists ---------------------------------------------------------------

  /// Reads `json[key]` as a `List<Object?>`. Returns a fresh empty
  /// list when missing or not a list. The returned list is never
  /// the underlying value — callers may safely mutate it.
  ///
  /// Use [readListN] when "missing" needs to be distinguishable
  /// from "empty".
  static List<Object?> readList(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is List ? v.cast<Object?>() : <Object?>[];
  }

  /// Reads `json[key]` as a `List<Object?>`. Returns `null` when
  /// missing or not a list. The returned list is the underlying
  /// value cast to `List<Object?>`; do not mutate.
  static List<Object?>? readListN(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is List ? v.cast<Object?>() : null;
  }

  /// Reads `json[key]` as a `List<Map<String, Object?>>` by
  /// filtering out any non-map elements. Returns a fresh empty list
  /// when missing, not a list, or the list contains zero maps.
  ///
  /// The most common JSON-array-of-objects shape. Equivalent to
  /// `readList(json, key).whereType<Map<String, Object?>>().toList()`
  /// with the cast collapsed into a single call.
  static List<Map<String, Object?>> readMapList(
    Map<String, Object?> json,
    String key,
  ) {
    final v = json[key];
    if (v is! List) return <Map<String, Object?>>[];
    return v
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
  }

  /// Reads `json[key]` as a `List<double>` by accepting any numeric
  /// element and converting via `num.toDouble`. Returns `null` when
  /// missing or not a list.
  ///
  /// Embedding vectors are the canonical use site: vendors emit
  /// numeric arrays without consistent int/double typing, and the
  /// consumer always wants `List<double>`.
  static List<double>? readDoubleListN(
    Map<String, Object?> json,
    String key,
  ) {
    final v = json[key];
    if (v is! List) return null;
    return v.whereType<num>().map((n) => n.toDouble()).toList(growable: false);
  }

  // --- Casts (throw on mismatch) -------------------------------------------

  /// Casts [value] to `Map<String, Object?>`, throwing
  /// [JsonShapeException] when it is not a map. Used at the top of
  /// an HTTP-response decode after a separate `is Map` check has
  /// guarded the wire-level error path.
  static Map<String, Object?> requireMap(
    Object? value, {
    required String where,
  }) {
    if (value is Map<String, Object?>) return value;
    throw JsonShapeException(
      where: where,
      expected: 'Map<String, Object?>',
      actualType: value.runtimeType,
    );
  }

  /// Casts [value] to `List<Object?>`, throwing [JsonShapeException]
  /// when it is not a list.
  static List<Object?> requireList(
    Object? value, {
    required String where,
  }) {
    if (value is List) return value.cast<Object?>();
    throw JsonShapeException(
      where: where,
      expected: 'List<Object?>',
      actualType: value.runtimeType,
    );
  }
}

/// Thrown by [JsonShape.requireMap] / [JsonShape.requireList] when a
/// cast assertion fails. Carries [where] (a free-form label naming
/// the decode site — e.g. `'OllamaHttpClient.chat response body'`)
/// so the caller-side log message localises the malformed payload
/// without re-deriving the call site from a stack frame.
///
/// Callers translate this to their own typed exception at the
/// boundary. The substrate's HTTP clients wrap it in
/// `OllamaHttpException` / `OpenAiHttpException`; memory wraps it
/// in its MCP error class. There is no need for consumers to catch
/// `JsonShapeException` directly outside the immediate boundary
/// translation.
final class JsonShapeException implements Exception {
  /// Free-form label naming the decode site. Should be human-
  /// readable and stable enough to grep for.
  final String where;

  /// The expected type, as a string (e.g. `'Map<String, Object?>'`).
  final String expected;

  /// The actual runtime type of the value that failed the cast.
  final Type actualType;

  const JsonShapeException({
    required this.where,
    required this.expected,
    required this.actualType,
  });

  @override
  String toString() =>
      'JsonShapeException at $where: expected $expected, got $actualType';
}
