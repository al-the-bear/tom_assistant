// BootIntegrityCheck — boot-time integrity check for the memory store.
//
// Plan step A.29:
//   "Boot-time integrity check: schema version, FTS5 availability,
//    `loadExtension` capability, embedding-model marker file."
//
// Role in the open path (will land at A.30):
//
//   1. Host opens `memory.db` via the store opener.
//   2. Host constructs a `BootIntegrityCheck`.
//   3. Host calls `check.run(memoryDb: ..., directory: ..., config: ...)`.
//   4. The check:
//        a. Runs `SchemaMigrator().migrate(db)` — this is the *only*
//           step that may write to `memory.db`; on `SchemaVersionAhead`
//           the exception propagates as-is (it is already the typed
//           hard refusal the operator needs to see).
//        b. Runs four read-only probes against the freshly-migrated
//           database and the on-disk directory:
//             - `schemaVersion`            — DB version matches the
//                                            migrator's `latestKnownVersion`.
//             - `fts5Available`            — SQLite build includes FTS5
//                                            (create+drop a temp FTS5
//                                            virtual table).
//             - `loadExtensionCapable`     — SQLite build was compiled
//                                            with ENABLE_LOAD_EXTENSION
//                                            so the sqlite-vec FFI
//                                            extension (§ 2.2 Option A)
//                                            can be loaded at A.50+.
//             - `embeddingModelMarker`     — placeholder probe; returns
//                                            `skipped` with a reference
//                                            to Q-A.26.2. The marker
//                                            file is owned by A.50+
//                                            (vectors.db schema).
//        c. Aggregates into a `BootIntegrityReport`.
//
// Why the four probes are *named in this file* rather than chosen by
// the migrator or the opener:
//
//   The plan lists four probes by name. Locating them as one labelled
//   list in this file makes the contract auditable (read the file,
//   read the plan, they match). The class is the framework into which
//   later steps add probes — when A.50 introduces the vectors-DB
//   schema and a real embedding-model marker exists on disk, it
//   replaces `defaultEmbeddingMarkerProbe` and nothing else needs to
//   change.
//
// Failure handling philosophy:
//
//   `run()` always returns a complete `BootIntegrityReport`, even
//   when probes fail. The caller decides whether a failed probe is a
//   boot-blocker (most are) or a degraded-mode warning (some, like
//   missing `loadExtensionCapable`, can be tolerated if the operator
//   accepts vector-disabled mode). `BootIntegrityReport.throwIfFailed`
//   is the helper for the common "hard refusal" path; the alternative
//   "degraded boot" path inspects `report.failures` and decides for
//   itself.
//
//   `SchemaVersionAhead` is the exception: it propagates out of
//   `run()` and is *not* caught and wrapped as a failed probe. The
//   reasoning lives in Q-A.29.2 — a DB written by a newer binary is
//   a different class of failure (the brain literally cannot read it
//   safely; there is no degraded mode that helps), and the typed
//   exception already carries the operator-visible message.
//
// Why probes are constructor-injectable:
//
//   Two of the four production probes (FTS5, loadExtension) can only
//   be tested for the *success* path in this workspace, because the
//   bundled `sqlite3` Dart package ships an SQLite build that includes
//   both. Testing the *failure* path requires either swapping the
//   linked binary (out of scope) or injecting a probe that returns
//   failure deterministically. The constructor accepts overrides for
//   exactly this reason — the production wiring uses the defaults,
//   tests pass synthetic probes to drive the failure paths.
//
//   The marker probe is also injectable for symmetry; the default
//   today returns `skipped`, but tests can pass an injected probe
//   that returns `ok` or `failed` to verify the report aggregation
//   handles both branches.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../config/memory_config.dart';
import 'memory_directory.dart';
import 'schema_migrator.dart';
import 'schema_v1.dart' show readSchemaVersion;

