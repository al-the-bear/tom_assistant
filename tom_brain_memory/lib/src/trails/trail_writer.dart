// JSONL trail writer — one open trail file per `ProcedureRun`.
//
// Plan step A.46:
//   "Implement JSONL trail writer with `fsync` per append and
//    date-sharded path layout."
//
// Scope at A.46 is intentionally narrow: this file owns the
// **append-and-fsync** primitive over a single trail file. Everything
// above it (engine lifecycle — `openTrail` / `appendTrail` /
// `closeTrail` returning a `TrailId`, the `Trail` index row in
// `memory.db`, the corruption-tolerant reader, the close-emit event)
// is the next three plan steps (A.47 – A.49) and is deliberately not
// here.
//
// Layout (memory_specification.md § 2.1):
//
//   <trails-root>/YYYY/MM/DD/run-<runId>.jsonl
//
// where `YYYY/MM/DD` are derived from the **open-time** UTC date of
// the run, not the per-entry timestamp. A run that crosses UTC
// midnight keeps writing into its original date shard; the run-id is
// the stable identity, not the wall clock. This matches the spec's
// "one trail per run" invariant: the file is the run's identity on
// disk.
//
// Line shape (memory_specification.md § 8.2):
//
//   {
//     "ts": "<ISO-8601 UTC>",
//     "kind": "<TrailEntryKind.name>",
//     ...payload fields spread at top level
//   }
//
// Reserved top-level keys are `ts` and `kind`. A payload that
// contains either is rejected at `append` time — silently letting
// the spread overwrite would mask a bug at the call site (a
// `TrailEntry.primitiveCall` cannot meaningfully redefine `kind`,
// and the JSON-serialised log is the only artifact we have to debug
// a run after the fact).
//
// Durability stance: every `append` awaits `RandomAccessFile.flush()`
// before returning. On POSIX `flush()` is implemented as `fsync(2)`
// and on Windows as `FlushFileBuffers`; in both cases the OS is
// instructed to persist the bytes to durable storage before the
// future completes. The spec's "fsync per append" wording (§ 2.4)
// is taken literally — there is no batching mode at A.46.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart' show CloseGuard;
import 'package:tom_brain_shared/tom_brain_shared.dart' show Clock;

import 'trail.dart';

/// Reserved top-level keys in the JSONL entry. Payloads that contain
/// either are rejected by [TrailWriter.append].
const Set<String> _reservedTopLevelKeys = {'ts', 'kind'};

/// Append-only writer for a single trail file.
///
/// One [TrailWriter] is open per [ProcedureRunRef]. Construct via
/// [TrailWriter.open]; the constructor materialises the date-sharded
/// path and opens the underlying [RandomAccessFile] in append mode.
///
/// The writer is **not** thread-safe across isolates — the design
/// contract is one writer per run, owned by the engine, and an engine
/// owns its runs single-threadedly. Concurrent calls to [append] on
/// the same instance are serialised by an internal future chain, so
/// callers do not need to serialise themselves; that serialisation
/// matters only for the rare case where two primitive bridges fire
/// back-to-back without awaiting (and is cheap when they do not).
final class TrailWriter with CloseGuard {
  /// Absolute path to the trail file this writer owns.
  ///
  /// Resolved at [open] time from `<trailsRoot>/YYYY/MM/DD/run-<runId>.jsonl`
  /// using the UTC date returned by the injected [Clock].
  final String path;

  /// The run this trail file belongs to. Carried as a field so
  /// observers (tests, inspectors) can read it without re-parsing
  /// the path.
  final ProcedureRunRef runRef;

  final RandomAccessFile _raf;

  /// Number of JSONL lines successfully appended (and fsync'd) so far.
  ///
  /// Incremented only after [RandomAccessFile.flush] returns — a
  /// failed write or fsync does **not** bump the count. Useful for
  /// tests that want to assert "n entries are durable on disk".
  int get entryCount => _entryCount;
  int _entryCount = 0;

  /// Internal future chain that serialises overlapping [append] calls
  /// on the same writer. Each `append` chains onto the previous
  /// future so the JSON line write + fsync happen atomically with
  /// respect to other appends, preserving append-order on disk.
  Future<void> _tail = Future<void>.value();

  TrailWriter._({
    required this.path,
    required this.runRef,
    required RandomAccessFile raf,
  }) : _raf = raf;

