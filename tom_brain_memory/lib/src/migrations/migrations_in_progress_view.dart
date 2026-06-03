// MigrationsInProgressView — operator-UI surface over the
// long-running migrations subsystem (memory_specification.md § 11.3).
//
// Plan step A.73:
//   "Implement the `migrations_in_progress` view."
//
// ─────────────────────────────────────────────────────────────────────
// What this view is, and what it is NOT
// ─────────────────────────────────────────────────────────────────────
//
// Spec § 11.3 enumerates memory's contribution to the migration
// subsystem as three things:
//
//   1. `MigrationApi` (start / cursor / saveCursor / status)
//   2. Cursor durability across process restarts
//   3. A view (`migrations_in_progress`) that exposes per-migration
//      progress for the operator UI.
//
// A.72 landed (1) and (2) as `JsonFileMigrationApi`, plus a
// `listInProgress()` helper that returns the *raw* `MigrationStatus`
// rows for in-progress migrations. A.73 lands (3) — the formal
// operator-UI surface — as `MigrationsInProgressView`, decorating
// each raw row with derived fields the operator UI needs but the
// dispatcher does not:
//
//   * `progressPercent` — an integer 0..100 for display.
//   * `sinceLastCycleMs` — age of the most recent cycle in
//     milliseconds (`null` until the first `saveCursor`).
//   * `health` — a three-state classification
//     (`neverStarted` / `active` / `stalled`).
//
// The view is **read-only** and **side-effect-free**. It does not
// open files, mutate state, or talk to the substrate. Every snapshot
// is a pure projection over what `MigrationApi.listInProgress()`
// returns at the moment `snapshot()` is called, decorated with a
// view-local clock reading. Two consecutive `snapshot()` calls with
// no underlying state change return rows whose only difference is
// the `at` timestamp and the recomputed `sinceLastCycleMs`.
//
// The view is **not** part of `MigrationApi` (see Q-A.73.1 for the
// rationale). It is constructed by the operator-UI layer over a
// `MigrationApi` instance — the same pattern Tom Forge will use to
// build other operator surfaces over the brain.
//
// ─────────────────────────────────────────────────────────────────────
// Health classification
// ─────────────────────────────────────────────────────────────────────
//
// The `health` field answers the operator's first question: "is this
// migration actually making progress?" The classification rule is
// deterministic and clock-driven:
//
//   * `MigrationHealth.neverStarted` — `lastCycleAt == null`. The
//     migration is registered but no `saveCursor` has landed yet.
//     Spec § 11.4 is explicit that this is a valid steady state
//     (non-completion is allowed); the view labels it rather than
//     hides it.
//   * `MigrationHealth.active` — `lastCycleAt` is within the view's
//     `staleAfter` window. The dispatcher has checkpointed within
//     the freshness budget.
//   * `MigrationHealth.stalled` — `lastCycleAt` is older than
//     `staleAfter`. The migration registered, ran for at least one
//     cycle, then stopped advancing. This is operator-visible but
//     not a failure: a stalled migration is still safe per spec
//     § 11.4. The label tells the operator "look closer" without
//     calling it broken.
//
// `staleAfter` is configurable per view instance. The default of
// 30 minutes matches the spec's implied cadence (the dispatcher's
// idle-cycle reschedule); test code overrides it to seconds. There
// is no "failed" or "errored" state — a migration that genuinely
// failed would surface through `BrainEvent` / `TrailOutcome`
// channels, not this view.
//
// ─────────────────────────────────────────────────────────────────────
// Clock discipline
// ─────────────────────────────────────────────────────────────────────
//
// The view takes an optional `clock` callable (matching the
// `JsonFileMigrationApi` convention) so tests can drive deterministic
// age-classification scenarios. Production passes the default
// (`DateTime.now().toUtc()`). Every `snapshot()` reads the clock
// exactly once and stamps the resulting `MigrationsInProgressSnapshot.at`
// with that reading, so the operator UI can render a consistent
// "as of <timestamp>" header.
//
// ─────────────────────────────────────────────────────────────────────
// What a future operator UI plugs in here
// ─────────────────────────────────────────────────────────────────────
//
// Tom Forge's brain inspector (memory_specification.md § 15) will
// call `snapshot()` on a refresh cadence (manual + per-Nm poll) and
// render the resulting rows as a table:
//
//   id | progress | health | age | summary
//   ---|----------|--------|-----|--------
//
// Sort order is delegated to the underlying `listInProgress()`
// (stable by `migrationId`), so the UI does not need to re-sort
// between snapshots. A future enhancement could add row-level sort
// hints to the snapshot (e.g. "sort by health then id"); the view's
// current contract is "deterministic, alphabetical, decorated".

import 'package:tom_brain_shared/tom_brain_shared.dart' show MigrationApi, MigrationStatus;

/// Health classification for a single migration row in the
/// `migrations_in_progress` view (memory_specification.md § 11.3).
///
/// The three states are exhaustive and mutually exclusive; a
/// migration that has completed is excluded from the view upstream
/// (`MigrationApi.listInProgress` filters complete migrations out
/// before the view sees them).
enum MigrationHealth {
  /// Registered but no `saveCursor` has landed yet.
  /// `MigrationStatus.lastCycleAt == null`.
  neverStarted,

  /// Most recent `saveCursor` is within the view's `staleAfter`
  /// window. The dispatcher is checkpointing on cadence.
  active,

  /// Most recent `saveCursor` is older than `staleAfter`. The
  /// migration registered, ran at least one cycle, then stopped
  /// advancing. Operator-visible but not a failure — spec § 11.4
  /// allows non-completion.
  stalled,
}

