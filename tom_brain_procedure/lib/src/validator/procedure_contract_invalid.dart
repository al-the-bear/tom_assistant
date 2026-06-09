// ProcedureContractInvalid — thrown by the contract validator (C.29) when a
// procedure's entry point does not match the required signature
// (`tom_brain_procedure_specification.md` § 4.3, § 7 row 4).
//
// § 4.3: a procedure declares a single top-level async function over the
// bridged input/output classes:
//
//   Future<ProcedureResult> run(ProcedureInputs inputs) async { /* body */ }
//
// § 7 row 4: "Entry point `run(ProcedureInputs)` present with the expected
// signature" → `procedure.contract.invalid`. This is the *static* gate; the
// runtime additionally checks that `run` returns a `ProcedureResult` and not
// something else (`procedure.contract.violation`, § 4.3). A procedure whose
// entry point is missing or mis-shaped is rejected here before it ever
// reaches the host.

/// The canonical wire code every contract-invalid failure carries.
///
/// Matches the `procedure.contract.invalid` event in the spec error tables
/// (§ 7, § 11). Kept as a named constant so the validator (C.29), the
/// engine's failure-event mapping (C.44), and any trail consumer agree on
/// the exact string without re-typing it.
const String procedureContractInvalidCode = 'procedure.contract.invalid';

/// The category of contract violation a [ProcedureContractInvalid] records.
///
/// Distinguishes the four shape faults the C.29 signature check can find so
/// a trail entry or test can branch on the cause without parsing the human
/// message:
///
///   - [missingEntryPoint] — no top-level `run(...)` function was found.
///   - [wrongParameterType] — `run` exists but its single parameter is not
///     typed `ProcedureInputs` (wrong type, or wrong arity).
///   - [wrongReturnType] — `run`'s return type is not
///     `Future<ProcedureResult>`.
///   - [notAsync] — `run` is not declared `async`.
enum ContractViolationKind {
  /// No top-level `run(...)` entry point was found.
  missingEntryPoint,

  /// The `run` parameter is not a single `ProcedureInputs`.
  wrongParameterType,

  /// The `run` return type is not `Future<ProcedureResult>`.
  wrongReturnType,

  /// `run` is not declared `async`.
  notAsync,
}

/// Raised when a procedure's entry point does not match the required
/// `Future<ProcedureResult> run(ProcedureInputs inputs) async { … }`
/// signature.
///
/// [kind] names the category; [line] is the 1-based line in the source the
/// fault was located at (0 when unknown — e.g. a missing entry point);
/// [procedureId] names the procedure when the validator was given a loaded
/// procedure rather than a bare source. [code] is always
/// [procedureContractInvalidCode] so a trail entry can route on the wire
/// code without string-matching the message.
final class ProcedureContractInvalid implements Exception {
  /// Records a rejected entry point.
  const ProcedureContractInvalid(
    this.reason, {
    required this.kind,
    this.line = 0,
    this.procedureId,
  });

  /// The category of violation.
  final ContractViolationKind kind;

  /// 1-based line where the fault was located, or `0` when the validator
  /// could not attribute a line (e.g. a missing entry point).
  final int line;

  /// The procedure's id when validation ran over a loaded procedure, or
  /// `null` when it ran over a bare source.
  final String? procedureId;

  /// Human-readable explanation of why the entry point was rejected.
  final String reason;

  /// The wire code carried by every contract-invalid failure.
  String get code => procedureContractInvalidCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final where = procedureId == null ? '' : ' in "$procedureId"';
    final at = line > 0 ? ' (line $line)' : '';
    return '$code$where$at: $reason';
  }

  @override
  String toString() => 'ProcedureContractInvalid: $message';
}