/// Outcome category for a single integrity probe.
///
/// Three states, not four:
///
///   * `ok`       — probe ran, invariant holds.
///   * `failed`   — probe ran, invariant violated. The boot-time
///                  caller is expected to refuse to bring the
///                  subsystem up.
///   * `skipped`  — probe applies in principle but the underlying
///                  check is deferred to a later plan step; running
///                  it now would assert nothing useful. A skipped
///                  probe is *not* a failure — the report still
///                  surfaces it so an operator can see the "what is
///                  expected to land at A.50+" set explicitly.
///
/// There is no `warning` band: a probe either holds its invariant
/// or it does not. Soft conditions (e.g. "FTS5 is available but
/// uses an old tokeniser") are different probes with their own
/// boolean outcome, not a half-state on an existing probe.
enum IntegrityProbeStatus { ok, failed, skipped }

/// Result of a single integrity probe.
///
/// Immutable. `cause` carries the originating exception when
/// `status == failed`, so the caller can log structured information
/// without re-running the probe.
final class IntegrityProbeResult {
  /// Stable identifier for the probe. Matches the names listed in
  /// plan step A.29: `schemaVersion`, `fts5Available`,
  /// `loadExtensionCapable`, `embeddingModelMarker`.
  final String name;

  /// What the probe found.
  final IntegrityProbeStatus status;

  /// One-line human-readable summary. For `failed` probes this is
  /// the operator-facing message; for `skipped` probes this names
  /// the step (and / or question) that owns the deferred decision.
  final String summary;

  /// Originating exception when `status == failed`. `null` for
  /// `ok` and `skipped` probes.
  final Object? cause;

  const IntegrityProbeResult({
    required this.name,
    required this.status,
    required this.summary,
    this.cause,
  });

  bool get isOk => status == IntegrityProbeStatus.ok;
  bool get isFailed => status == IntegrityProbeStatus.failed;
  bool get isSkipped => status == IntegrityProbeStatus.skipped;

  @override
  String toString() =>
      'IntegrityProbeResult(name: $name, status: $status, summary: $summary)';
}

/// Default-replaceable signature for the FTS5 probe.
typedef Fts5Probe = IntegrityProbeResult Function(Database db);

/// Default-replaceable signature for the `loadExtension` probe.
typedef LoadExtensionProbe = IntegrityProbeResult Function(Database db);

/// Default-replaceable signature for the embedding-model marker probe.
///
/// The probe is handed the directory (in case the marker is a file
/// inside it) and the config (in case the marker compares against a
/// configured identity). The current default uses neither; the
/// signature exists so A.50+ can swap in a real implementation
/// without changing the call site.
typedef EmbeddingMarkerProbe = IntegrityProbeResult Function(
  MemoryDirectory directory,
  MemoryConfig config,
);

/// Aggregated outcome of one [BootIntegrityCheck.run] call.
///
/// Returned even when probes fail. The caller chooses whether to
/// raise (via [throwIfFailed]) or to continue in a degraded mode.
final class BootIntegrityReport {
  /// The migrator's report. Captured for diagnostics — the caller
  /// can log "schema went from vX to vY" without re-querying the DB.
  final SchemaMigrationReport schemaMigration;

  /// Every probe that ran, in registration order. Frozen so the
  /// caller cannot mutate the report after the fact.
  final List<IntegrityProbeResult> probes;

  /// Wall-clock UTC at which the check started. Captured before the
  /// migrator runs.
  final DateTime startedAt;

  /// Wall-clock UTC at which the check finished. Captured after the
  /// last probe completes.
  final DateTime finishedAt;

  BootIntegrityReport({
    required this.schemaMigration,
    required List<IntegrityProbeResult> probes,
    required this.startedAt,
    required this.finishedAt,
  }) : probes = List.unmodifiable(probes);

  /// Every probe that returned `failed`, in registration order.
  Iterable<IntegrityProbeResult> get failures =>
      probes.where((p) => p.isFailed);

  /// Every probe that returned `skipped`, in registration order.
  Iterable<IntegrityProbeResult> get skipped =>
      probes.where((p) => p.isSkipped);

