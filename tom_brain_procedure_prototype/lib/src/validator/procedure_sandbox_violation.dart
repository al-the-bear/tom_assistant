// ProcedureSandboxViolation — thrown by the sandbox validator (C.28) when
// a procedure's verbatim source reaches outside the bridged primitive API
// (`tom_brain_procedure_prototype_specification.md` § 7 row 3, § 4.2,
// invariant PE-1).
//
// PE-1: "The bridged primitive API is the only surface a procedure can
// touch." Enforced at two layers — the d4rt sandbox (runtime) and the
// bridge (effects). The sandbox validator is the *static* half of that
// lock: before a procedure reaches `draft`/runnable it is scanned, and any
// `import`/`export` directive or reference to a disallowed top-level
// identifier (`Process`, `File`, `Isolate`, …) is rejected with the wire
// code `procedure.sandbox.violation`. The runtime layer would also stop
// such a script, but a static refusal keeps a malformed procedure out of
// the runnable set entirely (def § 14.7, proc § P3).

/// The canonical wire code every sandbox-violation failure carries.
///
/// Matches the `procedure.sandbox.violation` event in the spec error
/// tables (§ 7, § 11). Kept as a named constant so the validator (C.28),
/// the engine's failure-event mapping (C.44), and any trail consumer agree
/// on the exact string without re-typing it.
const String procedureSandboxViolationCode = 'procedure.sandbox.violation';

/// The category of sandbox violation a [ProcedureSandboxViolation] records.
///
/// Distinguishes the two static checks C.28 owns so a trail entry or test
/// can branch on the cause without parsing the human message:
///
///   - [forbiddenDirective] — the source contains an `import` / `export`
///     directive; procedures may not import anything (§ 4.2).
///   - [disallowedIdentifier] — the source references a banned top-level
///     identifier (an SDK gateway such as `Process`, `File`, `Isolate`).
enum SandboxViolationKind {
  /// An `import` / `export` directive was found.
  forbiddenDirective,

  /// A banned top-level identifier was referenced.
  disallowedIdentifier,
}

/// Raised when a procedure's source reaches outside the bridged primitive
/// API: an `import`/`export` directive, or a reference to a disallowed
/// top-level identifier.
///
/// [kind] names the category; [offender] is the exact directive keyword or
/// identifier that triggered the rejection; [line] is the 1-based line in
/// the source where it was found (0 when unknown); [procedureId] names the
/// procedure when the validator was given a loaded procedure rather than a
/// bare source. [code] is always [procedureSandboxViolationCode] so a trail
/// entry can route on the wire code without string-matching the message.
final class ProcedureSandboxViolation implements Exception {
  /// Records a rejected source.
  const ProcedureSandboxViolation(
    this.reason, {
    required this.kind,
    required this.offender,
    this.line = 0,
    this.procedureId,
  });

  /// The category of violation.
  final SandboxViolationKind kind;

  /// The exact directive keyword (`import`/`export`) or identifier that
  /// triggered the rejection.
  final String offender;

  /// 1-based line where [offender] was found, or `0` when the validator
  /// could not attribute a line.
  final int line;

  /// The procedure's id when validation ran over a loaded procedure, or
  /// `null` when it ran over a bare source.
  final String? procedureId;

  /// Human-readable explanation of why the source was rejected.
  final String reason;

  /// The wire code carried by every sandbox-violation failure.
  String get code => procedureSandboxViolationCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final where = procedureId == null ? '' : ' in "$procedureId"';
    final at = line > 0 ? ' (line $line)' : '';
    return '$code$where$at: $reason';
  }

  @override
  String toString() => 'ProcedureSandboxViolation: $message';
}