  /// Opens (or re-opens) the trail file for [runRef] under
  /// [trailsRoot], creating any missing date-shard directories along
  /// the way.
  ///
  /// The file is opened in [FileMode.writeOnlyAppend]. If a file
  /// already exists at the resolved path (crash recovery / re-open),
  /// subsequent [append] calls extend it rather than truncating —
  /// the run's existing trail is preserved.
  ///
  /// [clock] supplies the UTC instant used for the `YYYY/MM/DD`
  /// shard. Tests pass a `FixedClock` or `MutableTestClock` so the
  /// shard is deterministic across runs.
  static Future<TrailWriter> open({
    required String trailsRoot,
    required ProcedureRunRef runRef,
    required Clock clock,
  }) async {
    if (trailsRoot.isEmpty) {
      throw ArgumentError.value(
        trailsRoot,
        'trailsRoot',
        'trails root path must be non-empty',
      );
    }
    if (runRef.runId.isEmpty) {
      throw ArgumentError.value(
        runRef.runId,
        'runRef.runId',
        'runId must be non-empty (engine should assign a ULID at dispatch)',
      );
    }

    final openedAt = clock.now().toUtc();
    final shard = _dateShard(openedAt);
    final shardDir = Directory(_join(trailsRoot, shard));
    if (!shardDir.existsSync()) {
      shardDir.createSync(recursive: true);
    }

    final filePath = _join(shardDir.absolute.path, 'run-${runRef.runId}.jsonl');
    final file = File(filePath);
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    return TrailWriter._(
      path: file.absolute.path,
      runRef: runRef,
      raf: raf,
    );
  }

  /// Appends one [TrailEntry] as a single JSONL line and fsyncs the
  /// file before returning.
  ///
  /// On a successful return the bytes are durable: a crash
  /// immediately after the future completes still leaves the line
  /// readable by [TrailReader] (A.48).
  ///
  /// Throws [StateError] if called after [close]. Throws
  /// [ArgumentError] if [entry]'s payload contains a reserved
  /// top-level key (`ts` or `kind`).
  Future<void> append(TrailEntry entry) {
    if (isClosed) {
      throw StateError(
        'TrailWriter for ${runRef.runId} is closed; cannot append.',
      );
    }
    final collidingKeys = entry.payload.keys
        .where(_reservedTopLevelKeys.contains)
        .toList(growable: false);
    if (collidingKeys.isNotEmpty) {
      throw ArgumentError.value(
        entry.payload,
        'entry.payload',
        'payload contains reserved top-level key(s): $collidingKeys. '
            'Reserved keys are $_reservedTopLevelKeys (they are filled by '
            'the writer from entry.at / entry.kind).',
      );
    }

    final next = _tail.then((_) => _writeOne(entry));
    // Swallow errors on the chain itself so a single failed append
    // does not poison subsequent ones; the caller of the failing
    // append sees the error via the returned future, which still
    // resolves normally from `next`. Subsequent appends just continue
    // from the file's post-failure position.
    _tail = next.then(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _writeOne(TrailEntry entry) async {
    final line = _encodeLine(entry);
    final bytes = utf8.encode('$line\n');
    await _raf.writeFrom(bytes);
    await _raf.flush();
    _entryCount += 1;
  }

  /// Closes the underlying file handle. Idempotent.
  ///
  /// After [close] returns, [append] throws [StateError]. The on-disk
  /// file is left as-is; callers that need to record an outcome
  /// should write an `outcome` [TrailEntry] *before* calling [close].
  Future<void> close() async {
    if (!markClosed()) return;
    // Drain any in-flight appends so we never close out from under a
    // pending write.
    try {
      await _tail;
    } catch (_) {
      // Errors from the chain were already surfaced to the original
      // caller; swallow here so close() itself does not throw.
    }
    await _raf.close();
  }

  // --- Encoding ----------------------------------------------------------

  static String _encodeLine(TrailEntry entry) {
    final map = <String, Object?>{
      'ts': entry.at.toUtc().toIso8601String(),
      'kind': entry.kind.name,
      ...entry.payload,
    };
    return json.encode(map);
  }

  // --- Path helpers ------------------------------------------------------

  /// Returns the `YYYY/MM/DD` shard for [at] using UTC components.
  /// Padded with leading zeros so lexicographic sort matches
  /// chronological order — convenient for ops grep and for the
  /// retention sweep in A.49+.
  static String _dateShard(DateTime at) {
    final utc = at.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y${Platform.pathSeparator}$m${Platform.pathSeparator}$d';
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}