  /// Every probe that returned `ok`, in registration order.
  Iterable<IntegrityProbeResult> get passed => probes.where((p) => p.isOk);

  /// `true` iff at least one probe failed.
  bool get hasFailures => failures.isNotEmpty;

  /// Wall-clock duration of the check. Non-negative.
  Duration get duration => finishedAt.difference(startedAt);

  /// Raises [BootIntegrityFailure] if any probe failed; no-op when
  /// every probe is `ok` or `skipped`.
  ///
  /// This is the convenience for the most common boot path: the
  /// host wants a hard refusal on any integrity violation. The
  /// alternative (inspect `failures` directly and choose a degraded
  /// mode) is for the rare paths where a partial boot is acceptable
  /// — currently no such caller exists, but the API leaves the door
  /// open.
  void throwIfFailed() {
    if (hasFailures) {
      throw BootIntegrityFailure(
        failures: failures.toList(growable: false),
      );
    }
  }

  @override
  String toString() => 'BootIntegrityReport('
      'schemaFrom: ${schemaMigration.fromVersion}, '
      'schemaTo: ${schemaMigration.toVersion}, '
      'probes: ${probes.length}, '
      'failures: ${failures.length}, '
      'skipped: ${skipped.length})';
}

/// Thrown by [BootIntegrityReport.throwIfFailed] when at least one
/// probe in the report returned `failed`.
///
/// The exception carries the failing probes so the operator-facing
/// message can be assembled by the catch site (or by a top-level
/// `unawaited` reporter); the `toString` produces a multi-line
/// listing suitable for direct logging in the absence of a custom
/// formatter.
final class BootIntegrityFailure implements Exception {
  /// The failing probes, in registration order.
  final List<IntegrityProbeResult> failures;

  const BootIntegrityFailure({required this.failures});

  @override
  String toString() {
    final lines =
        failures.map((f) => '  - ${f.name}: ${f.summary}').join('\n');
    return 'BootIntegrityFailure: ${failures.length} integrity probe(s) '
        'failed:\n$lines';
  }
}

/// Boot-time integrity check for the memory store.
///
/// One instance per process. Holds no per-call state; the same
/// instance can be reused across opens.
final class BootIntegrityCheck {
  final SchemaMigrator _migrator;
  final Fts5Probe _fts5Probe;
  final LoadExtensionProbe _loadExtensionProbe;
  final EmbeddingMarkerProbe _markerProbe;
  final DateTime Function() _now;

  /// Constructs the integrity check.
  ///
  /// All five parameters are optional and have production defaults:
  ///
  ///   * [migrator]            — defaults to `SchemaMigrator()`,
  ///                             i.e. the canonical
  ///                             `kSchemaMigrations` registry.
  ///   * [fts5Probe]           — defaults to [defaultFts5Probe].
  ///   * [loadExtensionProbe]  — defaults to [defaultLoadExtensionProbe].
  ///   * [embeddingMarkerProbe] — defaults to
  ///                             [defaultEmbeddingMarkerProbe] (which
  ///                             returns `skipped` until A.50+).
  ///   * [clock]               — defaults to `DateTime.now().toUtc`.
  ///
  /// Tests pass overrides; production wiring uses the defaults.
  BootIntegrityCheck({
    SchemaMigrator? migrator,
    Fts5Probe? fts5Probe,
    LoadExtensionProbe? loadExtensionProbe,
    EmbeddingMarkerProbe? embeddingMarkerProbe,
    DateTime Function()? clock,
  })  : _migrator = migrator ?? SchemaMigrator(),
        _fts5Probe = fts5Probe ?? defaultFts5Probe,
        _loadExtensionProbe = loadExtensionProbe ?? defaultLoadExtensionProbe,
        _markerProbe = embeddingMarkerProbe ?? defaultEmbeddingMarkerProbe,
        _now = clock ?? _defaultClock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  /// The migrator backing this check. Exposed for diagnostics —
  /// callers may want to log `latestKnownVersion` separately from
  /// the actual check.
  SchemaMigrator get migrator => _migrator;

