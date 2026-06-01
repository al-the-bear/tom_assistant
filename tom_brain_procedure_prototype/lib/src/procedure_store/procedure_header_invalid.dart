// ProcedureHeaderInvalid — thrown by the loader (C.24) when a procedure's
// structured header (§ 4.4) cannot be parsed or is missing a required
// field (`tom_brain_procedure_prototype_specification.md` § 4.4, § 7
// error table, § 8).
//
// § 4.4: "A header missing `id`, `version`, `summary`, `successCriterion`,
// or `budget` is rejected with `procedure.header.invalid`." § 7 lists the
// same wire code for "Header parses, all required fields present, version
// monotonic". The loader owns the *parse + required-field* portion of that
// check; version monotonicity across a version chain is the validator's
// (C.27) job, so this error is raised only for a single header that does
// not parse or lacks a required field.

/// The canonical wire code every header-invalid failure carries.
///
/// Matches the `procedure.header.invalid` event in the spec error tables
/// (§ 4.4, § 7, § 8). Kept as a named constant so the loader, the
/// validator (C.27), and the engine's failure-event mapping (C.44) all
/// agree on the exact string.
const String procedureHeaderInvalidCode = 'procedure.header.invalid';

/// Raised when a procedure's structured header cannot be parsed into a
/// [ProcedureHeader] or is missing a required field.
///
/// Carries the offending [field] when the fault is a missing/ill-typed
/// named field (e.g. `version`), or `null` when the fault is structural
/// (no `@procedure` marker, malformed YAML). [reason] explains the fault
/// in human terms; [code] is always [procedureHeaderInvalidCode] so a
/// trail entry can route on the wire code without string-matching the
/// message.
final class ProcedureHeaderInvalid implements Exception {
  /// Records a rejected header.
  const ProcedureHeaderInvalid(this.reason, {this.field});

  /// The field that was missing or ill-typed, or `null` for a structural
  /// fault (no marker / unparseable YAML).
  final String? field;

  /// Human-readable explanation of why the header was rejected.
  final String reason;

  /// The wire code carried by every header-invalid failure.
  String get code => procedureHeaderInvalidCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final where = field == null ? '' : ' (field "$field")';
    return '$code$where: $reason';
  }

  @override
  String toString() => 'ProcedureHeaderInvalid: $message';
}
