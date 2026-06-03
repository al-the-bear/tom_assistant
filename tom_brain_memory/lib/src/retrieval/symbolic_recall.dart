// SymbolicRecall — symbolic-mode executor for `RecallQuery.filter`
// (Plan step A.56, spec § 6.1 symbolic mode).
//
// What this file owns:
//
//   - Compiling a `SymbolicFilter` (already declared at A.24 in
//     `recall_query.dart`) into a parameterised SQL `WHERE` clause +
//     positional binding list, then running it against the `nodes`
//     table to produce a ranked candidate list.
//   - Mapping the eight `SymbolicOp` values to their SQL equivalents
//     (`=`, `!=`, `<`, `<=`, `>`, `>=`, `IN`, `NOT IN`), with
//     `null`-aware special-casing for `eq` / `ne` so an attribute
//     clause `(field, eq, null)` compiles to `IS NULL` rather than
//     the always-false `= NULL`.
//   - Routing attribute clauses through SQLite's `json_extract` so
//     callers can filter on any field stored inside `attrs_json`
//     without a column-per-attribute migration.
//   - Producing a deterministic ordering — newest-first by
//     `created_at_ms`, tie-broken by `id` — so two runs against the
//     same DB return the same list. (Symbolic mode has no natural
//     relevance score; the post-fusion stage at A.57 reduces every
//     mode to ranks anyway.)
//
// What this file does NOT own:
//
//   - Fusion across modes (A.57 RRF / weighted).
//   - Diversity (A.58 MMR).
//   - The `RecallReport` cost row. The recall executor at A.59 will
//     compose this output with the report.
//   - LLM re-rank. That is a caller-side hook on `RecallQuery`.
//
// Wire contract:
//
//   The `SymbolicRecallCandidate` carries `(nodeId, typeName,
//   createdAtMs)`. It deliberately does *not* carry the materialised
//   `Node` — that read happens in one bulk `NodeReader.getMany`
//   after fusion + diversity, so symbolic results that lose the
//   fusion stage do not cost a `nodes` row read each.
//
//   No score field is carried. The fusion stage treats symbolic
//   results purely by rank — `createdAtMs` is exposed only as a
//   stable secondary tie-breaker for downstream consumers that want
//   it.
//
// Compiler shape:
//
//   The compiler is exposed as `compileSymbolicFilter(SymbolicFilter)
//   -> CompiledSymbolicFilter`. The split lets tests assert the
//   pure-function compiler's output independently of running SQL
//   against a database — and lets a future graph-walk seed
//   pre-filter (A.61+) reuse the same compiler.
//
// Empty-filter semantics:
//
//   `SymbolicFilter()` with no clauses compiles to a tautology
//   (`WHERE 1`). That means a symbolic-only recall with an empty
//   filter returns the newest `perModeK` nodes in the database. This
//   is the "WHERE TRUE" reading; the `perModeK` cap is the safety.
//   See `prototype_implementation_questions.md` for the alternative
//   considered (refuse the empty filter).

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import 'recall_query.dart';

/// A single symbolic-mode candidate.
///
/// The recall executor returns these ordered by descending
/// [createdAtMs] (newest first), tie-broken by [NodeId] ascending
/// for determinism.
final class SymbolicRecallCandidate {
  /// The node the symbolic row points to.
  final NodeId nodeId;

  /// The node's type — kept on the candidate so the fusion stage
  /// can apply per-type weights without a second registry lookup.
  final String typeName;

  /// `nodes.created_at_ms` for the row. Carried so a downstream
  /// consumer can apply a secondary recency ordering without a
  /// second query.
  final int createdAtMs;

  const SymbolicRecallCandidate({
    required this.nodeId,
    required this.typeName,
    required this.createdAtMs,
  });

  @override
  String toString() => 'SymbolicRecallCandidate('
      'type: $typeName, id: $nodeId, createdAtMs: $createdAtMs)';
}

/// Result of [compileSymbolicFilter] — a parameterised `WHERE`
/// clause plus the positional binding list that fills the `?`
/// placeholders.
///
/// The [whereSql] is *without* a leading `WHERE` keyword so callers
/// can compose it into a larger query (e.g. prepended with a
/// `WHERE` keyword, or AND-ed into an existing one).
///
/// When the input filter is empty (no type names, no time bounds,
/// no producer, no attribute clauses), the compiler emits the
/// single-token tautology `1` — never the empty string — so the
/// caller's `WHERE ${whereSql}` template always produces valid SQL.
final class CompiledSymbolicFilter {
  /// The `WHERE`-clause body, parameterised with `?` placeholders.
  /// Never empty; always at least the literal `1`.
  final String whereSql;