  /// Runs the boot-time integrity sequence.
  ///
  /// Contract:
  ///
  ///   1. Calls `migrator.migrate(memoryDb)`. On
  ///      [SchemaVersionAhead] the exception propagates unchanged;
  ///      no probes run.
  ///   2. Runs the four probes in fixed order: `schemaVersion`,
  ///      `fts5Available`, `loadExtensionCapable`,
  ///      `embeddingModelMarker`.
  ///   3. Returns a [BootIntegrityReport]; never throws on a probe
  ///      failure (use [BootIntegrityReport.throwIfFailed] for that).
  ///
  /// The probes are intentionally read-only against `memoryDb` once
  /// the migrator has finished. FTS5's create+drop happens against
  /// the `temp` schema so the on-disk database is untouched.
  BootIntegrityReport run({
    required Database memoryDb,
    required MemoryDirectory directory,
    required MemoryConfig config,
  }) {
    final startedAt = _now();

    // Schema-version chain runs first. If the DB is ahead, the typed
    // SchemaVersionAhead propagates as-is — see Q-A.29.2.
    final schemaReport = _migrator.migrate(memoryDb);

    final probes = <IntegrityProbeResult>[
      _schemaVersionProbe(memoryDb, _migrator),
      _fts5Probe(memoryDb),
      _loadExtensionProbe(memoryDb),
      _markerProbe(directory, config),
    ];

    final finishedAt = _now();

    return BootIntegrityReport(
      schemaMigration: schemaReport,
      probes: probes,
      startedAt: startedAt,
      finishedAt: finishedAt,
    );
  }

  /// Verifies that the schema version in [db] matches the migrator's
  /// `latestKnownVersion`.
  ///
  /// Strictly speaking, this is redundant with the migrator's own
  /// success — if `migrate` returned without throwing, the DB *is*
  /// at the latest known version. The probe still runs because (a)
  /// it makes the integrity contract explicit in the report, and
  /// (b) it guards against a hypothetical future migrator bug where
  /// `migrate` returns `ok` without actually advancing the DB.
  static IntegrityProbeResult _schemaVersionProbe(
    Database db,
    SchemaMigrator migrator,
  ) {
    final actual = readSchemaVersion(db);
    final expected = migrator.latestKnownVersion;
    if (actual == expected) {
      return IntegrityProbeResult(
        name: 'schemaVersion',
        status: IntegrityProbeStatus.ok,
        summary: 'memory.db is at schema v$actual (latest known)',
      );
    }
    return IntegrityProbeResult(
      name: 'schemaVersion',
      status: IntegrityProbeStatus.failed,
      summary: 'memory.db is at schema v$actual but the binary expected '
          'v$expected (migrator did not converge)',
    );
  }
}

/// Default FTS5 availability probe.
///
/// Creates an FTS5 virtual table in the `temp` schema (so the
/// on-disk DB is untouched), then drops it. If the SQLite build does
/// not include the FTS5 module, the CREATE statement throws and the
/// probe returns `failed`.
///
/// Public so the production wiring can reference it directly (e.g.
/// for "probe this DB but use only the FTS5 probe" diagnostics).
IntegrityProbeResult defaultFts5Probe(Database db) {
  const probeName = 'fts5Available';
  try {
    db.execute(
      'CREATE VIRTUAL TABLE temp.__tom_brain_fts5_probe USING fts5(t)',
    );
    db.execute('DROP TABLE temp.__tom_brain_fts5_probe');
    return const IntegrityProbeResult(
      name: probeName,
      status: IntegrityProbeStatus.ok,
      summary: 'FTS5 module is available and a temp virtual table '
          'was created+dropped successfully',
    );
  } on Object catch (e) {
    return IntegrityProbeResult(
      name: probeName,
      status: IntegrityProbeStatus.failed,
      summary: 'FTS5 module unavailable: $e',
      cause: e,
    );
  }
}

