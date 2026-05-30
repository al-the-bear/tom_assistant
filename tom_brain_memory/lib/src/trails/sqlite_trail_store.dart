// SqliteTrailStore — concrete trail subsystem (Plan step A.47).
//
// What this file owns:
//
//   - The four `TomBrainMemory` trail-side methods spec § 3.1
//     names: `openTrail`, `appendTrail`, `closeTrail`, `readTrail`.
//   - The single invariant Plan A.47 calls out:
//
//       "The `Trail` index row is written only after the first
//        JSONL line is durable."
//
//     The store therefore does NOT insert the `trails` row at
//     `openTrail` time. It mints the [TrailId], opens the
//     [TrailWriter], and remembers (in process) that the row is
//     still owed. The next successful `appendTrail` writes the
//     row inside the same call — *after* `TrailWriter.append`
//     returns, i.e. after fsync. A `closeTrail` against a trail
//     that never saw a real append synthesises the outcome line
//     (which itself goes through `appendTrail`), so the same code
//     path also writes the row for "never-actually-used" trails.
//
//   - The four event leaves declared in `trail_events.dart`.
//     `TrailOpened` fires alongside the index-row insert
//     (so it observes the spec § 8.1 "durable + indexed"
//     post-condition). `TrailEntryAppended` fires on every
//     successful append. `TrailClosed` fires after the index row's
//     status / outcome columns are updated. `TrailEntryCorrupted`
//     fires inside `readTrail` on JSONL lines that fail to parse.
//
//   - A basic `readTrail` reader. The reader is intentionally
//     simple — it skips bad lines and emits `TrailEntryCorrupted`
//     events for them. A.48 will replace the line-by-line parse
//     with the streaming reader spec § 8.3 calls for; A.49 will
//     add the end-to-end durability and corruption tests.
//
// What this file does NOT own:
//
//   - The SQLite handle. The store takes a raw `Database` and
//     never closes it (mirrors `SqliteStackApi`).
//   - The `trails/` directory. The store takes an absolute
//     `trailsRoot` path; creation/validation is `MemoryDirectory`'s
//     job.
//   - The `TrailId` generation policy. Production passes
//     [TrailId.generate]; tests inject a deterministic mint.
//   - Recovery of orphan trail files (trails opened but never
//     appended-to before a crash). The file is left on disk; a
//     future sweep at A.49+ will surface them as
//     `TrailEntryCorrupted`-style observability.
//
// Concurrency:
//
//   The store is single-process / single-isolate. Cross-isolate
//   safety is the responsibility of the isolate adapter (A.78+),
//   which serialises trail operations onto the memory isolate.
//   Within a process, two concurrent calls against the same
//   [TrailId] are serialised by [TrailWriter]'s internal future
//   chain (for appends) and by the natural ordering of awaited
//   futures everywhere else.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Clock, SystemClock, TrailId;

import '../api/memory_event.dart';
import 'trail.dart';
import 'trail_events.dart';
import 'trail_writer.dart';

/// In-process status string for the `trails.status` column. The two
/// values mirror the spec § 8 lifecycle: a trail is `active` from
/// the moment its first line is durable, and `closed` once
/// `closeTrail` has both written the outcome line and updated the
/// row.
const String _statusActive = 'active';
const String _statusClosed = 'closed';

/// Concrete trail subsystem backed by `memory.db` (Plan step A.47).
final class SqliteTrailStore {
  /// Live SQLite handle on `memory.db`. Owned by the store opener;
  /// the trail store does NOT close it.
  final Database _db;

  /// Absolute path to the `trails/` directory under the memory
  /// root. Resolved by `MemoryDirectory.openOrCreate` and forwarded
  /// here verbatim.
  final String _trailsRoot;

  /// Time source. Used for `opened_at_*` / `closed_at_*` columns,
  /// for event `occurredAt`, and forwarded to [TrailWriter.open] to
  /// drive the date shard.
  final Clock _clock;

