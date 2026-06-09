// Durable backing for the edge limiters' per-principal state (P1.4).
//
// The rate limiter (E.29) and the daily quota (E.30) each own a per-principal
// map. In the prototype's first cut that map lived only in process memory, so a
// restart reset it — harmless for the burst throttle, but for the *daily* cap a
// restart near the day boundary would hand every principal a fresh allowance, a
// bypass of the cap (Q-E.30.1 / P1.4). This port persists those maps so the
// cap survives a restart.
//
// The store is deliberately *domain-blind*: it persists an opaque
// `principalId → JSON-able row` map and knows nothing about tokens, calls, or
// days. Each limiter owns the codec between its typed snapshot and a row, so
// one store serves both limiters (one file per limiter) and the persistence
// format is the limiter's concern, not the store's.
//
// Two implementations:
//
//   * [MapEdgeStateStore] — in memory, for tests and for a deployment that
//     opts out of durability (the default when no state directory is
//     configured).
//   * [JsonFileEdgeStateStore] — one JSON file per limiter, written atomically
//     (temp file + rename) so a crash mid-write never leaves a half-written
//     file. A missing file is first boot (empty); a *corrupt* file makes
//     [load] throw rather than silently return empty — silently resetting is
//     exactly the cap bypass this layer exists to prevent, so a damaged file is
//     a loud failure for an operator to resolve, not a quiet reset.
//
// Why save synchronously on every admitted request. The limiters' `check` is
// synchronous and runs once per inbound prompt. Prompts are slow (a full
// thinking loop), so a synchronous file write per admitted request is not a
// performance concern (P1.4 user note) and keeps `check` synchronous — no
// async colouring leaks into the edge chain.

import 'dart:convert';
import 'dart:io';

/// A domain-blind durable store of `principalId → opaque JSON row`.
///
/// The edge limiters persist their per-principal state through this port. A
/// row is any JSON-encodable map; the store neither inspects nor interprets it.
/// [load] returns the persisted rows (empty when nothing has been stored yet)
/// and [save] replaces the whole set. Implementations isolate the caller from
/// their internal state — a map returned by [load] may be mutated freely
/// without affecting the store, and a map passed to [save] is captured, not
/// aliased.
abstract interface class EdgeStateStore {
  /// Loads every persisted row, keyed by `principalId`. Empty when nothing has
  /// been stored. Throws [EdgeStateStoreException] when the backing store
  /// exists but is unreadable or malformed (never returns empty to hide that).
  Map<String, Map<String, Object?>> load();

  /// Replaces the whole persisted set with [rows]. A subsequent [load] returns
  /// exactly these rows.
  void save(Map<String, Map<String, Object?>> rows);
}

/// Raised when a [EdgeStateStore] backing exists but cannot be read as the
/// expected `principalId → row` shape.
///
/// Carries a human [message] and the [source] (e.g. the file path) so an
/// operator can find and repair the damaged store. Thrown rather than silently
/// returning empty: a silently-reset quota is the restart-near-the-day-boundary
/// bypass the persistence exists to prevent.
final class EdgeStateStoreException implements Exception {
  /// What went wrong, in operator-readable terms.
  final String message;

  /// The backing source the failure concerns (e.g. the JSON file path).
  final String source;

  /// Builds the exception for [message] concerning [source].
  const EdgeStateStoreException(this.message, [this.source = '']);

  @override
  String toString() => source.isEmpty
      ? 'EdgeStateStoreException: $message'
      : 'EdgeStateStoreException($source): $message';
}

/// In-memory [EdgeStateStore] — durable only for the process lifetime.
///
/// The default when no state directory is configured (the prototype's original
/// in-process behaviour) and the substitute tests inject. Copies rows in and
/// out so a caller can never reach the stored state by reference.
final class MapEdgeStateStore implements EdgeStateStore {
  Map<String, Map<String, Object?>> _rows = {};

  @override
  Map<String, Map<String, Object?>> load() => _copy(_rows);

  @override
  void save(Map<String, Map<String, Object?>> rows) => _rows = _copy(rows);

  static Map<String, Map<String, Object?>> _copy(
    Map<String, Map<String, Object?>> rows,
  ) =>
      <String, Map<String, Object?>>{
        for (final entry in rows.entries)
          entry.key: Map<String, Object?>.from(entry.value),
      };
}

/// File-backed [EdgeStateStore] — one JSON file per limiter.
///
/// [load] reads and parses the file ({} when it does not exist yet);
/// [save] writes it atomically (a sibling temp file renamed over the target) so
/// a crash mid-write cannot truncate the live file and a missing parent
/// directory is created on first save. A file that exists but does not parse as
/// `principalId → object` makes [load] throw [EdgeStateStoreException].
final class JsonFileEdgeStateStore implements EdgeStateStore {
  /// The JSON file this store reads and writes.
  final String path;

  /// Builds a store over the file at [path]. The file need not exist yet — a
  /// missing file is first boot.
  JsonFileEdgeStateStore(this.path);

  @override
  Map<String, Map<String, Object?>> load() {
    final file = File(path);
    if (!file.existsSync()) return <String, Map<String, Object?>>{};

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw EdgeStateStoreException('not valid JSON (${e.message})', path);
    }
    if (decoded is! Map) {
      throw EdgeStateStoreException('expected a JSON object at the root', path);
    }

    final rows = <String, Map<String, Object?>>{};
    decoded.forEach((key, value) {
      if (value is! Map) {
        throw EdgeStateStoreException(
          "row '$key' is not a JSON object",
          path,
        );
      }
      rows[key as String] = Map<String, Object?>.from(value);
    });
    return rows;
  }

  @override
  void save(Map<String, Map<String, Object?>> rows) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temp = File('$path.tmp');
    temp.writeAsStringSync(jsonEncode(rows), flush: true);
    temp.renameSync(path);
  }
}