/// One row of the `migrations_in_progress` view.
///
/// Wraps the underlying [MigrationStatus] (the raw progress numbers
/// memory tracks) with three operator-UI-only derivations:
///
///   * [progressPercent] — `(status.progress * 100).round()`.
///   * [sinceLastCycleMs] — milliseconds between [at] and
///     `status.lastCycleAt`; `null` when no cycle has happened yet.
///   * [health] — a [MigrationHealth] classification.
final class MigrationProgressRow {
  /// The raw status row this view row was derived from.
  final MigrationStatus status;

  /// The snapshot timestamp this row's derivations were computed
  /// against. Same value as the enclosing
  /// [MigrationsInProgressSnapshot.at]; carried on the row so the
  /// row can be reasoned about independently of the snapshot.
  final DateTime at;

  /// Age (milliseconds) of the most recent `saveCursor`, computed
  /// as `at - status.lastCycleAt`. `null` when
  /// `status.lastCycleAt == null` (no cycle has happened yet).
  ///
  /// May be **negative** when the clock has been adjusted backwards
  /// between `saveCursor` and `snapshot()` — the view does not
  /// clamp the value because the operator should see the anomaly
  /// rather than have it silently rounded away.
  final int? sinceLastCycleMs;

  /// Health classification — see [MigrationHealth].
  final MigrationHealth health;

  const MigrationProgressRow({
    required this.status,
    required this.at,
    required this.sinceLastCycleMs,
    required this.health,
  });

  /// Migration identifier. Forwarded from [status] for ergonomics.
  String get migrationId => status.migrationId;

  /// Progress as an integer 0..100, rounded half-away-from-zero.
  /// Returns `0` when `status.total <= 0`.
  int get progressPercent => (status.progress * 100).round();
}

/// Snapshot of the `migrations_in_progress` view at a single instant.
///
/// Produced by [MigrationsInProgressView.snapshot]. Rows are ordered
/// by `migrationId` — the ordering is inherited from
/// `MigrationApi.listInProgress`.
final class MigrationsInProgressSnapshot {
  /// Wall-clock UTC the snapshot was taken at. The operator UI
  /// uses this for the `as of <timestamp>` header.
  final DateTime at;

  /// The decorated rows, sorted by `migrationId`. Empty when no
  /// in-progress migrations exist.
  final List<MigrationProgressRow> rows;

  const MigrationsInProgressSnapshot({
    required this.at,
    required this.rows,
  });

  /// Convenience: `rows.isEmpty`.
  bool get isEmpty => rows.isEmpty;

  /// Convenience: `rows.isNotEmpty`.
  bool get isNotEmpty => rows.isNotEmpty;

  /// Convenience: `rows.length`.
  int get length => rows.length;
}

/// The `migrations_in_progress` view
/// (memory_specification.md § 11.3).
///
/// A read-only projection over [MigrationApi.listInProgress] that
/// decorates each row with operator-UI fields (progress percent,
/// last-cycle age, health classification). See the file header for
/// the design discussion.
///
/// Construct once per consuming UI; the instance is cheap (it
/// holds a reference to a [MigrationApi], a stale-after window,
/// and a clock callable — no I/O state). Each [snapshot] call
/// produces a fresh, immutable [MigrationsInProgressSnapshot].
final class MigrationsInProgressView {
  /// Default freshness window. Picked to match the spec's implied
  /// idle-cycle reschedule cadence — 30 minutes between checkpoints
  /// is the boundary at which the operator should start asking
  /// "is this still moving?".
  static const Duration defaultStaleAfter = Duration(minutes: 30);

  final MigrationApi _api;
  final Duration _staleAfter;
  final DateTime Function() _now;

  /// Constructs the view over [api].
  ///
  /// [staleAfter] sets the [MigrationHealth.active] /
  /// [MigrationHealth.stalled] boundary; defaults to
  /// [defaultStaleAfter].
  ///
  /// [clock] is injected for deterministic tests; defaults to
  /// `DateTime.now().toUtc()`.
  MigrationsInProgressView({
    required MigrationApi api,
    Duration staleAfter = defaultStaleAfter,
    DateTime Function()? clock,
  })  : _api = api,
        _staleAfter = staleAfter,
        _now = clock ?? _defaultNow {
    if (_staleAfter <= Duration.zero) {
      throw ArgumentError.value(
        staleAfter,
        'staleAfter',
        'MigrationsInProgressView: staleAfter must be > Duration.zero',
      );
    }
  }

  static DateTime _defaultNow() => DateTime.now().toUtc();

  /// The freshness window the view uses to classify rows as
  /// [MigrationHealth.active] vs [MigrationHealth.stalled].
  /// Exposed for the operator UI's "as of, threshold X" header.
  Duration get staleAfter => _staleAfter;

  /// Produces a fresh snapshot.
  ///
  /// Each call: reads the clock once, calls
  /// `api.listInProgress()`, and decorates each row. The returned
  /// snapshot is fully immutable.
  Future<MigrationsInProgressSnapshot> snapshot() async {
    final at = _now().toUtc();
    final statuses = await _api.listInProgress();
    final rows = <MigrationProgressRow>[
      for (final s in statuses) _decorate(s, at),
    ];
    return MigrationsInProgressSnapshot(at: at, rows: rows);
  }

  MigrationProgressRow _decorate(MigrationStatus status, DateTime at) {
    final lastCycle = status.lastCycleAt;
    if (lastCycle == null) {
      return MigrationProgressRow(
        status: status,
        at: at,
        sinceLastCycleMs: null,
        health: MigrationHealth.neverStarted,
      );
    }
    final age = at.difference(lastCycle.toUtc());
    final health = age <= _staleAfter
        ? MigrationHealth.active
        : MigrationHealth.stalled;
    return MigrationProgressRow(
      status: status,
      at: at,
      sinceLastCycleMs: age.inMilliseconds,
      health: health,
    );
  }
}