  /// Positional bindings, in the order the `?`s appear in
  /// [whereSql]. Empty for the tautological filter.
  final List<Object?> bindings;

  const CompiledSymbolicFilter({
    required this.whereSql,
    required this.bindings,
  });
}

/// Compiles [filter] into a parameterised SQL `WHERE`-clause body
/// against the `nodes` table.
///
/// Mapping (spec § 6.1 symbolic mode):
///
///   * [SymbolicFilter.typeNames] → `type_name IN (?, ?, …)`
///     (skipped when empty).
///   * [SymbolicFilter.createdAfter] → `created_at_ms >= ?`
///     (inclusive lower bound, in epoch ms).
///   * [SymbolicFilter.createdBefore] → `created_at_ms < ?`
///     (exclusive upper bound, in epoch ms).
///   * [SymbolicFilter.producer] → `produced_by = ?`.
///   * [SymbolicFilter.attributes] → one
///     `json_extract(attrs_json, '$.field') op ?` clause per
///     `AttrClause`, AND-ed together with everything else.
///
/// Attribute-op mapping:
///
///   * `eq`/`ne` with non-null value: `=` / `!=`.
///   * `eq` with null value: `IS NULL`.
///   * `ne` with null value: `IS NOT NULL`.
///   * `lt`, `lte`, `gt`, `gte`: `<`, `<=`, `>`, `>=`.
///   * `inList`/`notInList`: `IN (?, ?, …)` / `NOT IN (?, ?, …)`.
///
/// Throws [ArgumentError] when:
///
///   * An `AttrClause.field` is empty or contains characters that
///     would break the JSON path. Field names are validated against
///     `[A-Za-z_][A-Za-z0-9_]*` — the same shape `FieldSpec.name`
///     uses elsewhere in the package.
///   * An `inList` / `notInList` value is not a `List` or is an
///     empty list. Empty `IN ()` is invalid SQL and the safer
///     reading of an empty in-list is "programmer error" rather
///     than "always false / always true".
///   * `lt`/`lte`/`gt`/`gte` is given a `null` value (the SQL
///     comparison would always be NULL, never true — almost
///     certainly a programmer error).
///
/// Never concatenates values into the SQL string — every value goes
/// through a `?` placeholder.
CompiledSymbolicFilter compileSymbolicFilter(SymbolicFilter filter) {
  final clauses = <String>[];
  final bindings = <Object?>[];

  if (filter.typeNames.isNotEmpty) {
    final placeholders =
        List<String>.filled(filter.typeNames.length, '?').join(', ');
    clauses.add('type_name IN ($placeholders)');
    bindings.addAll(filter.typeNames);
  }

  if (filter.createdAfter != null) {
    clauses.add('created_at_ms >= ?');
    bindings.add(filter.createdAfter!.toMs());
  }

  if (filter.createdBefore != null) {
    clauses.add('created_at_ms < ?');
    bindings.add(filter.createdBefore!.toMs());
  }

  if (filter.producer != null) {
    clauses.add('produced_by = ?');
    bindings.add(filter.producer);
  }

  for (final attr in filter.attributes) {
    _appendAttrClause(attr, clauses, bindings);
  }

  if (clauses.isEmpty) {
    return const CompiledSymbolicFilter(whereSql: '1', bindings: <Object?>[]);
  }
  return CompiledSymbolicFilter(
    whereSql: clauses.join(' AND '),
    bindings: bindings,
  );
}

