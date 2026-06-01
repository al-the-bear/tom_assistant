// HeaderValidator — the first of the three validator layers (Plan step
// C.27; `tom_brain_procedure_prototype_specification.md` § 7).
//
// The validator runs **before a procedure reaches `draft`/runnable**. This
// layer owns the spec's first row — "Header parses, all required fields
// present, version monotonic" → `procedure.header.invalid`. It sits one
// level above the loader (C.24): the loader enforces required fields *as it
// parses one source's header*; the validator re-affirms them at the
// *header-object boundary* and adds the two checks the loader cannot make
// because they need more than one header in view:
//
//   - **Version monotonicity** — across an id's whole version set (the
//     resolver's `[v_latest, …, v1]` chain), versions must be positive and
//     strictly increasing (no duplicates, no zero/negative versions).
//   - **Success-criterion presence** — re-asserted at the header level so a
//     brain-authored `Procedure` node constructed in memory (not via the
//     loader) cannot slip a runnable procedure past the gate with an empty
//     criterion.
//
// Why re-check required fields the loader already guarantees: not every
// header reaches the validator through the loader. A brain-authored
// procedure arrives as a `ProcedureHeader` built directly from a memory
// node; the validator is its only gate. Validating at this boundary is the
// "validate at system boundaries" rule, not redundant defence over a
// trusted internal caller. Every failure carries the wire code
// `procedure.header.invalid` (via [ProcedureHeaderInvalid]) so a trail
// entry routes on the code, exactly as the loader's failures do.

import '../procedure_store/procedure_header.dart';
import '../procedure_store/procedure_header_invalid.dart';
import '../procedure_store/procedure_loader.dart';

/// Validates procedure headers: required-field presence (including the
/// success criterion) on a single header, and version monotonicity across
/// an id's version set (§ 7).
///
/// Stateless — every method is a pure function of its input. Construct once
/// and reuse, or use the [shared] instance. Failures throw
/// [ProcedureHeaderInvalid] (wire code `procedure.header.invalid`).
final class HeaderValidator {
  const HeaderValidator();

  /// A shared, reusable validator (holds no state).
  static const HeaderValidator shared = HeaderValidator();

  /// Validates a single [header]'s required fields, including
  /// success-criterion presence.
  ///
  /// The five required fields (`id`, `version`, `summary`,
  /// `successCriterion`, `budget`) are non-null by [ProcedureHeader]'s
  /// type, but a header built directly (not via the loader) can still carry
  /// empty strings, a non-positive version, or an empty budget. Each of
  /// those is rejected here:
  ///
  ///   - [ProcedureHeader.id] must be non-empty (after trimming);
  ///   - [ProcedureHeader.version] must be `>= 1`;
  ///   - [ProcedureHeader.summary] must be non-empty;
  ///   - [ProcedureHeader.successCriterion] must be non-empty;
  ///   - [ProcedureHeader.budget] must declare at least one cap.
  ///
  /// Throws [ProcedureHeaderInvalid] on the first violation, with [field]
  /// naming the offending field.
  void validateHeader(ProcedureHeader header) {
    _requireNonEmpty(header.id, 'id');
    if (header.version < 1) {
      throw ProcedureHeaderInvalid(
        'must be a positive integer (>= 1), was ${header.version}',
        field: 'version',
      );
    }
    _requireNonEmpty(header.summary, 'summary');
    _requireNonEmpty(header.successCriterion, 'successCriterion');
    if (header.budget.isEmpty) {
      throw const ProcedureHeaderInvalid(
        'must declare at least one cap',
        field: 'budget',
      );
    }
  }

  /// Validates that the [versions] of one [id] form a monotonic chain:
  /// non-empty, every version positive (`>= 1`), and strictly increasing
  /// with no duplicates.
  ///
  /// Accepts the versions in any order (the resolver hands them back
  /// **descending**; a raw scan may hand them in any order) and judges
  /// monotonicity on the ascending sort. A duplicate `(id, version)` — two
  /// sources claiming the same identity — is the most common real fault and
  /// surfaces here as a monotonicity violation rather than silently
  /// collapsing.
  ///
  /// Gaps in the sequence (e.g. `[1, 3]` after `v2` was demoted) are
  /// **allowed**: procedures are never deleted, only demoted, so a missing
  /// intermediate version is a legitimate history, not a malformed chain.
  ///
  /// Throws [ProcedureHeaderInvalid] (field `version`) on any violation.
  void validateVersionChain(String id, Iterable<int> versions) {
    final sorted = versions.toList(growable: false)..sort();
    if (sorted.isEmpty) {
      throw ProcedureHeaderInvalid(
        'no versions known for id "$id"',
        field: 'version',
      );
    }
    if (sorted.first < 1) {
      throw ProcedureHeaderInvalid(
        'id "$id" has a non-positive version ${sorted.first}; '
        'versions must be >= 1',
        field: 'version',
      );
    }
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] == sorted[i - 1]) {
        throw ProcedureHeaderInvalid(
          'id "$id" declares version ${sorted[i]} more than once; '
          'versions must be strictly increasing',
          field: 'version',
        );
      }
    }
  }

  /// Validates a whole loaded set: each header individually
  /// ([validateHeader]) and each id's version chain ([validateVersionChain]).
  ///
  /// This is the integration point the engine uses after the resolver is
  /// built — it groups [procedures] by id, checks every header is
  /// well-formed, and checks every id's version set is monotonic. Throws
  /// [ProcedureHeaderInvalid] on the first violation found.
  void validateAll(Iterable<LoadedProcedure> procedures) {
    final versionsById = <String, List<int>>{};
    for (final proc in procedures) {
      validateHeader(proc.header);
      versionsById
          .putIfAbsent(proc.header.id, () => <int>[])
          .add(proc.header.version);
    }
    for (final entry in versionsById.entries) {
      validateVersionChain(entry.key, entry.value);
    }
  }

  void _requireNonEmpty(String value, String field) {
    if (value.trim().isEmpty) {
      throw ProcedureHeaderInvalid(
        'must be a non-empty string',
        field: field,
      );
    }
  }
}
