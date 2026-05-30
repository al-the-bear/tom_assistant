// Fts5Catalog — owner of the per-type FTS5 virtual-table layout
// (Plan step A.54).
//
// What this file owns:
//
//   - The single source of truth for the FTS5 table name of a node
//     type (`fts_<TypeName>`).
//   - The single source of truth for the FTS5 column list and order
//     of a node type (`[node_id UNINDEXED, <fts_field_1>,
//     <fts_field_2>, ...]` — `ftsFields` are sorted alphabetically so
//     the writer and the reader cannot drift).
//   - Idempotent provisioning: `CREATE VIRTUAL TABLE IF NOT EXISTS`
//     for every type whose `indexPolicy.ftsFields` is non-empty.
//   - The tokeniser decision: `indexPolicy.ftsTokeniser` when present,
//     otherwise the spec § 2.3 default `unicode61 remove_diacritics 2`.
//
// What this file does NOT own:
//
//   - Row writes. The persister-side row write lives in
//     `fts5_writer.dart`; this file only declares the table layout
//     the writer (and the reader) must agree on.
//   - The BM25 query path. That lives in `bm25_recall.dart`. The
//     catalog provides `tableNameFor` / `ftsColumnsFor` so the
//     recall executor builds its `MATCH` queries against the
//     authoritative table layout.
//   - Type-evolution drops. When a `NodeTypeDecl` is superseded, the
//     old FTS table stays around until a later restructuring pass
//     cleans it up. The catalog is forward-only at A.54; rebuild /
//     swap semantics land with the type-evolution flow in a later A
//     step (matched up with `propose_node_type_v1`).
//
// Why per-type tables and not one wide `fts_nodes` table:
//
// Spec § 2.3 says "FTS5 virtual tables are added per indexable text
// column when a NodeType registers its indexPolicy." A wide single
// table would force every type's FTS columns into a shared schema
// where most rows leave most columns empty, the BM25 normalisation
// becomes type-blind, and a per-type tokeniser override is impossible.
// Per-type tables give:
//
//   - Real per-type BM25 normalisation (FTS5 normalises within a
//     virtual table, so each type's IDF reflects its own corpus).
//   - Per-type tokeniser choice (the `ftsTokeniser` field is honoured
//     here and only here).
//   - Cheap "drop and re-index this type" semantics for type
//     evolution.
//
// The cost is N virtual tables on the connection (one per type with
// FTS fields). At the 21 bootstrap types this is trivial.

import 'package:sqlite3/sqlite3.dart';

import '../nodes/node_type_decl.dart';

/// Owner of the per-type FTS5 virtual-table layout.
///
/// Stateless: every public method takes the inputs it needs. The
/// catalog can be a `const` in callers that just need the name /
/// column helpers; tests construct an instance to call `ensureTable`
/// against a live SQLite connection.
final class Fts5Catalog {
  /// SQLite identifier prefix for the per-type FTS5 virtual table.
  ///
  /// `fts_<TypeName>` keeps the type's PascalCase identity in the
  /// table name so an operator dumping `sqlite_master` can read the
  /// schema without consulting the registry.
  static const String tableNamePrefix = 'fts_';

  /// Default tokeniser when `IndexPolicy.ftsTokeniser` is null.
  ///
  /// Mirrors spec § 2.3: `unicode61` for case-fold + Unicode word
  /// segmentation, `remove_diacritics 2` to fold accented characters
  /// to their base forms (so "résumé" and "resume" share an index
  /// entry). This is the same default SQLite's FTS5 ships with for
  /// `unicode61`; we name it explicitly so a future tokeniser swap is
  /// an opt-in per-type override rather than a runtime surprise.
  static const String defaultTokeniser = 'unicode61 remove_diacritics 2';

  const Fts5Catalog();

  /// Returns the FTS5 virtual-table name for [typeName].
  ///
  /// Pure: same input → same output, regardless of whether the table
  /// has been provisioned yet. Callers that need the table to exist
  /// must call [ensureTable] first.
  String tableNameFor(String typeName) => '$tableNamePrefix$typeName';

  /// Returns the ordered list of FTS-indexed column names for [decl],
  /// not including the leading `node_id UNINDEXED` column.
  ///
  /// Order is alphabetical so the writer's `INSERT … VALUES (…)` and
  /// the reader's column projection cannot drift apart silently. The
  /// returned list is unmodifiable.
  List<String> ftsColumnsFor(NodeTypeDecl decl) {
    final fields = decl.indexPolicy.ftsFields.toList()..sort();
    return List<String>.unmodifiable(fields);
  }

  /// Provisions the FTS5 virtual table for [decl] on [db] if and
  /// only if the type carries any FTS-indexed fields.
  ///
  /// No-op when `decl.indexPolicy.ftsFields` is empty — types without
  /// FTS coverage (e.g. `Stack`, `StackEntry`) do not get an empty
  /// virtual table.
  ///
  /// Idempotent via `CREATE VIRTUAL TABLE IF NOT EXISTS`, so calling
  /// this against an already-provisioned table is a no-op at the
  /// SQLite layer.
  ///
  /// The tokeniser is `decl.indexPolicy.ftsTokeniser` when non-null,
  /// otherwise [defaultTokeniser].
  void ensureTable(NodeTypeDecl decl, Database db) {
    final fields = ftsColumnsFor(decl);
    if (fields.isEmpty) return;
    final tokeniser = decl.indexPolicy.ftsTokeniser ?? defaultTokeniser;
    final tableName = tableNameFor(decl.typeName);
    // Column list: leading `node_id UNINDEXED` so MATCH doesn't tokenise
    // the foreign key, followed by the sorted FTS fields. Quoting every
    // identifier with double quotes is the FTS5-safe form — a field
    // named `order` or `select` would otherwise collide with SQL
    // keywords.
    final quotedFields = fields.map((f) => '"$f"').join(', ');
    final ddl =
        'CREATE VIRTUAL TABLE IF NOT EXISTS "$tableName" USING fts5('
        'node_id UNINDEXED, '
        '$quotedFields, '
        "tokenize = '$tokeniser'"
        ')';
    db.execute(ddl);
  }

  /// Provisions FTS5 tables for every decl in [decls] in iteration
  /// order. A bulk convenience for the registry's warm-up path.
  void ensureAllTables(Iterable<NodeTypeDecl> decls, Database db) {
    for (final decl in decls) {
      ensureTable(decl, db);
    }
  }
}
