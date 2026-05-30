// SchemaV1 — SQLite schema v1 for `memory.db`.
//
// Plan step A.27:
//   "SQLite schema v1 for `memory.db`: tables `nodes`, `edges`,
//    `node_types`, `stacks`, `stack_entries`, `trails`,
//    `pending_vector_writes`, `centroids`, `migrations`,
//    `tombstones_index`. Indexes per spec § 4.2."
//
// Scope at A.27 is the *DDL only*:
//
//   - The ten tables named in the plan.
//   - The composite edge indexes spec § 4.2 mandates
//     (`(from, type)`, `(to, type)`, `(type, from, to)`).
//   - The auxiliary indexes that every other phase-A step assumes
//     (type filter on `nodes`, status filter on `nodes`, time range
//     on `nodes`, stack-entry lookup keys, trail status filter,
//     tombstone time index).
//
// What is intentionally NOT here:
//
//   - FTS5 virtual tables. Per spec § 2.3 those are added *per
//     indexable text column* when a `NodeType` registers its
//     `indexPolicy`. They land in A.32+ once the type registry
//     can drive them.
//   - The `vectors.db` schema. That is sqlite-vec territory and
//     lives in its own file (A.50+).
//   - WAL configuration, busy-timeout tuning, `PRAGMA journal_mode`,
//     etc. Those are connection-open concerns that land alongside
//     the store opener (A.26 / A.28). They are *not* part of the
//     schema definition.
//   - The bootstrap `node_types` and `stacks` rows. Inserting those
//     is A.32 / A.43; this file only declares the tables that hold
//     them.
//
// Forward-only: per quest hard-principle 1 (no backwards
// compatibility), there is no v0→v1 migration script. v1 is the
// initial schema. When v2 lands (A.28+), it gets its own file
// (`schema_v2.dart`) and the migrator chains them in order.
//
// Idempotency: every DDL statement uses `IF NOT EXISTS` so
// `applySchemaV1` is safe to call against a freshly-opened DB *or*
// against a DB that already has v1 applied. The `migrations` row is
// upserted via `INSERT OR IGNORE` so re-application is a no-op at
// the bookkeeping layer too.
//
// Two-database coordination: the `pending_vector_writes` table is
// the persistent buffer between `memory.db` and `vectors.db` (spec
// § 2.4). The schema is declared here; the *use* of it (the actual
// crash-resilient two-DB commit) is A.30. Both halves need each
// other but they ship in separate steps so the DDL can be tested
// independently of the coordinator logic.

import 'package:sqlite3/sqlite3.dart';

/// Schema version produced by [applySchemaV1].
///
/// The migrator (A.28) compares this against the highest row in the
/// `migrations` table to decide whether to apply this version. The
/// `1` is deliberately not a `const` configured elsewhere — every
/// schema-version file owns its own version literal.
const int schemaV1Version = 1;

/// Human-readable summary persisted into `migrations.summary` for
/// every v1 application. Operators reading the migrations table
/// see this string; it never appears in production data paths.
const String schemaV1Summary =
    'Tom Brain memory schema v1 — 10 base tables + indexes per spec § 4.2.';