  /// `TrailId` factory. Defaults to [TrailId.generate]; tests
  /// override for determinism.
  final TrailId Function() _idMint;

  /// Optional global sink for `MemoryEvent`s. Wired by the higher-
  /// level store to the same broadcast controller that backs
  /// `TomBrainMemory.events()`.
  final void Function(MemoryEvent)? _eventSink;

  /// Currently-open trails keyed by stringified [TrailId]. An entry
  /// in this map is the source of truth for the "index row not yet
  /// written" flag — the alternative would be a SQL probe on every
  /// append, which is wasteful given that openTrail/appendTrail/
  /// closeTrail are owned single-threadedly by one engine.
  final Map<String, _OpenTrail> _open = <String, _OpenTrail>{};

  bool _closed = false;

  SqliteTrailStore({
    required Database memoryDb,
    required String trailsRoot,
    Clock clock = const SystemClock(),
    TrailId Function()? idMint,
    void Function(MemoryEvent)? eventSink,
  })  : _db = memoryDb,
        _trailsRoot = trailsRoot,
        _clock = clock,
        _idMint = idMint ?? TrailId.generate,
        _eventSink = eventSink;

  /// Closes any still-open trail writers. Does NOT close the
  /// database handle. Idempotent.
  ///
  /// A still-open trail at shutdown is an engine bug (the engine
  /// should `closeTrail` every trail it opens). To preserve the
  /// "no event is ever truly lost" invariant the writer is flushed
  /// + closed here, but the index row is left in `active` status:
  /// the next process to open the store can observe the residue and
  /// either re-attach (engine recovery) or mark it `aborted` (a
  /// reconciliation sweep — out of scope at A.47).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final pending = _open.values.toList();
    _open.clear();
    for (final open in pending) {
      try {
        await open.writer.close();
      } catch (_) {
        // Swallow per-writer close errors; we cannot do anything
        // useful with them at shutdown, and surfacing them would
        // mask whichever original error triggered the shutdown.
      }
    }
  }

  // ─── openTrail ────────────────────────────────────────────────

  /// Opens a per-run trail and returns its id.
  ///
  /// Contract (Plan A.47 / spec § 8.1): does NOT insert the
  /// `trails` row. The row is inserted by the first successful
  /// `appendTrail`, *after* the JSONL line it writes is durable.
  /// Until then the trail exists only in process memory and on the
  /// filesystem (as an empty / partially-written file).
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    _assertOpen();
    final trailId = _idMint();
    final openedAt = _clock.now().toUtc();
    final writer = await TrailWriter.open(
      trailsRoot: _trailsRoot,
      runRef: run,
      clock: _clock,
    );
    _open[trailId.toString()] = _OpenTrail(
      id: trailId,
      runRef: run,
      writer: writer,
      openedAt: openedAt,
    );
    return trailId;
  }

  // ─── appendTrail ──────────────────────────────────────────────

  /// Appends one entry. Fsyncs the JSONL line before returning
  /// (spec § 2.4). On the *first* successful append for a trail,
  /// inserts the `trails` index row inside the same call —
  /// satisfying Plan A.47's "row written only after first JSONL
  /// line is durable" invariant — and emits [TrailOpened] paired
  /// with the [TrailEntryAppended] for the entry itself.
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    _assertOpen();
    final open = _requireOpen(id);
    await open.writer.append(entry);
    // Line is durable. Whether we wrote the index row yet is the
    // gate for emitting `TrailOpened` (and for inserting the row).
    final wasFirst = !open.indexRowWritten;
    if (wasFirst) {
      _insertIndexRow(open);
      open.indexRowWritten = true;
      final at = _clock.now().toUtc();
      _eventSink?.call(
        TrailOpened(
          trailId: open.id,
          runRef: open.runRef,
          jsonlPath: open.writer.path,
          openedAt: open.openedAt,
          occurredAt: at,
          runId: open.runRef.runId,
        ),
      );
    }
    _eventSink?.call(
      TrailEntryAppended(
        trailId: open.id,
        entryKind: entry.kind,
        entryIndex: open.writer.entryCount,
        occurredAt: _clock.now().toUtc(),
        runId: open.runRef.runId,
      ),
    );
  }

  // ─── closeTrail ───────────────────────────────────────────────

  /// Writes the outcome record as the final JSONL line, closes the
  /// underlying writer, updates the index row, and emits
  /// [TrailClosed].
  ///
  /// If the trail saw no real appends, the synthesised outcome
  /// entry is the first durable line on disk — so the same
  /// `appendTrail` path that runs the index-row insert kicks in.
  /// The post-condition is identical either way: file ends with an
  /// `outcome` line, index row is `status='closed'`, and the
  /// outcome column carries the JSON payload.
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    _assertOpen();
    final open = _requireOpen(id);
    final outcomeEntry = TrailEntry.outcome(outcome, at: _clock.now());
    await appendTrail(id, outcomeEntry);
    await open.writer.close();
    final closedAt = _clock.now().toUtc();
    _updateIndexRowOnClose(open, outcome, closedAt);
    _open.remove(open.id.toString());
    _eventSink?.call(
      TrailClosed(
        trailId: open.id,
        outcome: outcome,
        entriesWritten: open.writer.entryCount,
        closedAt: closedAt,
        occurredAt: closedAt,
        runId: open.runRef.runId,
      ),
    );
  }

  // ─── readTrail ────────────────────────────────────────────────

  /// Reads a trail back as a stream of [TrailEntry] values.
  ///
  /// Bad JSONL lines are silently skipped; a [TrailEntryCorrupted]
  /// event is emitted per skip so observers learn about the
  /// corruption. (Spec § 8.3.) The file is found via the in-process
  /// `_open` map when the trail is still active, and via the
  /// `trails` index row otherwise.
  ///
  /// Throws [StateError] when the trail id is unknown — neither in
  /// `_open` nor in the index row. Distinct from "file missing on
  /// disk" which surfaces as a [FileSystemException].
  Stream<TrailEntry> readTrail(TrailId id) async* {
    _assertOpen();
    final path = _resolveJsonlPath(id);
    if (path == null) {
      throw StateError(
        'readTrail: no trail known by id ${id.toString()} '
        '(neither open nor present in the trails index).',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException(
        'readTrail: trail file missing for ${id.toString()}',
        path,
      );
    }
    final raw = await file.readAsString();
    if (raw.isEmpty) return;
    final lines = raw.split('\n');
    var lineNumber = 0;
    for (final line in lines) {
      lineNumber += 1;
      if (line.isEmpty) continue;
      final entry = _tryDecodeEntry(id, line, lineNumber);
      if (entry != null) {
        yield entry;
      }
    }
  }

  // ─── Internal helpers ─────────────────────────────────────────

  void _assertOpen() {
    if (_closed) {
      throw StateError('SqliteTrailStore: store is closed.');
    }
  }

  _OpenTrail _requireOpen(TrailId id) {
    final open = _open[id.toString()];
    if (open == null) {
      throw StateError(
        'SqliteTrailStore: no open trail with id ${id.toString()}. '
        'Call openTrail first (and do not use a TrailId after '
        'closeTrail returns).',
      );
    }
    return open;
  }

  /// Inserts the `trails` row for [open]. Called inside the first
  /// `appendTrail` for that trail, *after* the JSONL line is
  /// durable — never before.
  void _insertIndexRow(_OpenTrail open) {
    final openedAtMs = open.openedAt.millisecondsSinceEpoch;
    final openedAtIso = open.openedAt.toIso8601String();
    _db.execute(
      'INSERT INTO trails ('
      'id, run_id, jsonl_path, status, outcome, '
      'opened_at_ms, opened_at_iso, closed_at_ms, closed_at_iso'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        open.id.toString(),
        open.runRef.runId,
        open.writer.path,
        _statusActive,
        null,
        openedAtMs,
        openedAtIso,
        null,
        null,
      ],
    );
  }

  void _updateIndexRowOnClose(
    _OpenTrail open,
    TrailOutcome outcome,
    DateTime closedAt,
  ) {
    final closedAtMs = closedAt.millisecondsSinceEpoch;
    final closedAtIso = closedAt.toIso8601String();
    final outcomeJson = jsonEncode(<String, Object?>{
      'status': outcome.status.name,
      'summary': outcome.summary,
      if (outcome.details.isNotEmpty) 'details': outcome.details,
      'elapsedMs': outcome.elapsedMs,
    });
    _db.execute(
      'UPDATE trails SET '
      'status = ?, outcome = ?, closed_at_ms = ?, closed_at_iso = ? '
      'WHERE id = ?',
      <Object?>[
        _statusClosed,
        outcomeJson,
        closedAtMs,
        closedAtIso,
        open.id.toString(),
      ],
    );
  }

  String? _resolveJsonlPath(TrailId id) {
    final open = _open[id.toString()];
    if (open != null) return open.writer.path;
    final rows = _db.select(
      'SELECT jsonl_path FROM trails WHERE id = ? LIMIT 1',
      <Object?>[id.toString()],
    );
    if (rows.isEmpty) return null;
    return rows.first['jsonl_path'] as String;
  }

  TrailEntry? _tryDecodeEntry(TrailId id, String line, int lineNumber) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        return _reportCorruption(
          id,
          line,
          lineNumber,
          'JSONL line is not a JSON object',
        );
      }
      final tsRaw = decoded['ts'];
      if (tsRaw is! String) {
        return _reportCorruption(
          id,
          line,
          lineNumber,
          'JSONL line missing or non-string "ts" field',
        );
      }
      final kindRaw = decoded['kind'];
      if (kindRaw is! String) {
        return _reportCorruption(
          id,
          line,
          lineNumber,
          'JSONL line missing or non-string "kind" field',
        );
      }
      final at = DateTime.parse(tsRaw).toUtc();
      final kind = _kindByName(kindRaw);
      if (kind == null) {
        return _reportCorruption(
          id,
          line,
          lineNumber,
          'JSONL line has unknown "kind": $kindRaw',
        );
      }
      // Strip the two reserved keys; the rest is payload.
      final payload = <String, Object?>{
        for (final entry in decoded.entries)
          if (entry.key != 'ts' && entry.key != 'kind') entry.key: entry.value,
      };
      return TrailEntry(at: at, kind: kind, payload: payload);
    } on FormatException catch (e) {
      return _reportCorruption(
        id,
        line,
        lineNumber,
        'FormatException: ${e.message}',
      );
    }
  }

  TrailEntry? _reportCorruption(
    TrailId id,
    String line,
    int lineNumber,
    String reason,
  ) {
    _eventSink?.call(
      TrailEntryCorrupted(
        trailId: id,
        lineNumber: lineNumber,
        rawLength: line.length,
        reason: reason,
        occurredAt: _clock.now().toUtc(),
      ),
    );
    return null;
  }

  static TrailEntryKind? _kindByName(String name) {
    for (final k in TrailEntryKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// In-process bookkeeping for a trail that has been opened but not
/// yet closed. Owned exclusively by [SqliteTrailStore]; never
/// surfaces through the public API.
final class _OpenTrail {
  final TrailId id;
  final ProcedureRunRef runRef;
  final TrailWriter writer;
  final DateTime openedAt;

  /// `true` once the `trails` index row has been inserted. Flipped
  /// inside the first successful `appendTrail`. Reading this field
  /// outside [SqliteTrailStore] is forbidden — see the field's role
  /// in the index-row-after-first-fsync invariant.
  bool indexRowWritten = false;

  _OpenTrail({
    required this.id,
    required this.runRef,
    required this.writer,
    required this.openedAt,
  });
}