/// Default `loadExtension` capability probe.
///
/// Asks SQLite whether `ENABLE_LOAD_EXTENSION` was set at compile
/// time via `sqlite_compileoption_used()`. This does **not** attempt
/// to load `vec0` — actually loading the extension is A.50+
/// territory; the boot check only confirms the capability exists.
///
/// Public so the production wiring can reference it directly.
IntegrityProbeResult defaultLoadExtensionProbe(Database db) {
  const probeName = 'loadExtensionCapable';
  try {
    final rows = db.select(
      "SELECT sqlite_compileoption_used('ENABLE_LOAD_EXTENSION') AS x",
    );
    if (rows.isEmpty) {
      return const IntegrityProbeResult(
        name: probeName,
        status: IntegrityProbeStatus.failed,
        summary: 'sqlite_compileoption_used returned no rows; '
            'cannot determine load_extension capability',
      );
    }
    final used = rows.first['x'];
    if (used is int && used == 1) {
      return const IntegrityProbeResult(
        name: probeName,
        status: IntegrityProbeStatus.ok,
        summary: 'SQLite was compiled with ENABLE_LOAD_EXTENSION; '
            'sqlite-vec (vec0) can be loaded at A.50+',
      );
    }
    return IntegrityProbeResult(
      name: probeName,
      status: IntegrityProbeStatus.failed,
      summary: 'SQLite was NOT compiled with ENABLE_LOAD_EXTENSION '
          '(value=$used); sqlite-vec cannot be loaded',
    );
  } on Object catch (e) {
    return IntegrityProbeResult(
      name: probeName,
      status: IntegrityProbeStatus.failed,
      summary: 'load_extension capability probe failed: $e',
      cause: e,
    );
  }
}

/// Default embedding-model marker probe.
///
/// **Currently a deliberate `skipped`.** Per Q-A.26.2, the
/// embedding-model identity is owned by the vectors.db schema
/// (A.50+), not by a root-level marker file. The probe exists in
/// the integrity check today so the four-probe surface listed in
/// plan step A.29 is wired up; when A.50 introduces the
/// authoritative location for the identity, this default is
/// replaced with a real probe and nothing else in the boot path
/// changes.
///
/// If a host nevertheless wants to assert a marker file is present
/// (e.g. for ad-hoc operational scripts before A.50 lands), it can
/// pass a custom [EmbeddingMarkerProbe] to
/// [BootIntegrityCheck]'s constructor.
///
/// Public so the production wiring can reference it directly.
IntegrityProbeResult defaultEmbeddingMarkerProbe(
  MemoryDirectory directory,
  MemoryConfig config,
) {
  // [directory] and [config] are part of the typedef contract so
  // that A.50+ can wire a real probe in without changing the call
  // site. The default implementation does not consult either.
  return const IntegrityProbeResult(
    name: 'embeddingModelMarker',
    status: IntegrityProbeStatus.skipped,
    summary: 'embedding-model marker check is deferred to A.50+ '
        '(vectors.db schema owns the embedding-model identity; '
        'see Q-A.26.2 in prototype_implementation_questions.md)',
  );
}

/// File-name convention reserved for the embedding-model marker, in
/// case A.50+ decides to introduce one at the root level.
///
/// Documented here so all readers see a single name; the constant
/// is referenced by no production code today (the probe is
/// `skipped`). When A.50+ activates the probe it may keep this
/// convention or replace it; either way the constant gives the
/// later step a starting point rather than a blank field.
const String kEmbeddingModelMarkerFileName = '.embedding-model';

/// Resolves the marker file path under [directory] — convenience for
/// any caller (test fixture, ad-hoc script, future A.50+ probe) that
/// wants to write or read the marker without re-deriving the path.
String embeddingModelMarkerPath(MemoryDirectory directory) =>
    '${directory.root}${Platform.pathSeparator}$kEmbeddingModelMarkerFileName';
