// Durable backing for the session manager's conversation histories
// (persistence of history; umbrella Hard principle 6 — "nothing is ever lost";
// access spec § 21.10).
//
// The [SessionManager] holds every live conversation's running history — the
// global per-(user, channel) defaults and the per-session entries. In the
// prototype's first cut those histories lived only in process memory, so a
// restart wiped them: the brain forgot the user's name the moment it was
// restarted, even though the exchange had just happened (the "doesn't remember
// after restart" defect this layer exists to fix). This store persists the
// whole session-histories snapshot so it survives a restart.
//
// The store is deliberately *domain-blind*: it persists one opaque
// JSON-able document and knows nothing about sessions, channels, or turns. The
// session manager owns the codec between its typed [SessionHistoriesSnapshot]
// and that document (the snapshot's private constructor lives in the same
// file as the manager), so the persistence format is the manager's concern,
// not the store's.
//
// Two implementations, mirroring the edge-state store (P1.4):
//
//   * [MapHistoryStore] — in memory, for tests and for a deployment that opts
//     out of durability (the default when no history directory is configured).
//   * [JsonFileHistoryStore] — one JSON file, written atomically (temp file +
//     rename) so a crash mid-write never leaves a half-written file. A missing
//     file is first boot (empty); a *corrupt* file makes [load] throw rather
//     than silently return empty — a damaged history is a loud failure for an
//     operator to resolve, not a quiet reset that re-introduces the amnesia.

import 'dart:convert';
import 'dart:io';

/// A domain-blind durable store of one opaque JSON document — the session
/// manager's whole conversation-histories snapshot.
///
/// [load] returns the persisted document (empty when nothing has been stored
/// yet) and [save] replaces it. Implementations isolate the caller from their
/// internal state — a map returned by [load] may be mutated freely without
/// affecting the store, and a map passed to [save] is captured, not aliased.
abstract interface class HistoryStore {
  /// Loads the persisted snapshot document. Empty when nothing has been stored
  /// (first boot). Throws [HistoryStoreException] when the backing store exists
  /// but is unreadable or malformed (never returns empty to hide that).
  Map<String, Object?> load();

  /// Replaces the whole persisted snapshot with [snapshot]. A subsequent
  /// [load] returns exactly this document.
  void save(Map<String, Object?> snapshot);
}

/// Raised when a [HistoryStore] backing exists but cannot be read as the
/// expected JSON-object shape.
///
/// Carries a human [message] and the [source] (e.g. the file path) so an
/// operator can find and repair the damaged store. Thrown rather than silently
/// returning empty: a silently-reset history is the restart amnesia the
/// persistence exists to prevent.
final class HistoryStoreException implements Exception {
  /// What went wrong, in operator-readable terms.
  final String message;

  /// The backing source the failure concerns (e.g. the JSON file path).
  final String source;

  /// Builds the exception for [message] concerning [source].
  const HistoryStoreException(this.message, [this.source = '']);

  @override
  String toString() => source.isEmpty
      ? 'HistoryStoreException: $message'
      : 'HistoryStoreException($source): $message';
}

/// In-memory [HistoryStore] — durable only for the process lifetime.
///
/// The default when no history directory is configured (the prototype's
/// original in-process behaviour) and the substitute tests inject. Copies the
/// document in and out so a caller can never reach the stored state by
/// reference.
final class MapHistoryStore implements HistoryStore {
  Map<String, Object?> _snapshot = <String, Object?>{};

  @override
  Map<String, Object?> load() => _copy(_snapshot);

  @override
  void save(Map<String, Object?> snapshot) => _snapshot = _copy(snapshot);

  static Map<String, Object?> _copy(Map<String, Object?> snapshot) =>
      jsonDecode(jsonEncode(snapshot)) as Map<String, Object?>;
}

/// File-backed [HistoryStore] — one JSON file holding the whole snapshot.
///
/// [load] reads and parses the file ({} when it does not exist yet); [save]
/// writes it atomically (a sibling temp file renamed over the target) so a
/// crash mid-write cannot truncate the live file, and a missing parent
/// directory is created on first save. A file that exists but does not parse as
/// a JSON object makes [load] throw [HistoryStoreException].
final class JsonFileHistoryStore implements HistoryStore {
  /// The JSON file this store reads and writes.
  final String path;

  /// Builds a store over the file at [path]. The file need not exist yet — a
  /// missing file is first boot.
  JsonFileHistoryStore(this.path);

  @override
  Map<String, Object?> load() {
    final file = File(path);
    if (!file.existsSync()) return <String, Object?>{};

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw HistoryStoreException('not valid JSON (${e.message})', path);
    }
    if (decoded is! Map) {
      throw HistoryStoreException('expected a JSON object at the root', path);
    }
    return Map<String, Object?>.from(decoded);
  }

  @override
  void save(Map<String, Object?> snapshot) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temp = File('$path.tmp');
    temp.writeAsStringSync(jsonEncode(snapshot), flush: true);
    temp.renameSync(path);
  }
}
