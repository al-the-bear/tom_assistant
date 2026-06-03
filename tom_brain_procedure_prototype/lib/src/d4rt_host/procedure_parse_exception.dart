// ProcedureSourceParseException — the host-owned signal that a procedure's
// source failed to parse (`tom_brain_procedure_prototype_specification.md`
// § 10.4, failure class `procedure.parse.failed`; Q-C.46.1).
//
// ── Why this type exists ────────────────────────────────────────────
//
// The static `SandboxValidator` gates a procedure's *imports* and *banned
// identifiers* lexically (it is deliberately not a full Dart parser — see
// `validator/code_projection.dart`). The authority on *syntax* is the d4rt
// runtime parser, which lives behind the host. When the interpreter rejects a
// source string with a parse / syntax error, the host re-raises it as this
// typed exception so callers can tell a *source* failure (the procedure never
// ran) apart from a *runtime* crash (the body threw mid-execution).
//
// The distinction is load-bearing for version-chain fallback (§ 10.4):
//
//   - `procedure.runtime.crash` is a fallback trigger — the dispatcher steps
//     the chain to an older, presumably-working version.
//   - `procedure.parse.failed` is *not* a fallback trigger — an older version
//     cannot repair a syntactically broken newer source; the break is in this
//     version's source. Stepping the chain on a parse error would mask the
//     real fault and silently run stale logic.
//
// Collapsing the two (recording every uncaught error as `runtime.crash`) would
// trigger a wrong fallback on a parse error. The engine classifies on this
// type (recording `procedure.parse.failed`) and the Phase-D fallback
// classifier treats it as a non-fallback failure.
//
// This file deliberately knows nothing about d4rt: the concrete interpreter
// exception type is isolated inside the host (`d4rt_dcli_host.dart`), which is
// the single place that translates it into this host-layer exception.

/// Raised when a procedure's source fails to parse before it runs (§ 10.4
/// `procedure.parse.failed`).
///
/// Distinct from a runtime crash: a parse failure means the procedure never
/// executed, so it must not step the version-chain fallback (an older version
/// cannot repair a syntactically broken newer one). The host raises this in
/// place of the underlying interpreter parse exception; the engine records it
/// under `procedure.parse.failed`, and `defaultFallbackClassifier` surfaces it
/// without stepping the chain.
final class ProcedureSourceParseException implements Exception {
  /// Builds a parse exception carrying the interpreter's [message]
  /// (the line/column-annotated parse diagnostics).
  const ProcedureSourceParseException(this.message);

  /// The parse diagnostics reported by the interpreter.
  final String message;

  @override
  String toString() => 'ProcedureSourceParseException: $message';
}
