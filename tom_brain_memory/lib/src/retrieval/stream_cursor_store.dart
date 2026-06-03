// StreamCursorStore — durable persistence for `StreamCursor` (§ 9.2).
//
// ─────────────────────────────────────────────────────────────────────
// Why this exists
// ─────────────────────────────────────────────────────────────────────
//
// `memory_specification.md` § 9.2: "Agents iterate over potentially
// huge node sets. `stream(StreamQuery)` returns a cursor-backed
// `Stream<Node>`. Cursors survive process restarts via
// `StreamCursor.save()` / `restore()`." A cognitive agent (Extractor,
// Connector, Synthesizer, …) may walk the full node set over many
// scheduling slots; if the process restarts mid-walk it must resume
// from the last checkpoint instead of starting from zero (Q-A.87.11).
//
// `StreamCursor` itself stays a pure value object (its doc-comment:
// "the cursor is an opaque token from the caller's perspective ...
// concrete encoding is memory's concern"). The durable surface lives
// here, exactly as the migration cursor's durable surface lives on
// `MigrationApi.saveCursor` / `cursor` rather than on `MigrationCursor`.
//
// ─────────────────────────────────────────────────────────────────────
// File layout — and why it mirrors JsonFileMigrationApi
// ─────────────────────────────────────────────────────────────────────
//
// `<root>/checkpoints/stream_<streamId>.json`
//
// The same `checkpoints/` directory that holds migration cursors
// (`restructure_<id>.json`, spec § 11.2). The `stream_` prefix keeps
// the two families disjoint: a stream and a migration may legitimately
// share an id, and the migration's `listInProgress()` directory scan
// filters on the `restructure_` prefix, so a `stream_*.json` file is
// never mistaken for a migration record (and vice versa).
//
// Format (single JSON object):
//
//   {
//     "schemaVersion": 1,
//     "streamId": "extractor_full_walk",
//     "savedAt": "2026-06-03T12:34:56.789Z",
//     "payload": { ... }   // opaque, defined by the stream consumer
//   }
//
// `savedAt` is metadata for operators / debugging; the restored
// `StreamCursor` carries only `streamId` + `payload` (the value type's
// shape). Mirroring `JsonFileMigrationApi`, every write is atomic
// (write-temp-then-rename) and every read is defensive: a truncated,
// non-JSON, or wrong-shape checkpoint degrades to "no cursor" (resume
// from the beginning) rather than throwing — restarting from zero is
// wasteful but correct, because stream writes are idempotent (§ 9.1),
// whereas crashing the agent on a corrupt checkpoint is not.

import 'dart:convert';
import 'dart:io';

import '../store/memory_directory.dart';
import 'stream_query.dart';

/// Durable persistence for a [StreamCursor] (spec § 9.2).
///
/// One cursor per `streamId` (one per agent run). [save] checkpoints
/// the current position; [restore] resumes after a process restart;
/// [clear] discards the checkpoint when a walk completes so the next
/// run of the same stream starts fresh.
abstract class StreamCursorStore {
  /// Persists [cursor] durably, keyed on [StreamCursor.streamId].
  /// A later save for the same id overwrites the prior checkpoint
  /// (last write wins). Survives process restarts.
  Future<void> save(StreamCursor cursor);

  /// Returns the most-recently-saved cursor for [streamId], or `null`
  /// when no checkpoint exists (a fresh stream) or the checkpoint is
  /// unreadable (resume-from-zero, never throws on a corrupt file).
  Future<StreamCursor?> restore(String streamId);

  /// Discards the checkpoint for [streamId]. Idempotent — clearing a
  /// never-saved or already-cleared stream is a no-op.
  Future<void> clear(String streamId);
}

/// File-backed [StreamCursorStore] over a [MemoryDirectory]'s
/// `checkpoints/` directory.
///
/// Construct once per [MemoryDirectory]. Safe across `await`
/// boundaries on a single isolate; not safe across isolates (the
/// rename keeps the file consistent, but two writers would race on the
/// in-memory temp-name counter). Single-writer-per-`streamId` is the
/// contract — one agent run owns one stream.
final class JsonFileStreamCursorStore implements StreamCursorStore {
  /// On-disk schema version embedded in every written file. Bumping
  /// requires a forward-only read-side migration in [_readFile].
  static const int fileSchemaVersion = 1;

  /// Filename prefix. Distinct from `JsonFileMigrationApi`'s
  /// `restructure_` so the two cursor families never collide in the
  /// shared `checkpoints/` directory.
  static const String filenamePrefix = 'stream_';

