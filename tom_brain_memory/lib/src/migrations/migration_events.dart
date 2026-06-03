// Migration `MemoryEvent` leaf — `MigrationProgressed`.
//
// Spec § 16 names `MigrationProgressed` as one of the typed events
// memory fans out over the single observability stream. The natural
// emission point is `MigrationApi.saveCursor`: every persisted cursor
// advance is one observable step of progress, and the convention-
// mirrored `processed` / `total` / `complete` fields are exactly the
// numbers the event reports.
//
// One event per successful `saveCursor`. A `start` registration does
// not emit (no progress was made yet); a failed write does not emit
// (nothing was persisted). The terminal cycle — the one whose position
// carries `complete: true` — emits with `complete` set, so a
// subscriber sees the completion transition on the same stream.
//
// The discriminator (`memory.migration-progressed`) follows the
// per-component convention documented on `MemoryEvent`. Per the
// `MemoryEvent` base, `runId` is null when the cursor advance happened
// outside any run; the dispatcher's `restructure_tree_v1` threads its
// run scope through when it has one.

import '../api/memory_event.dart';

/// Emitted when `MigrationApi.saveCursor` durably advances a
/// migration's cursor (spec § 16).
///
/// Carries the post-advance progress snapshot: which migration moved,
/// how many candidates it has [processed], the current [total]
/// estimate, and whether the migration is now [complete]. [progress]
/// is the convenience ratio `processed / total` clamped to `[0, 1]`
/// (0.0 when [total] is 0), mirroring `MigrationStatus.progress`.
final class MigrationProgressed extends MemoryEvent {
  /// Stable id of the migration whose cursor advanced.
  final String migrationId;

  /// Candidates processed so far, as mirrored from the cursor
  /// position (`0` when the migration script reported none).
  final int processed;

  /// Current candidate-total estimate (`0` when never seeded).
  final int total;

  /// `true` when this advance carried `complete: true` in its
  /// position payload — the terminal cycle.
  final bool complete;

  const MigrationProgressed({
    required this.migrationId,
    required this.processed,
    required this.total,
    required this.complete,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  /// Fractional progress in `[0.0, 1.0]`. Returns `0.0` when [total]
  /// is `0`. Mirrors `MigrationStatus.progress`.
  double get progress => total <= 0 ? 0.0 : processed / total;

  @override
  String get kind => 'memory.migration-progressed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'migrationId': migrationId,
        'processed': processed,
        'total': total,
        'complete': complete,
        'progress': progress,
      };
}
