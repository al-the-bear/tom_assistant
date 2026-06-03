// JsonFileMigrationApi — file-backed concrete `MigrationApi`.
//
// Plan step A.72:
//   "Implement `MigrationApi.start`, `cursor`, `saveCursor`, `status`."
//
// ─────────────────────────────────────────────────────────────────────
// Why file-backed (no SQLite table)
// ─────────────────────────────────────────────────────────────────────
//
// `memory_specification.md` § 11.2 names the cursor's persistent
// location explicitly: "A persisted cursor (in
// `checkpoints/restructure_<id>.json`)". The simplest faithful
// implementation puts the *entire* migration record — registration
// metadata + cursor — in that one file. The dispatcher's
// `restructure_tree_v1` is the only caller in normal operation
// (§ 11.3); a JSON-per-migration layout is well-matched to that
// access pattern: one record read per cursor lookup, one atomic
// rewrite per checkpoint, a directory scan for the operator
// `listInProgress()` view.
//
// A SQLite-backed alternative was rejected for A.72:
//
//   * Adding a `long_running_migrations` table would force a schema
//     v2 + chained migrator update, churn every A.27/A.28/A.29 test
//     that hard-codes "v1 is the latest known version", and would
//     duplicate the cursor (file canonical per spec § 11.2 + table
//     shadow), creating a drift-repair burden.
//   * `listInProgress()` is operator-UI surface (spec § 11.3,
//     `migrations_in_progress` view). It is not on a hot path; a
//     directory walk + per-file JSON parse is comfortable for the
//     hundreds-of-rows scale the section anticipates.
//
// See `prototype_implementation_questions.md` Q-A.72.1 for the
// recorded recommended-default.
//
// ─────────────────────────────────────────────────────────────────────
// File layout
// ─────────────────────────────────────────────────────────────────────
//
// `<root>/checkpoints/restructure_<migrationId>.json`
//
// Format (single JSON object):
//
//   {
//     "schemaVersion": 1,
//     "migrationId": "restructure_question_2026_v1",
//     "summary": "Reclassify Question nodes under v3 schema",
//     "perCycleBudget": 200,
//     "totalEstimate": 0,
//     "startedAt": "2026-05-30T12:34:56.789Z",
//     "lastCycleAt": "2026-05-30T13:01:02.345Z",
//     "complete": false,
//     "processedCount": 1400,
//     "position": { ... }   // opaque payload, defined by the migration
//   }
//
// `lastCycleAt`, `processedCount`, and `position` are absent until
// the first `saveCursor` call lands. `complete` and `totalEstimate`
// default to `false` / `0` respectively.
//
// `processedCount` and `complete` are derived from the
// `position` map by convention: the dispatcher's migration script
// SHOULD include `processed` (int) and `complete` (bool) keys in
// the position payload on every `saveCursor` call. When present,
// they are mirrored into the dedicated columns so `status()` and
// `listInProgress()` can answer without inspecting `position`. When
// absent, the prior values are retained — `processedCount` stays
// at the last value reported (or `0` if never reported); `complete`
// stays `false`. See `prototype_implementation_questions.md`
// Q-A.72.2 for the rationale of this convention.
//
// ─────────────────────────────────────────────────────────────────────
// Atomic rewrite
// ─────────────────────────────────────────────────────────────────────
//
// Every write to the file goes through write-temp-then-rename:
//
//   1. Encode the full record to JSON.
//   2. Write the JSON to `<file>.tmp.<pid>.<counter>`.
//   3. `flush` + `sync` the temp file's contents (POSIX `fsync`).
//   4. `rename` the temp to the canonical path. On every supported
//      platform `rename` is atomic — a reader either sees the old
//      file or the new file, never a partial write.
//
// The temp filename embeds the pid plus a per-instance counter so
// two concurrent writes inside the same process (which is an error
// — `MigrationApi` is single-writer per id by contract) cannot
// collide on the temp name; the second writer overwrites only its
// own temp file before its own rename. The post-rename canonical
// file is always one of the two complete payloads.
//
// ─────────────────────────────────────────────────────────────────────
// Idempotency on `start`
// ─────────────────────────────────────────────────────────────────────
//
// `start(decl)` is idempotent on `decl.migrationId`. On the second
// call with the same id:
//
//   * If the existing file's `summary` / `perCycleBudget` differ,
//     the new values are accepted (the dispatcher may have rev'd
//     the procedure declaration). All cursor-side fields
//     (`lastCycleAt`, `processedCount`, `complete`, `position`)
//     are preserved untouched.
//   * If the file is missing, it is created fresh — the registry
//     is rebuilt from the surviving file set on every start, so a
//     deleted file lets a brand-new registration take its place.
//
// `start()` does NOT compute the candidate count. `totalEstimate`
// is taken from `decl.initialTotal` if supplied (a future extension
// of `MigrationDecl`), otherwise `0`. Spec § 11.3 calls the count
// "approximate; counted at start of the migration"; A.72 leaves
// the seeding to the dispatcher because counting requires a
// `StreamQuery` runner that landed at A.62 but is not the
// migration API's responsibility to invoke.
//
// ─────────────────────────────────────────────────────────────────────
// Filename safety
// ─────────────────────────────────────────────────────────────────────
//
// Spec § 11.3 names `migrationId` as a string under the
// dispatcher's control. To prevent path traversal or filesystem
// surprises, `migrationId` is constrained to
// `[A-Za-z0-9_.-]{1,128}`. Any other value raises
// `ArgumentError` from `start` / `cursor` / `saveCursor` /
// `status` before any I/O. This is a defensive boundary check —
// the dispatcher should always pass well-formed ids, but a typo
// or a tainted reload from a malformed `Procedure` node would
// otherwise turn into a filesystem write outside the checkpoints
// directory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../store/memory_directory.dart';
import 'migration_api.dart';