/// Ordered list of DDL statements that constitute schema v1.
///
/// Order is meaningful only for documentation — every statement is
/// independently idempotent and references no foreign keys (SQLite
/// FK enforcement is off in this schema; cross-table integrity is
/// guarded at the Dart layer, not at the SQL layer, because that
/// is where the typed errors must originate).
///
/// Returned as `List<String>` rather than `Iterable<String>` so the
/// test suite can index into it for "exactly N statements" checks
/// without consuming an iterator.
List<String> schemaV1Statements() => const <String>[
  // ─────────────────────────────────────────────────────────────
  // migrations — schema-version history.
  //
  // The migrator (A.28) reads `MAX(version)` to detect the current
  // schema state. `applied_at_ms` is the indexable form; the ISO
  // string mirrors it for human dumps (spec § 12.2 dual-time form).
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS migrations (
  version          INTEGER PRIMARY KEY,
  applied_at_ms    INTEGER NOT NULL,
  applied_at_iso   TEXT    NOT NULL,
  summary          TEXT    NOT NULL
)
''',

  // ─────────────────────────────────────────────────────────────
  // nodes — every node in the property graph.
  //
  // Columns mirror `Node` (spec § 4.1) with the typed-fields payload
  // serialised as `attrs_json` for forward-compatibility with the
  // open node-type registry. `embedding_model_id` is nullable: nodes
  // without any embedded field record `NULL`; the vector itself
  // lives in `vectors.db` (A.50+).
  //
  // `idempotency_key` is nullable and uniquely indexed only when
  // present — this is the `Scope.idempotencyKey` guarantee (spec
  // § 9.1): a re-run with the same key reuses the prior `NodeId`.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS nodes (
  id                  TEXT    PRIMARY KEY,
  type_name           TEXT    NOT NULL,
  scope_json          TEXT    NOT NULL,
  produced_by         TEXT,
  attrs_json          TEXT    NOT NULL,
  status              TEXT    NOT NULL,
  created_at_ms       INTEGER NOT NULL,
  created_at_iso      TEXT    NOT NULL,
  updated_at_ms       INTEGER NOT NULL,
  updated_at_iso      TEXT    NOT NULL,
  idempotency_key     TEXT,
  embedding_model_id  TEXT
)
''',
  'CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type_name)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_created_at_ms ON nodes(created_at_ms)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_type_created_at_ms '
      'ON nodes(type_name, created_at_ms)',
  'CREATE INDEX IF NOT EXISTS idx_nodes_type_status '
      'ON nodes(type_name, status)',
  // Partial-unique index: idempotency keys only collide when they
  // are non-null, mirroring spec § 9.1.
  'CREATE UNIQUE INDEX IF NOT EXISTS uniq_nodes_idempotency_key '
      'ON nodes(idempotency_key) WHERE idempotency_key IS NOT NULL',

  // ─────────────────────────────────────────────────────────────
  // edges — typed graph edges; closed 12-edge alphabet (spec § 4.2).
  //
  // `from_node` / `to_node` are bare strings here; type-level checks
  // (`allowedOutgoing` / `allowedIncoming`) happen in the Dart layer
  // before insert.
  //
  // The three composite indexes are *the* indexes spec § 4.2
  // requires: every edge query enters by either endpoint or by edge
  // type, and the third covers exact-shape lookup (`type, from,
  // to`) for membership checks like `StackEntry —part_of→ Stack`.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS edges (
  id              TEXT    PRIMARY KEY,
  from_node       TEXT    NOT NULL,
  to_node         TEXT    NOT NULL,
  type            TEXT    NOT NULL,
  weight          REAL    NOT NULL DEFAULT 1.0,
  attrs_json      TEXT,
  produced_by     TEXT,
  created_at_ms   INTEGER NOT NULL,
  created_at_iso  TEXT    NOT NULL
)
''',
  'CREATE INDEX IF NOT EXISTS idx_edges_from_type '
      'ON edges(from_node, type)',
  'CREATE INDEX IF NOT EXISTS idx_edges_to_type '
      'ON edges(to_node, type)',
  'CREATE INDEX IF NOT EXISTS idx_edges_type_from_to '
      'ON edges(type, from_node, to_node)',

  // ─────────────────────────────────────────────────────────────
  // node_types — cached `NodeTypeDecl` for fast lookup.
  //
  // The canonical declaration is a `NodeType` node in `nodes`; this
  // table caches the fields callers hit on the hot path
  // (`allowed_outgoing_json`, `allowed_incoming_json`,
  // `embedding_policy_json`) so the per-write permission check is
  // one row read rather than a node-fetch-and-decode.
  //
  // `version` lets the registry hold multiple cached declarations
  // for the same type during a type-evolution migration (spec
  // § 4.1 "Adding a new node type"). The migrator superseding a
  // type writes a new row; the in-flight column on the canonical
  // `NodeType` node is the source of truth, this table is a
  // performance cache.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS node_types (
  type_name                TEXT    PRIMARY KEY,
  version                  INTEGER NOT NULL,
  decl_node_id             TEXT    NOT NULL,
  supersedes               TEXT,
  schema_json              TEXT    NOT NULL,
  embedding_policy_json    TEXT    NOT NULL,
  index_policy_json        TEXT    NOT NULL,
  retention_policy_json    TEXT    NOT NULL,
  allowed_outgoing_json    TEXT    NOT NULL,
  allowed_incoming_json    TEXT    NOT NULL,
  validator_script_id      TEXT,
  registered_at_ms         INTEGER NOT NULL,
  registered_at_iso        TEXT    NOT NULL
)
''',

  // ─────────────────────────────────────────────────────────────
  // stacks — one row per registered stack (spec § 5).
  //
  // The `Stack` node in `nodes` is the canonical declaration;
  // this table caches the policy + bootstrap flag so the hot
  // push/pop path does not pay a JSON decode.
  //
  // `is_bootstrap` blocks `BootstrapStackImmutable` violations
  // (spec § 5.4): an attempt to delete a row where
  // `is_bootstrap = 1` errors at the Dart layer.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS stacks (
  name                          TEXT    PRIMARY KEY,
  stack_node_id                 TEXT    NOT NULL,
  entry_node_type               TEXT    NOT NULL,
  priority_policy               TEXT    NOT NULL,
  priority_policy_attrs_json    TEXT,
  retention_policy              TEXT    NOT NULL,
  retention_policy_attrs_json   TEXT,
  harvester_hook                TEXT,
  is_bootstrap                  INTEGER NOT NULL DEFAULT 0,
  created_at_ms                 INTEGER NOT NULL,
  created_at_iso                TEXT    NOT NULL
)
''',

  // ─────────────────────────────────────────────────────────────
  // stack_entries — membership of a node in a stack (spec § 5).
  //
  // Schema mirrors `StackEntry` with the priority + status carried
  // here, not on the underlying node. The triple
  // `(stack_name, status, priority DESC, pushed_at_ms ASC)` covers
  // every `priority`-policy peek; the `(stack_name, status,
  // pushed_at_ms)` covers `fifo` / `lifo` / `time_decayed_priority`
  // ordering — the time-decayed policy still wants to scan
  // newest-first because the exponential decay is monotonic in age.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS stack_entries (
  id              TEXT    PRIMARY KEY,
  stack_name      TEXT    NOT NULL,
  entry_node      TEXT    NOT NULL,
  priority        REAL    NOT NULL DEFAULT 0.0,
  status          TEXT    NOT NULL DEFAULT 'active',
  attrs_json      TEXT,
  pushed_at_ms    INTEGER NOT NULL,
  pushed_at_iso   TEXT    NOT NULL,
  updated_at_ms   INTEGER NOT NULL,
  updated_at_iso  TEXT    NOT NULL
)
''',
  'CREATE INDEX IF NOT EXISTS idx_stack_entries_stack '
      'ON stack_entries(stack_name)',
  'CREATE INDEX IF NOT EXISTS idx_stack_entries_stack_status_priority '
      'ON stack_entries(stack_name, status, priority)',
  'CREATE INDEX IF NOT EXISTS idx_stack_entries_stack_status_pushed_at '
      'ON stack_entries(stack_name, status, pushed_at_ms)',
  'CREATE INDEX IF NOT EXISTS idx_stack_entries_entry_node '
      'ON stack_entries(entry_node)',

  // ─────────────────────────────────────────────────────────────
  // trails — index rows for JSONL trail files (spec § 8).
  //
  // The actual append-only JSONL lives under `<root>/trails/`.
  // This index row is written *after* the first JSONL line is
  // durable (spec § 2.4); on read, the index tells consumers which
  // file to open.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS trails (
  id              TEXT    PRIMARY KEY,
  run_id          TEXT    NOT NULL,
  jsonl_path      TEXT    NOT NULL,
  status          TEXT    NOT NULL,
  outcome         TEXT,
  opened_at_ms    INTEGER NOT NULL,
  opened_at_iso   TEXT    NOT NULL,
  closed_at_ms    INTEGER,
  closed_at_iso   TEXT
)
''',
  'CREATE INDEX IF NOT EXISTS idx_trails_run ON trails(run_id)',
  'CREATE INDEX IF NOT EXISTS idx_trails_status ON trails(status)',
  'CREATE INDEX IF NOT EXISTS idx_trails_opened_at_ms '
      'ON trails(opened_at_ms)',

  // ─────────────────────────────────────────────────────────────
  // pending_vector_writes — two-DB transaction coordinator
  // (spec § 2.4).
  //
  // The row is enqueued *inside* the `memory.db` transaction that
  // writes the node; the vector is then applied to `vectors.db`
  // and the row deleted. A crash between the two writes leaves the
  // row visible at startup, which A.30's startup-replay path
  // either applies or rolls back.
  //
  // Primary key on `node_id` enforces "at most one pending vector
  // write per node" — the node-write path is single-writer per
  // node-id so this never collides in normal operation.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS pending_vector_writes (
  node_id              TEXT    PRIMARY KEY,
  embedding_model_id   TEXT    NOT NULL,
  payload_blob         BLOB    NOT NULL,
  payload_dims         INTEGER NOT NULL,
  enqueued_at_ms       INTEGER NOT NULL,
  enqueued_at_iso      TEXT    NOT NULL
)
''',
  'CREATE INDEX IF NOT EXISTS idx_pending_vector_writes_enqueued_at_ms '
      'ON pending_vector_writes(enqueued_at_ms)',

  // ─────────────────────────────────────────────────────────────
  // centroids — per-key classification centroid (spec § 7.1).
  //
  // `for_key` is `'NodeType:Question'`, `'Procedure:research_v1'`,
  // etc. The encoding namespace prevents collisions when the same
  // string would denote two different kinds of key.
  //
  // `example_count` lets the cold-start gate (spec § 7.1
  // `n=8`) read the threshold in one column rather than counting
  // accepted examples on every classify call.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS centroids (
  for_key              TEXT    PRIMARY KEY,
  embedding_model_id   TEXT    NOT NULL,
  centroid_blob        BLOB    NOT NULL,
  centroid_dims        INTEGER NOT NULL,
  example_count        INTEGER NOT NULL,
  updated_at_ms        INTEGER NOT NULL,
  updated_at_iso       TEXT    NOT NULL
)
''',

  // ─────────────────────────────────────────────────────────────
  // tombstones_index — fast lookup of "what was forgotten"
  // (spec § 4.1 Tombstone row).
  //
  // The canonical Tombstone is a node in `nodes` (with edge
  // `derived_from` → the successor). This table is an index from
  // the forgotten node-id back to that Tombstone for the
  // common-case lookup "did we already forget this?" without a
  // node-scan.
  //
  // Note the *index*-only role: nothing here is the source of
  // truth, and a drop+rebuild of this table from the Tombstone
  // nodes is a valid recovery path.
  // ─────────────────────────────────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS tombstones_index (
  forgotten_node_id    TEXT    PRIMARY KEY,
  tombstone_node_id    TEXT    NOT NULL,
  forgotten_type       TEXT    NOT NULL,
  reason               TEXT    NOT NULL,
  forgotten_at_ms      INTEGER NOT NULL,
  forgotten_at_iso     TEXT    NOT NULL
)
''',
  'CREATE INDEX IF NOT EXISTS idx_tombstones_index_forgotten_at_ms '
      'ON tombstones_index(forgotten_at_ms)',
  'CREATE INDEX IF NOT EXISTS idx_tombstones_index_tombstone_node '
      'ON tombstones_index(tombstone_node_id)',
];