void _appendAttrClause(
  AttrClause clause,
  List<String> clauses,
  List<Object?> bindings,
) {
  _validateAttrFieldName(clause.field);
  // json_extract path: `$.<field>`. The field-name validation above
  // restricts the field to identifier characters, so the path is
  // safe to embed without further escaping.
  final path = '\$.${clause.field}';

  switch (clause.op) {
    case SymbolicOp.eq:
      if (clause.value == null) {
        clauses.add('json_extract(attrs_json, ?) IS NULL');
        bindings.add(path);
      } else {
        clauses.add('json_extract(attrs_json, ?) = ?');
        bindings
          ..add(path)
          ..add(clause.value);
      }
      return;
    case SymbolicOp.ne:
      if (clause.value == null) {
        clauses.add('json_extract(attrs_json, ?) IS NOT NULL');
        bindings.add(path);
      } else {
        // `json_extract(...) != ?` does not match rows where the
        // extracted value is NULL; we explicitly include them so
        // `(field, ne, "x")` matches both `field == "y"` and `field
        // missing`. This mirrors the typical "not equal" intuition.
        clauses.add(
          '(json_extract(attrs_json, ?) != ? '
          'OR json_extract(attrs_json, ?) IS NULL)',
        );
        bindings
          ..add(path)
          ..add(clause.value)
          ..add(path);
      }
      return;
    case SymbolicOp.lt:
    case SymbolicOp.lte:
    case SymbolicOp.gt:
    case SymbolicOp.gte:
      if (clause.value == null) {
        throw ArgumentError.value(
          clause.value,
          'AttrClause.value',
          'Operator ${clause.op.name} cannot be applied to a null value '
              '(SQL comparison with NULL is never true). For "is null" '
              'use SymbolicOp.eq with value null.',
        );
      }
      final sqlOp = switch (clause.op) {
        SymbolicOp.lt => '<',
        SymbolicOp.lte => '<=',
        SymbolicOp.gt => '>',
        SymbolicOp.gte => '>=',
        _ => throw StateError('unreachable'),
      };
      clauses.add('json_extract(attrs_json, ?) $sqlOp ?');
      bindings
        ..add(path)
        ..add(clause.value);
      return;
    case SymbolicOp.inList:
    case SymbolicOp.notInList:
      final values = clause.value;
      if (values is! List) {
        throw ArgumentError.value(
          values,
          'AttrClause.value',
          'Operator ${clause.op.name} requires a List value; got '
              '${values?.runtimeType ?? 'null'}.',
        );
      }
      if (values.isEmpty) {
        throw ArgumentError.value(
          values,
          'AttrClause.value',
          'Operator ${clause.op.name} requires a non-empty list. Empty '
              'IN-lists are programmer errors; remove the clause if the '
              'intent was "no constraint".',
        );
      }
      final placeholders = List<String>.filled(values.length, '?').join(', ');
      final keyword = clause.op == SymbolicOp.inList ? 'IN' : 'NOT IN';
      clauses.add('json_extract(attrs_json, ?) $keyword ($placeholders)');
      bindings.add(path);
      bindings.addAll(values);
      return;
  }
}

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

void _validateAttrFieldName(String field) {
  if (!_identifierPattern.hasMatch(field)) {
    throw ArgumentError.value(
      field,
      'AttrClause.field',
      'Attribute field name must match [A-Za-z_][A-Za-z0-9_]* — the JSON '
          'path \$.${jsonEncode(field)} would otherwise be ambiguous or '
          'unsafe to inline.',
    );
  }
}

/// Symbolic mode executor.
///
/// One instance per open memory store. Stateless across calls; safe
/// to share between callers on the same SQLite connection.
final class SymbolicRecall {
  /// Live SQLite handle on `memory.db`. Owned by the store opener.
  final Database _db;

  /// Constructs the executor.
  SymbolicRecall({required Database memoryDb}) : _db = memoryDb;

  // ─── Public surface ────────────────────────────────────────────

  /// Runs the symbolic mode against [filter].
  ///
  /// Contract:
  ///
  ///   * Returns at most [perModeK] candidates, ordered newest-first
  ///     by `created_at_ms`, tie-broken by `id` ascending.
  ///   * [perModeK] <= 0 returns empty without issuing SQL.
  ///   * An empty [SymbolicFilter] (no clauses) compiles to the
  ///     tautology and returns the newest [perModeK] nodes in the
  ///     database. The cap is the safety; callers that mean
  ///     "match nothing" should not call symbolic mode at all.
  ///
  /// Throws [ArgumentError] when an attribute clause is malformed
  /// (see [compileSymbolicFilter]). Database-level errors propagate
  /// as `SqliteException`; the recall executor at A.59 catches them
  /// per-mode and degrades the mode rather than aborting the whole
  /// recall.
  List<SymbolicRecallCandidate> recall({
    required SymbolicFilter filter,
    int perModeK = 64,
  }) {
    if (perModeK <= 0) return const <SymbolicRecallCandidate>[];

    final compiled = compileSymbolicFilter(filter);

    final rows = _db.select(
      'SELECT id, type_name, created_at_ms '
      'FROM nodes '
      'WHERE ${compiled.whereSql} '
      'ORDER BY created_at_ms DESC, id ASC '
      'LIMIT ?',
      <Object?>[...compiled.bindings, perModeK],
    );

    final results = <SymbolicRecallCandidate>[];
    for (final row in rows) {
      results.add(
        SymbolicRecallCandidate(
          nodeId: NodeId.fromString(row['id'] as String),
          typeName: row['type_name'] as String,
          createdAtMs: (row['created_at_ms'] as num).toInt(),
        ),
      );
    }
    return List<SymbolicRecallCandidate>.unmodifiable(results);
  }
}
