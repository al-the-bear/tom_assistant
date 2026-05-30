// MigrationApi — long-running structural migrations
// (memory_specification.md § 11).
//
// A migration is a `Procedure` node with a query that enumerates
// candidates, a per-cycle budget, and a persisted cursor in
// `checkpoints/restructure_<id>.json`. The dispatcher runs
// `restructure_tree_v1` against this API; memory owns durability of
// the cursor.
//
// At A.24 the API is declared but unimplemented (lands at A.72).

import '../retrieval/stream_query.dart' show StreamQuery;

/// Declaration handed to `MigrationApi.start`.
final class MigrationDecl {
  /// Stable id for the migration. Matching `checkpoints/` filename
  /// is derived from this.
  final String migrationId;

  /// One-line summary kept on the underlying `Procedure` node.
  final String summary;

  /// Query that enumerates candidate nodes for this migration.
  final StreamQuery candidates;

  /// Per-cycle node budget — the dispatcher pulls this many
  /// candidates per scheduling slot.
  final int perCycleBudget;

  const MigrationDecl({
    required this.migrationId,
    required this.summary,
    required this.candidates,
    required this.perCycleBudget,
  });
}

/// Persisted cursor state for one migration.
///
/// The cursor survives process restarts; the dispatcher resumes
/// from `position` after a restart with no replay.
final class MigrationCursor {
  final String migrationId;

  /// Last-completed position. The shape is opaque to consumers; the
  /// migration script defines it.
  final Map<String, Object?> position;

  /// Wall-clock UTC of the last `saveCursor` call.
  final DateTime savedAt;

  const MigrationCursor({
    required this.migrationId,
    required this.position,
    required this.savedAt,
  });
}

/// Status report returned by `MigrationApi.status`.
final class MigrationStatus {
  final String migrationId;

  /// Total candidate count at start (approximate; counted at start
  /// of the migration).
  final int total;

  /// Number processed so far.
  final int processed;

  /// True when no more candidates remain.
  final bool complete;

  /// Wall-clock UTC of the last cycle.
  final DateTime? lastCycleAt;

  const MigrationStatus({
    required this.migrationId,
    required this.total,
    required this.processed,
    required this.complete,
    this.lastCycleAt,
  });

  /// Fractional progress in [0.0, 1.0]. Returns 0.0 when [total] is 0.
  double get progress => total <= 0 ? 0.0 : processed / total;
}

/// Surface returned by `TomBrainMemory.migrations`.
///
/// Used by the dispatcher's restructure scripts. The MCP server v1
/// does NOT expose this surface — migrations are an internal
/// concern.
abstract class MigrationApi {
  /// Registers a migration. Idempotent on [MigrationDecl.migrationId].
  Future<void> start(MigrationDecl decl);

  /// Returns the current cursor for [migrationId], or `null` when
  /// the migration has never checkpointed (fresh start state).
  Future<MigrationCursor?> cursor(String migrationId);

  /// Persists a new cursor position. Durable across process
  /// restarts.
  Future<void> saveCursor(String migrationId, Map<String, Object?> position);

  /// Returns progress for [migrationId], or `null` when no
  /// migration of that id exists.
  Future<MigrationStatus?> status(String migrationId);

  /// Returns status for every known migration. Used by the
  /// `migrations_in_progress` operator view (§ 11.3).
  Future<List<MigrationStatus>> listInProgress();
}
