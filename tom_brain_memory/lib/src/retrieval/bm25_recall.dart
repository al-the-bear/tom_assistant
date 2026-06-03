// Bm25Recall — BM25-mode executor for `RecallQuery.text`
// (Plan step A.54, spec § 6.1 BM25 mode).
//
// What this file owns:
//
//   - Tokenising the caller's free-text query into an FTS5 MATCH
//     expression. The transformation is deterministic and refuses
//     queries that produce zero usable tokens (so the caller cannot
//     accidentally MATCH the empty string and get the universe).
//   - Running one `SELECT … MATCH ? ORDER BY bm25(...)` per
//     candidate type's FTS5 table, scoping by [Set<String>?] of
//     type names when supplied.
//   - Merging the per-type results into a single ranked list with at
//     most `perModeK` rows. FTS5's BM25 returns lower-is-better
//     scores; the merge keeps that orientation so the fusion stage
//     (A.57) does its own per-mode normalisation.
//
// What this file does NOT own:
//
//   - Fusion across modes (A.57 RRF / weighted).
//   - Diversity (A.58 MMR).
//   - Symbolic filter compilation (A.56). The `typeNames` parameter
//     accepts the symbolic-filter's type-name set when present, but
//     the wider `WHERE` shape is not applied at A.54.
//   - The `RecallReport` cost row. The recall executor at A.59 will
//     compose this output with the report.
//
// Wire contract:
//
//   The `Bm25RecallCandidate` carries `(nodeId, typeName, bm25Score)`.
//   It deliberately does *not* carry the materialised `Node` — that
//   read happens in one bulk `NodeReader.getMany` after fusion +
//   diversity, so BM25 results that lose the fusion stage do not cost
//   a `nodes` row read each.
//
//   The score field name is `bm25Score` (not `score`) so a future
//   fusion record carrying multiple per-mode scores can be added
//   without renaming.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, NodeTypeDecl;

import '../nodes/node_type_registry.dart';
import 'fts5_catalog.dart';

/// A single BM25-mode candidate.
///
/// The recall executor returns these ordered by ascending [bm25Score]
/// (FTS5's convention: lower = more relevant).
final class Bm25RecallCandidate {
  /// The node the FTS row points to.
  final NodeId nodeId;

  /// The node's type — kept on the candidate so the fusion stage can
  /// apply per-type weights without a second registry lookup.
  final String typeName;

  /// FTS5's `bm25(...)` score. Lower = more relevant. Negative in
  /// FTS5's default formulation. Memory's downstream fusion stage
  /// normalises per-mode and does not assume a sign convention.
  final double bm25Score;

  const Bm25RecallCandidate({
    required this.nodeId,
    required this.typeName,
    required this.bm25Score,
  });

  @override
  String toString() =>
      'Bm25RecallCandidate(type: $typeName, id: $nodeId, score: $bm25Score)';
}

/// BM25 mode executor.
///
/// One instance per open memory store. Stateless across calls; safe
/// to share between callers on the same SQLite connection.
final class Bm25Recall {
  /// Live SQLite handle on `memory.db`. Owned by the store opener.
  final Database _db;

  /// Live registry — used to enumerate which types have FTS coverage.
  final NodeTypeRegistry _registry;

  /// Catalog that owns the table-name shape (must agree with the
  /// writer's).
  final Fts5Catalog _catalog;

  /// Constructs the executor.
  ///
  /// [catalog] defaults to `const Fts5Catalog()` — the same default the
  /// writer uses. Pass a non-default only when the catalog's naming
  /// has been overridden for a test.
  Bm25Recall({
    required Database memoryDb,
    required NodeTypeRegistry registry,
    Fts5Catalog catalog = const Fts5Catalog(),
  })  : _db = memoryDb,
        _registry = registry,
        _catalog = catalog;

  // ─── Public surface ────────────────────────────────────────────

  /// Runs the BM25 mode for [text] across every registered type whose
  /// `IndexPolicy.ftsFields` is non-empty.
  ///
  /// Contract:
  ///
  ///   * Returns at most [perModeK] candidates, ordered by ascending
  ///     `bm25Score` (FTS5's lower-is-better).
  ///   * Returns an empty list when [text] contains no FTS-usable
  ///     tokens (whitespace-only, punctuation-only, or empty). This
  ///     is a typed refusal — no SQL is issued, no `MATCH ''` runs.
  ///   * [typeNames] (when non-null and non-empty) restricts the
  ///     scan to those type names. Names that are not registered or
  ///     that carry no FTS coverage are silently elided. An empty
  ///     set restricts to *no* types (returns empty); pass `null` for
  ///     "all types".
  ///   * [perModeK] caps the *post-merge* count, not the per-type
  ///     count: each type is queried with `LIMIT perModeK`, then the
  ///     merged result is truncated to `perModeK`. This keeps the
  ///     per-mode I/O bounded by `numTypes * perModeK` rows in the
  ///     worst case.
  ///
  /// Throws when an underlying FTS5 table does not exist. That can
  /// only happen if a type was registered before the catalog wiring
  /// was added; the existing tests and the production wiring at
  /// A.54+ always provision the table.
  List<Bm25RecallCandidate> recall({
    required String text,
    Set<String>? typeNames,
    int perModeK = 64,
  }) {
    if (perModeK <= 0) return const <Bm25RecallCandidate>[];

    final matchExpression = _toFts5Match(text);
    if (matchExpression == null) return const <Bm25RecallCandidate>[];

    final candidates = _selectCandidateTypes(typeNames);
    if (candidates.isEmpty) return const <Bm25RecallCandidate>[];

    final merged = <Bm25RecallCandidate>[];
    for (final decl in candidates) {
      _appendPerTypeMatches(
        decl: decl,
        match: matchExpression,
        perModeK: perModeK,
        into: merged,
      );
    }

    // BM25: lower = better. Sort ascending; truncate to perModeK.
    merged.sort((a, b) => a.bm25Score.compareTo(b.bm25Score));
    if (merged.length > perModeK) {
      return List<Bm25RecallCandidate>.unmodifiable(
        merged.sublist(0, perModeK),
      );
    }
    return List<Bm25RecallCandidate>.unmodifiable(merged);
  }

