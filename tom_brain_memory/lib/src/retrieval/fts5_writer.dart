// Fts5Writer — owner of the per-type FTS5 INSERT path (Plan step
// A.54).
//
// Called from `NodePersister` inside the two-DB coordinator's
// `writeNode` callback so the FTS row lands in the same `memory.db`
// transaction as the `nodes` row. The FTS5 virtual table lives in
// `memory.db`, so the BEGIN/COMMIT that wraps the node INSERT also
// wraps the FTS INSERT — no separate cross-store coordination is
// needed for FTS (the two-DB coordinator's job is the `vectors.db`
// half, which the FTS path does not touch).
//
// Why a separate file from `Fts5Catalog`:
//
//   - The catalog is the schema source-of-truth (table name + column
//     order + tokeniser). It is consulted by both the writer and the
//     reader, and tests build a `const Fts5Catalog()` without ever
//     touching a row.
//   - The writer is the per-row INSERT executor. Splitting the two
//     means the reader has no path to the writer (and vice versa) —
//     they share only the catalog's pure helpers.
//
// What this file does NOT own:
//
//   - Deletion / demotion. When a node is forgotten or demoted, its
//     FTS row needs to disappear from the index (spec § 5.3:
//     "demoteFromIndexes" on `RetentionPolicy`). That path lands
//     alongside the lifecycle write rewrites in a later A step.
//   - Re-index on type evolution. When a `NodeTypeDecl` is
//     superseded, the predecessor's FTS table may need to be
//     re-populated under the new schema. Out of scope at A.54.

import 'package:sqlite3/sqlite3.dart';

import '../nodes/node_type_decl.dart';
import 'fts5_catalog.dart';

/// Owner of the per-type FTS5 INSERT path.
///
/// One instance per `NodePersister`. Constructed by the store opener
/// alongside the persister, sharing the same `memory.db` handle.
final class Fts5Writer {
  /// Catalog that owns the table layout (name + column order). The
  /// writer holds a reference rather than a copy so a future swap of
  /// the catalog (alternate tokeniser, alternate naming) is a
  /// constructor-level change rather than a writer-internal one.
  final Fts5Catalog _catalog;

  /// Constructs a writer over [catalog]. Defaults to the system
  /// catalog so the production wiring is a single zero-argument
  /// `Fts5Writer()` in most cases; tests can inject a catalog whose
  /// names are stubbed for inspection.
  const Fts5Writer({Fts5Catalog catalog = const Fts5Catalog()})
      : _catalog = catalog;

  /// Inserts (or replaces) the FTS5 row for [nodeId] of type [decl]
  /// on [db], using the field values in [values].
  ///
  /// No-op when [decl] declares no FTS-indexed fields (the per-type
  /// table is never created and there is nothing to insert).
  ///
  /// Behaviour:
  ///
  ///   * `node_id` is the bare `NodeId.toString()` form.
  ///   * Every FTS column is set to the stringified value from
  ///     [values], or the empty string when missing or null. Per
  ///     `NodeTypeRegistry._validateIndexPolicy` an FTS-eligible
  ///     field is always typed `string` on the schema, so the
  ///     stringification is identity for any present non-null value.
  ///   * Existing rows for the same `node_id` are replaced via
  ///     `INSERT INTO … (rowid, …) SELECT rowid, … FROM …` — but the
  ///     FTS5 path simpler than that: the persister never re-inserts
  ///     an existing node id (idempotent persist returns early
  ///     without calling this writer). For safety against a future
  ///     update-then-persist path we still issue `DELETE` + `INSERT`
  ///     under the same transaction.
  ///
  /// Must be called inside an open SQLite transaction (the
  /// coordinator's `writeNode` callback already runs inside one).
  /// The writer does not open its own BEGIN.
  void insertRow({
    required Database db,
    required NodeTypeDecl decl,
    required String nodeId,
    required Map<String, Object?> values,
  }) {
    final columns = _catalog.ftsColumnsFor(decl);
    if (columns.isEmpty) return;

    final tableName = _catalog.tableNameFor(decl.typeName);

    // The FTS5 spec doesn't enforce a single-row-per-node-id
    // invariant; we enforce it here so a future "rewrite this node"
    // path (not present at A.54) cannot accidentally produce
    // duplicates that would inflate BM25 frequencies.
    db.execute(
      'DELETE FROM "$tableName" WHERE node_id = ?',
      <Object?>[nodeId],
    );

    final placeholders = List<String>.filled(columns.length + 1, '?').join(', ');
    final quotedColumns = columns.map((c) => '"$c"').join(', ');
    final params = <Object?>[
      nodeId,
      for (final column in columns) _coerceToFtsText(values[column]),
    ];
    db.execute(
      'INSERT INTO "$tableName" (node_id, $quotedColumns) VALUES ($placeholders)',
      params,
    );
  }

  /// Removes any FTS5 row for [nodeId] from [decl]'s table. No-op when
  /// the type has no FTS table.
  ///
  /// Exposed for the future lifecycle path (demote / forget). At A.54
  /// nothing calls it; it is here so the writer surface is complete
  /// when the lifecycle wiring lands.
  void deleteRow({
    required Database db,
    required NodeTypeDecl decl,
    required String nodeId,
  }) {
    final columns = _catalog.ftsColumnsFor(decl);
    if (columns.isEmpty) return;
    final tableName = _catalog.tableNameFor(decl.typeName);
    db.execute(
      'DELETE FROM "$tableName" WHERE node_id = ?',
      <Object?>[nodeId],
    );
  }

  /// Stringifies a per-field value for the FTS column.
  ///
  /// Null collapses to the empty string — FTS5 cannot index NULL and
  /// the column-store storage interprets NULL as "no text", which is
  /// not what a missing nullable field means at the query level. An
  /// empty string in an indexed column produces no tokens; the row
  /// is still findable via other indexed columns.
  static String _coerceToFtsText(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }
}