  /// Filename suffix.
  static const String filenameSuffix = '.json';

  /// Hard cap on `streamId` length. Mirrors the migration-id cap so
  /// `stream_<id>.json` fits comfortably inside POSIX 255-byte
  /// filename limits after prefix + suffix + temp decoration.
  static const int maxStreamIdLength = 128;

  /// Regex `streamId` must match: ASCII letters, digits, underscore,
  /// dot, dash; non-empty; not starting with a dot (defends against
  /// `.hidden` files) or a path separator (defends against traversal).
  static final RegExp _streamIdPattern =
      RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]*$');

  final MemoryDirectory _directory;
  final DateTime Function() _now;
  int _tempCounter = 0;

  /// Constructs a store over [directory] using [clock] for the
  /// `savedAt` stamp. Production passes the default ([DateTime.now]);
  /// tests inject a deterministic stand-in.
  JsonFileStreamCursorStore({
    required MemoryDirectory directory,
    DateTime Function()? clock,
  })  : _directory = directory,
        _now = clock ?? _defaultNow;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  /// The directory under which `stream_*.json` lives.
  String get checkpointsDir => _directory.checkpointsDir;

  @override
  Future<void> save(StreamCursor cursor) async {
    _validateStreamId(cursor.streamId);
    final record = <String, Object?>{
      'schemaVersion': fileSchemaVersion,
      'streamId': cursor.streamId,
      'savedAt': _now().toUtc().toIso8601String(),
      'payload': Map<String, Object?>.from(cursor.payload),
    };
    await _atomicWrite(_fileFor(cursor.streamId), record);
  }

  @override
  Future<StreamCursor?> restore(String streamId) async {
    _validateStreamId(streamId);
    final record = _readIfExists(_fileFor(streamId));
    if (record == null) return null;

    final payload = record['payload'];
    if (payload is! Map) return null;

    return StreamCursor(
      streamId: streamId,
      payload: Map<String, Object?>.from(payload),
    );
  }

  @override
  Future<void> clear(String streamId) async {
    _validateStreamId(streamId);
    final file = _fileFor(streamId);
    try {
      file.deleteSync();
    } on FileSystemException {
      // Tolerate the file already being gone (never-saved, already
      // cleared, or a benign race). A real failure (e.g. permission)
      // that leaves the file in place is re-raised so it is not hidden.
      if (file.existsSync()) rethrow;
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Internals
  // ──────────────────────────────────────────────────────────────

  File _fileFor(String streamId) {
    final path = '${_directory.checkpointsDir}${Platform.pathSeparator}'
        '$filenamePrefix$streamId$filenameSuffix';
    return File(path);
  }

  Map<String, Object?>? _readIfExists(File file) {
    if (!file.existsSync()) return null;
    return _readFile(file);
  }

  /// Reads and decodes the checkpoint. Returns `null` when the file is
  /// missing, empty, or contains invalid JSON / an unexpected shape —
  /// the read path never throws (resume-from-zero is correct; a
  /// corrupt checkpoint must not crash the agent's stream).
  Map<String, Object?>? _readFile(File file) {
    try {
      final raw = file.readAsStringSync();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Encodes [record] as JSON and atomically replaces [file] via
  /// write-temp-then-rename. `rename` is atomic on every supported
  /// platform, so a reader sees either the old file or the new file,
  /// never a partial write. On rename failure the temp file is removed
  /// before the original error is re-raised.
  Future<void> _atomicWrite(File file, Map<String, Object?> record) async {
    final json = const JsonEncoder.withIndent('  ').convert(record);
    final tempPath = '${file.path}.tmp.$pid.${_tempCounter++}';
    final tempFile = File(tempPath);

    final raf = await tempFile.open(mode: FileMode.write);
    try {
      await raf.writeString(json);
      await raf.flush();
    } finally {
      await raf.close();
    }

    try {
      await tempFile.rename(file.path);
    } catch (_) {
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {
          // Swallow the cleanup failure — the original cause is more
          // useful to surface than a secondary I/O issue.
        }
      }
      rethrow;
    }
  }

  void _validateStreamId(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(
        id,
        'streamId',
        'StreamCursorStore: streamId must be non-empty',
      );
    }
    if (id.length > maxStreamIdLength) {
      throw ArgumentError.value(
        id,
        'streamId',
        'StreamCursorStore: streamId must be <= '
            '$maxStreamIdLength characters',
      );
    }
    if (!_streamIdPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'streamId',
        'StreamCursorStore: streamId must match '
            r'[A-Za-z0-9_-][A-Za-z0-9_.-]*',
      );
    }
  }
}