  // ─── Internal: candidate-type enumeration ──────────────────────

  /// Resolves the candidate type list under the (optional) [typeNames]
  /// filter, dropping types without FTS coverage.
  List<NodeTypeDecl> _selectCandidateTypes(Set<String>? typeNames) {
    if (typeNames != null && typeNames.isEmpty) {
      return const <NodeTypeDecl>[];
    }
    final all = _registry.listAll();
    final scoped = typeNames == null
        ? all
        : all.where((decl) => typeNames.contains(decl.typeName));
    return scoped
        .where((decl) => decl.indexPolicy.ftsFields.isNotEmpty)
        .toList(growable: false);
  }

  // ─── Internal: per-type query ──────────────────────────────────

  void _appendPerTypeMatches({
    required NodeTypeDecl decl,
    required String match,
    required int perModeK,
    required List<Bm25RecallCandidate> into,
  }) {
    final tableName = _catalog.tableNameFor(decl.typeName);
    // The MATCH expression is the second-positional argument to
    // bm25() — FTS5 accepts column-weight literals after the table
    // reference, but the unweighted default is "all columns weighted
    // 1.0", which is what the spec asks for at A.54.
    //
    // `bm25(...)` returns a real; cast through `num` so a future
    // SQLite that yields an int doesn't crash the `as double`.
    final rows = _db.select(
      'SELECT node_id, bm25("$tableName") AS score '
      'FROM "$tableName" '
      'WHERE "$tableName" MATCH ? '
      'ORDER BY score '
      'LIMIT ?',
      <Object?>[match, perModeK],
    );
    for (final row in rows) {
      final nodeId = NodeId.fromString(row['node_id'] as String);
      final score = (row['score'] as num).toDouble();
      into.add(
        Bm25RecallCandidate(
          nodeId: nodeId,
          typeName: decl.typeName,
          bm25Score: score,
        ),
      );
    }
  }

  // ─── Internal: FTS5 MATCH builder ──────────────────────────────

  /// Tokenises [text] into a safe FTS5 MATCH expression, or returns
  /// `null` when the input carries no usable tokens.
  ///
  /// Strategy:
  ///
  ///   1. Split on whitespace.
  ///   2. For each token, keep only Unicode word characters
  ///      (`\p{L}`, `\p{N}`, `_`) — punctuation and FTS5 operator
  ///      characters are stripped so the quoted phrase cannot break
  ///      out into a MATCH operator. Accented letters are deliberately
  ///      *kept*: the index-side `unicode61 remove_diacritics 2`
  ///      tokeniser (see [Fts5Catalog.defaultTokeniser]) folds them to
  ///      their base form, and FTS5 applies that same tokeniser to the
  ///      query term, so "résumé" here matches "resume" in the index.
  ///      Stripping non-ASCII letters (the old `[A-Za-z0-9_]` rule)
  ///      silently broke that match.
  ///   3. Drop empty tokens.
  ///   4. Wrap each token in double quotes (FTS5 phrase / column
  ///      literal). This avoids accidental MATCH operators in user
  ///      input (`AND`, `OR`, `NEAR`, `*`, `^`, `-`).
  ///   5. Join with ` OR `. The OR-of-tokens behaviour is the
  ///      classic "recall-favouring" choice for a user-typed query;
  ///      AND-of-tokens would be high-precision but caller-hostile.
  ///
  /// Returns `null` when the resulting expression would have zero
  /// tokens — the BM25 mode then returns empty rather than running
  /// `MATCH ''` (which FTS5 rejects as a syntax error anyway).
  static String? _toFts5Match(String text) {
    if (text.isEmpty) return null;
    final tokens = <String>[];
    for (final raw in text.split(RegExp(r'\s+'))) {
      if (raw.isEmpty) continue;
      final cleaned =
          raw.replaceAll(RegExp(r'[^\p{L}\p{N}_]', unicode: true), '');
      if (cleaned.isEmpty) continue;
      tokens.add('"$cleaned"');
    }
    if (tokens.isEmpty) return null;
    return tokens.join(' OR ');
  }
}