/// File-backed concrete [MigrationApi] for the brain's long-running
/// migrations (memory_specification.md § 11).
///
/// Construct once per [MemoryDirectory]; the instance owns the
/// `checkpoints/restructure_<id>.json` layout under that directory.
/// Safe to share across `await` boundaries on a single isolate;
/// not safe across isolates (the file-rename atomicity protects
/// the file but two writers would still race on the in-memory
/// temp-name counter).
final class JsonFileMigrationApi implements MigrationApi {
  /// On-disk schema version embedded in every written file. Bumping
  /// requires a forward-only read-side migration in `_decode`.
  static const int fileSchemaVersion = 1;

  /// Filename prefix per spec § 11.2.
  static const String filenamePrefix = 'restructure_';

  /// Filename suffix.
  static const String filenameSuffix = '.json';

  /// Hard cap on [migrationId] length. Picked to comfortably fit
  /// inside POSIX 255-byte filename limits after prefix + suffix
  /// and any temp-file decoration.
  static const int maxMigrationIdLength = 128;

  /// Regex `migrationId` must match. ASCII letters, digits,
  /// underscore, dot, dash; non-empty; not starting with a dot
  /// (defends against `.hidden` files).
  static final RegExp _migrationIdPattern =
      RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]*$');

  /// Convention key in `position` for the dispatcher to report
  /// processed-count via [saveCursor]. See file header.
  static const String positionProcessedKey = 'processed';

  /// Convention key in `position` for the dispatcher to report
  /// migration completion via [saveCursor]. See file header.
  static const String positionCompleteKey = 'complete';

  /// Convention key in `position` for the dispatcher to refresh
  /// the candidate-total estimate via [saveCursor]. See file
  /// header. Optional — `totalEstimate` only changes when this
  /// key is present.
  static const String positionTotalKey = 'total';

  final MemoryDirectory _directory;
  final DateTime Function() _now;
  int _tempCounter = 0;

  /// Constructs an api over [directory] using [clock] for
  /// `startedAt` / `lastCycleAt` stamps.
  ///
  /// Production passes the default ([DateTime.now]); tests inject
  /// a deterministic stand-in.
  JsonFileMigrationApi({
    required MemoryDirectory directory,
    DateTime Function()? clock,
  })  : _directory = directory,
        _now = clock ?? _defaultNow;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  /// The directory under which `restructure_*.json` lives.
  /// Exposed for tests and the future operator-UI bridge.
  String get checkpointsDir => _directory.checkpointsDir;

  @override
  Future<void> start(MigrationDecl decl) async {
    _validateMigrationId(decl.migrationId);
    if (decl.perCycleBudget <= 0) {
      throw ArgumentError.value(
        decl.perCycleBudget,
        'decl.perCycleBudget',
        'MigrationApi.start: perCycleBudget must be > 0',
      );
    }
    if (decl.summary.isEmpty) {
      throw ArgumentError.value(
        decl.summary,
        'decl.summary',
        'MigrationApi.start: summary must be non-empty',
      );
    }

    final file = _fileFor(decl.migrationId);
    final existing = _readIfExists(file);

    final Map<String, Object?> record;
    if (existing == null) {
      // Fresh registration — stamp `startedAt`, leave cursor fields
      // unset.
      record = <String, Object?>{
        'schemaVersion': fileSchemaVersion,
        'migrationId': decl.migrationId,
        'summary': decl.summary,
        'perCycleBudget': decl.perCycleBudget,
        'totalEstimate': 0,
        'startedAt': _now().toIso8601String(),
        'complete': false,
        'processedCount': 0,
        // `lastCycleAt` and `position` deliberately absent.
      };
    } else {
      // Idempotent re-call. Accept summary / perCycleBudget updates
      // (the dispatcher may have rev'd the declaration), preserve
      // every cursor-side field untouched.
      record = Map<String, Object?>.from(existing);
      record['summary'] = decl.summary;
      record['perCycleBudget'] = decl.perCycleBudget;
      // Re-stamp `schemaVersion` in case the existing file predates
      // the current version — this is the forward-only repair point.
      record['schemaVersion'] = fileSchemaVersion;
    }

    await _atomicWrite(file, record);
  }

  @override
  Future<MigrationCursor?> cursor(String migrationId) async {
    _validateMigrationId(migrationId);
    final file = _fileFor(migrationId);
    final record = _readIfExists(file);
    if (record == null) return null;

    final position = record['position'];
    if (position is! Map) return null;

    // Defensive: a hand-edited or older-schema checkpoint may carry a
    // non-ISO-8601 `lastCycleAt`. The read contract (file header)
    // promises never to throw, so a malformed timestamp degrades to
    // "no cursor" rather than a FormatException.
    final savedAt = _parseTimestampOrNull(record['lastCycleAt']);
    if (savedAt == null) return null;

    return MigrationCursor(
      migrationId: migrationId,
      position: Map<String, Object?>.from(position),
      savedAt: savedAt,
    );
  }

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {
    _validateMigrationId(migrationId);

    final file = _fileFor(migrationId);
    final existing = _readIfExists(file);
    if (existing == null) {
      throw StateError(
        'MigrationApi.saveCursor: no migration registered under '
        'id "$migrationId"; call start(decl) first',
      );
    }

    final record = Map<String, Object?>.from(existing);
    final at = _now().toUtc();
    record['lastCycleAt'] = at.toIso8601String();
    record['position'] = Map<String, Object?>.from(position);

    // Convention-driven mirroring (see file header) — pulls
    // `processed` / `complete` / `total` from the position map onto
    // dedicated fields so the operator-UI view can answer without
    // parsing the opaque payload. Missing keys are no-ops; the prior
    // mirrored values are retained.
    //
    // `processed` / `total` accept any non-negative integral `num`:
    // a count that round-tripped through JSON/YAML as `200.0` is still
    // a valid count, and silently dropping it would stall
    // `processedCount` with no diagnostic.
    final processed = _asNonNegativeIntOrNull(position[positionProcessedKey]);
    if (processed != null) {
      record['processedCount'] = processed;
    }
    final complete = position[positionCompleteKey];
    if (complete is bool) {
      record['complete'] = complete;
    }
    final total = _asNonNegativeIntOrNull(position[positionTotalKey]);
    if (total != null) {
      record['totalEstimate'] = total;
    }

    await _atomicWrite(file, record);
  }

  @override
  Future<MigrationStatus?> status(String migrationId) async {
    _validateMigrationId(migrationId);
    final file = _fileFor(migrationId);
    final record = _readIfExists(file);
    if (record == null) return null;
    return _recordToStatus(record, migrationId);
  }

  @override
  Future<List<MigrationStatus>> listInProgress() async {
    // A.72 lands the directory-scan implementation. A.73 adds the
    // formal `migrations_in_progress` view contract on top.
    final dir = Directory(_directory.checkpointsDir);
    if (!dir.existsSync()) return const <MigrationStatus>[];

    final results = <MigrationStatus>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = _filenameOf(entity.path);
      if (!name.startsWith(filenamePrefix) ||
          !name.endsWith(filenameSuffix)) {
        continue;
      }
      final record = _readFile(entity);
      if (record == null) continue;
      // Skip migrations that are already complete — the view is for
      // *in-progress* ones. Completed migrations are still discoverable
      // via `status(id)` which walks the same file.
      if (record['complete'] == true) continue;
      // The filename, not the (possibly corrupt) record body, is the
      // authoritative migration id.
      final id = name.substring(
        filenamePrefix.length,
        name.length - filenameSuffix.length,
      );
      results.add(_recordToStatus(record, id));
    }

    // Stable ordering by migrationId so consumers see deterministic
    // sequences across calls.
    results.sort((a, b) => a.migrationId.compareTo(b.migrationId));
    return results;
  }

  // ──────────────────────────────────────────────────────────────
  // Internals
  // ──────────────────────────────────────────────────────────────

  File _fileFor(String migrationId) {
    final path =
        '${_directory.checkpointsDir}${Platform.pathSeparator}'
        '$filenamePrefix$migrationId$filenameSuffix';
    return File(path);
  }

  String _filenameOf(String path) {
    final sep = Platform.pathSeparator;
    final idx = path.lastIndexOf(sep);
    return idx < 0 ? path : path.substring(idx + sep.length);
  }

  Map<String, Object?>? _readIfExists(File file) {
    if (!file.existsSync()) return null;
    return _readFile(file);
  }

  /// Reads and decodes the file. Returns `null` when the file is
  /// missing, empty, or contains invalid JSON / unexpected shape —
  /// the migration API never throws on read because spec § 11.4
  /// allows non-completion; a corrupt checkpoint should not crash
  /// the dispatcher's status sweep.
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

  /// Encodes [record] as JSON and atomically replaces [file].
  ///
  /// Sequence:
  ///
  ///   1. Encode → bytes.
  ///   2. Write to `<file>.tmp.<pid>.<counter>`.
  ///   3. Flush + (best-effort) `RandomAccessFile.flush` on the
  ///      temp handle.
  ///   4. Rename temp → canonical path.
  ///
  /// On rename failure the temp file is removed so a partial state
  /// is not left behind. `rename` is atomic on every supported
  /// platform; the file at the canonical path always reads as one
  /// of the two complete payloads.
  Future<void> _atomicWrite(
    File file,
    Map<String, Object?> record,
  ) async {
    final json = const JsonEncoder.withIndent('  ').convert(record);
    final tempPath =
        '${file.path}.tmp.$pid.${_tempCounter++}';
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
      // Defensive: clean up the temp file rather than leaving a
      // half-named artifact behind. A failed rename most likely
      // means a permission or cross-device issue — re-raise after
      // cleanup so the caller sees the original failure.
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {
          // Swallow the cleanup failure — the original cause is
          // more useful to surface than a secondary I/O issue.
        }
      }
      rethrow;
    }
  }

  /// Projects a decoded checkpoint [record] onto a [MigrationStatus].
  ///
  /// [migrationId] is supplied by the caller (the lookup key for
  /// `status`, the filename for `listInProgress`) rather than read
  /// from the record body — the filename is authoritative and a
  /// corrupt/missing `migrationId` field must not crash the read.
  ///
  /// Per the file header the read path never throws: every field is
  /// decoded defensively. A non-integral `totalEstimate`/
  /// `processedCount` that round-tripped through JSON as a `double`
  /// (e.g. `200.0`) is accepted; a malformed `lastCycleAt` degrades
  /// to "no cycle" rather than a FormatException.
  MigrationStatus _recordToStatus(
    Map<String, Object?> record,
    String migrationId,
  ) {
    return MigrationStatus(
      migrationId: migrationId,
      total: _asNonNegativeIntOrNull(record['totalEstimate']) ?? 0,
      processed: _asNonNegativeIntOrNull(record['processedCount']) ?? 0,
      complete: record['complete'] == true,
      lastCycleAt: _parseTimestampOrNull(record['lastCycleAt']),
    );
  }

  /// Returns [raw] as a non-negative `int`, or `null` when it is not a
  /// non-negative integral number. Accepts any `num` that is integral
  /// (so a JSON `200.0` counts as `200`); rejects negatives, NaN, and
  /// non-numeric values.
  static int? _asNonNegativeIntOrNull(Object? raw) {
    if (raw is int) return raw >= 0 ? raw : null;
    if (raw is num && raw >= 0 && raw.isFinite && raw == raw.roundToDouble()) {
      return raw.toInt();
    }
    return null;
  }

  /// Parses an ISO-8601 timestamp into a UTC [DateTime], or `null`
  /// when [raw] is not a parseable string. Uses [DateTime.tryParse]
  /// so a malformed value never throws on the read path.
  static DateTime? _parseTimestampOrNull(Object? raw) {
    if (raw is! String) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toUtc();
  }

  void _validateMigrationId(String id) {
    if (id.isEmpty) {
      throw ArgumentError.value(
        id,
        'migrationId',
        'MigrationApi: migrationId must be non-empty',
      );
    }
    if (id.length > maxMigrationIdLength) {
      throw ArgumentError.value(
        id,
        'migrationId',
        'MigrationApi: migrationId must be <= '
            '$maxMigrationIdLength characters',
      );
    }
    if (!_migrationIdPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'migrationId',
        'MigrationApi: migrationId must match '
            r'[A-Za-z0-9_-][A-Za-z0-9_.-]*',
      );
    }
  }
}
