// ProcedureRequiresMismatch — thrown by the contract validator (C.29) when
// a procedure's declared `requires` set does not match the bridged-API
// calls its body actually makes
// (`tom_brain_procedure_specification.md` § 4.4, § 7 row 5).
//
// § 7 row 5: "Declared `requires` matches actual bridged-API calls used" →
// `procedure.requires.mismatch`. The `requires` list is the procedure's
// declared capability surface; it must be exactly the set of bridged
// primitives the body calls. The validator rejects three faults under this
// one wire code:
//
//   - the body calls a bridged primitive the header did not declare
//     (an undeclared capability — [RequiresMismatchKind.undeclaredCall]);
//   - the header declares a primitive the body never calls
//     (a stale/over-broad declaration — [RequiresMismatchKind.unusedRequire]);
//   - the header declares a name that is not a bridged primitive at all
//     (a typo or invented capability — [RequiresMismatchKind.unknownPrimitive]).

/// The canonical wire code every requires-mismatch failure carries.
///
/// Matches the `procedure.requires.mismatch` event in the spec error tables
/// (§ 7, § 11). Kept as a named constant so the validator (C.29), the
/// engine's failure-event mapping (C.44), and any trail consumer agree on
/// the exact string without re-typing it.
const String procedureRequiresMismatchCode = 'procedure.requires.mismatch';

/// The category of requires mismatch a [ProcedureRequiresMismatch] records.
///
///   - [undeclaredCall] — the body calls [offender] but the header's
///     `requires` does not list it.
///   - [unusedRequire] — the header's `requires` lists [offender] but the
///     body never calls it.
///   - [unknownPrimitive] — the header's `requires` lists [offender], which
///     is not a recognised bridged primitive at all.
enum RequiresMismatchKind {
  /// A bridged primitive is called but not declared in `requires`.
  undeclaredCall,

  /// A `requires` entry is declared but never called.
  unusedRequire,

  /// A `requires` entry names a non-existent bridged primitive.
  unknownPrimitive,
}

/// Raised when a procedure's declared `requires` set does not exactly match
/// the bridged primitives its body calls.
///
/// [kind] names the category; [offender] is the exact primitive name at
/// fault; [procedureId] names the procedure when the validator was given a
/// loaded procedure rather than a bare source. [code] is always
/// [procedureRequiresMismatchCode] so a trail entry can route on the wire
/// code without string-matching the message.
final class ProcedureRequiresMismatch implements Exception {
  /// Records a rejected requires set.
  const ProcedureRequiresMismatch(
    this.reason, {
    required this.kind,
    required this.offender,
    this.procedureId,
  });

  /// The category of mismatch.
  final RequiresMismatchKind kind;

  /// The exact primitive name at fault.
  final String offender;

  /// The procedure's id when validation ran over a loaded procedure, or
  /// `null` when it ran over a bare source.
  final String? procedureId;

  /// Human-readable explanation of why the requires set was rejected.
  final String reason;

  /// The wire code carried by every requires-mismatch failure.
  String get code => procedureRequiresMismatchCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final where = procedureId == null ? '' : ' in "$procedureId"';
    return '$code$where: $reason';
  }

  @override
  String toString() => 'ProcedureRequiresMismatch: $message';
}