/// Applies schema v1 to [db].
///
/// Contract:
///
///   * Wraps every DDL statement in a single `BEGIN … COMMIT`.
///     A failure in the middle of the application leaves the DB
///     unchanged (sqlite rolls the transaction back).
///   * Records the application in `migrations` via
///     `INSERT OR IGNORE` so the second call against a v1-applied
///     DB is a no-op.
///   * Uses `BrainTime`-equivalent dual-time form: `applied_at_ms`
///     (indexable) and `applied_at_iso` (human readable).
///
/// Idempotency note: the statements use `CREATE … IF NOT EXISTS`
/// so a partially-applied schema (e.g. crash during initial
/// migration in a previous run) re-converges on success. This is
/// the *primary* reason for the `IF NOT EXISTS` choice — the
/// transactional wrapper would already guarantee all-or-nothing,
/// but the per-statement guard means a re-run after a clean abort
/// is safe even before the transaction wrapper is reached.
///
/// Called by the migrator (A.28). Hosts must not call this
/// directly outside of the migration path.
void applySchemaV1(Database db) {
  db.execute('BEGIN');
  try {
    for (final stmt in schemaV1Statements()) {
      db.execute(stmt);
    }
    final now = DateTime.now().toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    final nowIso = now.toIso8601String();
    db.execute(
      'INSERT OR IGNORE INTO migrations '
      '(version, applied_at_ms, applied_at_iso, summary) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[schemaV1Version, nowMs, nowIso, schemaV1Summary],
    );
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Returns the highest schema version recorded in [db], or `0` when
/// the `migrations` table is absent (fresh DB).
///
/// The migrator uses this to decide which schema-vN file to apply
/// next. Returning `0` for "no `migrations` table" rather than
/// throwing means the caller can pass any database — newly created
/// or partially set up — and get a well-defined number back.
int readSchemaVersion(Database db) {
  final tableExists = db.select(
    "SELECT name FROM sqlite_master "
    "WHERE type = 'table' AND name = 'migrations'",
  );
  if (tableExists.isEmpty) {
    return 0;
  }
  final result = db.select('SELECT MAX(version) AS v FROM migrations');
  if (result.isEmpty) {
    return 0;
  }
  final v = result.first['v'];
  if (v == null) {
    return 0;
  }
  return v as int;
}
