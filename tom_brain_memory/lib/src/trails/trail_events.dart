// Trail `MemoryEvent` leaves — observability for the per-run
// JSONL trail subsystem (memory_specification.md § 8 / § 16).
//
// Three of the four events fire on the write path:
//
//   - `TrailOpened`            — emitted by `SqliteTrailStore` *after*
//                                the first JSONL line is durable AND
//                                the `trails` index row has been
//                                inserted. The pairing matters: a
//                                consumer that subscribes to this
//                                event can be certain that
//                                `readTrail(id)` will find both the
//                                file and the index row.
//   - `TrailEntryAppended`     — emitted on every successful append
//                                (after fsync). Carries the entry kind
//                                + the running entry count so an
//                                inspector can render the trail head
//                                without re-reading the file.
//   - `TrailClosed`            — emitted by `closeTrail` once the
//                                outcome line is durable and the index
//                                row has been updated. Carries the
//                                full `TrailOutcome` so observers do
//                                not need a follow-up read.
//
// `TrailEntryCorrupted` is emitted by the corruption-tolerant reader
// on read-time failures (a malformed or truncated JSONL line), so a
// consumer can observe partial-trail recovery without parsing the
// file itself.
//
// Per the per-component convention documented on `MemoryEvent`, the
// `kind` strings are kebab-cased under the `memory.trail-*` namespace.

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryEvent, ProcedureRunRef, TrailEntryKind, TrailId, TrailOutcome;

/// Emitted *after* the first JSONL line for a trail is durable AND
/// the `trails` index row has been inserted (spec § 8.1).
///
/// Subscribers can rely on the pairing: by the time this event
/// fires, `readTrail(trailId)` resolves the file via the index row
/// and the file contains at least one entry.
final class TrailOpened extends MemoryEvent {
  /// The id assigned to the trail at `openTrail` time.
  final TrailId trailId;

  /// The procedure run this trail belongs to.
  final ProcedureRunRef runRef;

  /// Absolute path to the JSONL file on disk.
  final String jsonlPath;

  /// Wall-clock UTC instant at which `openTrail` was invoked. This
  /// is the instant that determines the date shard of [jsonlPath].
  final DateTime openedAt;

  const TrailOpened({
    required this.trailId,
    required this.runRef,
    required this.jsonlPath,
    required this.openedAt,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.trail-opened';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'trailId': trailId.toString(),
        'procedureId': runRef.procedureId,
        'runId': runRef.runId,
        if (runRef.parentRunId != null) 'parentRunId': runRef.parentRunId,
        'jsonlPath': jsonlPath,
        'openedAt': openedAt.toIso8601String(),
      };
}

/// Emitted on every successful (post-fsync) `appendTrail` call.
///
/// The running [entryIndex] is 1-based: the first appended entry on a
/// trail surfaces `entryIndex = 1`, matching the count an operator
/// would see by `wc -l` over the JSONL file.
final class TrailEntryAppended extends MemoryEvent {
  /// The trail this entry was appended to.
  final TrailId trailId;

  /// Kind of the appended entry.
  final TrailEntryKind entryKind;

  /// 1-based index of the entry within the trail file.
  final int entryIndex;

  const TrailEntryAppended({
    required this.trailId,
    required this.entryKind,
    required this.entryIndex,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.trail-entry-appended';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'trailId': trailId.toString(),
        'entryKind': entryKind.name,
        'entryIndex': entryIndex,
      };
}

/// Emitted by `closeTrail` once the outcome line is durable and the
/// index row's status/outcome columns have been updated.
final class TrailClosed extends MemoryEvent {
  /// The closed trail.
  final TrailId trailId;

  /// The full outcome carried by the synthetic `outcome` entry.
  final TrailOutcome outcome;

  /// Number of JSONL lines on disk (including the outcome line).
  final int entriesWritten;

  /// Wall-clock UTC instant at which `closeTrail` completed.
  final DateTime closedAt;

  const TrailClosed({
    required this.trailId,
    required this.outcome,
    required this.entriesWritten,
    required this.closedAt,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.trail-closed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'trailId': trailId.toString(),
        'status': outcome.status.name,
        'summary': outcome.summary,
        if (outcome.details.isNotEmpty) 'details': outcome.details,
        'elapsedMs': outcome.elapsedMs,
        'entriesWritten': entriesWritten,
        'closedAt': closedAt.toIso8601String(),
      };
}

/// Emitted by `readTrail` when a JSONL line cannot be parsed.
///
/// The stream itself silently skips the bad line (spec § 8.3 —
/// "corruption-tolerant readback"). This event is how observers
/// learn that a skip happened so the corruption can be investigated.
///
/// [reason] is a short human-readable description (e.g. "FormatException:
/// Unexpected character"); [rawLength] is the byte length of the
/// offending line — useful to distinguish truncation (partial write)
/// from outright garbage without leaking the raw payload through the
/// event stream.
final class TrailEntryCorrupted extends MemoryEvent {
  /// The trail being read.
  final TrailId trailId;

  /// 1-based line number of the bad line in the JSONL file.
  final int lineNumber;

  /// Byte length of the offending line.
  final int rawLength;

  /// Short human-readable description of why the line failed to parse.
  final String reason;

  const TrailEntryCorrupted({
    required this.trailId,
    required this.lineNumber,
    required this.rawLength,
    required this.reason,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.trail-entry-corrupted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'trailId': trailId.toString(),
        'lineNumber': lineNumber,
        'rawLength': rawLength,
        'reason': reason,
      };
}
