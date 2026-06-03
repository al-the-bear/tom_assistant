// SymbolicFilter — a cross-component primitive for narrowing a node
// query by type, time window, producer-scope, and per-attribute clauses.
//
// Why this type lives in `tom_brain_shared`
// -----------------------------------------
// The symbolic-mode retrieval path in `tom_brain_memory` is the **first**
// consumer of `SymbolicFilter`, but the type itself is shape-only: it
// carries no implementation, no I/O, no SQLite touch. The compiler that
// turns a filter into a parameterised SQL `WHERE` clause lives in memory
// (`retrieval/symbolic_recall.dart`); the filter shape itself is
// consumer-side and should not require importing the storage stack.
//
// Subsequent consumers — the procedure engine's bridged primitive `recall`
// (Phase C), the procedure dispatcher's primitive-act API (Phase D), the
// access edge's REST/SSE handlers (Phase E) — all need to construct
// `SymbolicFilter` values to hand into `recall(RecallQuery)` without
// taking on a runtime dependency on `tom_brain_memory`. Per the
// `tom_brain` quest overview (Hard Principle 1, "no backwards
// compatibility"), the type moves cleanly to shared at A.88 rather than
// living a parallel re-export life later.
//
// Compile-time `const` form
// -------------------------
// The constructor is `const` and stores caller-supplied collections
// directly. This matches the original (pre-A.88) behaviour and lets the
// 30+ call sites that build `const SymbolicFilter(...)` continue to do
// so. The contract is documented: callers must not mutate a `Set` or
// `List` after handing it in. Mutation-by-aliasing is a producer bug
// rather than a defended-against case.
//
// What `SymbolicFilter` is NOT
// ----------------------------
//   * It is **not** the compiled SQL form. The compiler
//     (`CompiledSymbolicFilter`, `compileSymbolicFilter`) stays in
//     `tom_brain_memory/retrieval/symbolic_recall.dart`, because the
//     compiled form is intimately tied to the memory schema (table
//     names, column types, FTS5 join semantics).
//   * It is **not** the recall pipeline's entry point. That is
//     `RecallQuery` (currently still in memory). The decision to keep
//     `RecallQuery` in memory at A.88 is recorded in
//     `_ai/quests/tom_brain/prototype_implementation_details.md` § A.88.
//   * It does **not** know about node-type identity (only string names),
//     producer scopes (only the bare string), or attribute column
//     types — that pairing happens at compile time inside memory.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show listEquals, setEquals;

import '../time/brain_time.dart';
import 'attr_clause.dart';

/// Compiled-down `WHERE`-shape used by the memory symbolic retrieval
/// mode.
///
/// `SymbolicFilter` carries the **shape** of a node filter. The actual
/// SQL compiler that turns this into a parameterised `WHERE` clause lives
/// in `tom_brain_memory/retrieval/symbolic_recall.dart`.
final class SymbolicFilter {
  /// Node type names to include. Empty = no type filter.
  ///
  /// Stored as-supplied; the constructor is `const`. Callers must not
  /// mutate the passed-in set after construction.
  final Set<String> typeNames;

  /// Lower bound (inclusive) on `createdAt`. `null` = open.
  ///
  /// A [BrainTime] — the package's canonical timestamp — so the memory
  /// compiler reads `createdAfter.toMs()` directly against the indexed
  /// `created_at_ms` column with no zone-coercion step.
  final BrainTime? createdAfter;

  /// Upper bound (exclusive) on `createdAt`. `null` = open.
  ///
  /// A [BrainTime], for the same reason as [createdAfter].
  final BrainTime? createdBefore;

  /// Producer-scope filter (a `Scope.producer` value).
  final String? producer;

  /// Attribute clauses; ANDed together.
  ///
  /// Stored as-supplied; the constructor is `const`. Callers must not
  /// mutate the passed-in list after construction.
  final List<AttrClause> attributes;

  const SymbolicFilter({
    this.typeNames = const <String>{},
    this.createdAfter,
    this.createdBefore,
    this.producer,
    this.attributes = const <AttrClause>[],
  });

  /// Whether this filter would narrow nothing — equivalent to "no
  /// filter at all". Useful for callers that want to short-circuit the
  /// symbolic mode when the filter is vacuous.
  bool get isEmpty =>
      typeNames.isEmpty &&
      createdAfter == null &&
      createdBefore == null &&
      producer == null &&
      attributes.isEmpty;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SymbolicFilter) return false;
    if (createdAfter != other.createdAfter) return false;
    if (createdBefore != other.createdBefore) return false;
    if (producer != other.producer) return false;
    if (!setEquals(typeNames, other.typeNames)) return false;
    return listEquals(attributes, other.attributes);
  }

  @override
  int get hashCode {
    // Unordered set hash for typeNames; ordered list hash for attributes
    // (clauses are ANDed but their textual order is part of the filter
    // identity — we do not canonicalise).
    return Object.hash(
      Object.hashAllUnordered(typeNames),
      createdAfter,
      createdBefore,
      producer,
      Object.hashAll(attributes),
    );
  }

  @override
  String toString() {
    final parts = <String>[];
    if (typeNames.isNotEmpty) parts.add('types=$typeNames');
    if (createdAfter != null) parts.add('after=$createdAfter');
    if (createdBefore != null) parts.add('before=$createdBefore');
    if (producer != null) parts.add('producer=$producer');
    if (attributes.isNotEmpty) parts.add('attrs=$attributes');
    return 'SymbolicFilter(${parts.join(', ')})';
  }
}
