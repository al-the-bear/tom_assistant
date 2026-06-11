// RecursionLimitExceeded — thrown when a `runProcedure` call would push
// the procedure call chain past the hard depth cap
// (`RunProcedurePrimitive.defaultHardDepthCap`, set very high — effectively
// unlimited; `tom_brain_procedure_specification.md` § 8 error table, PE-3;
// `tom_brain_definition.md` § 7.3).
//
// PE-3: "`runProcedure(...)` may not exceed the hard depth cap; the next level
// errors with `RecursionLimitExceeded`. `request_depth_extension` does
// **not** exist in the prototype." The cap is a *hard* ceiling: it cannot
// be raised from inside the engine in v1, so this error is terminal for
// the offending call chain.

/// The canonical wire code every recursion-limit failure carries.
///
/// Matches the `PE-3` row in the spec error table
/// (`tom_brain_procedure_specification.md` § 8). Kept as a named
/// constant so the engine's failure-event mapping (C.44) can route on the
/// wire code without string-matching the message — the same idiom the
/// loader/validator codes follow.
const String recursionLimitExceededCode = 'recursion.limit.exceeded';

/// Raised when a `runProcedure` invocation would exceed the engine's hard
/// recursion depth cap.
///
/// Carries the [attemptedDepth] the rejected call would have run at, the
/// [hardDepthCap] that was breached, and which procedure ([procedureId] /
/// [version]) the rejected invocation targeted — enough for a trail entry
/// to identify exactly which call in the chain hit the ceiling.
final class RecursionLimitExceeded implements Exception {
  /// Records a rejected over-cap invocation.
  const RecursionLimitExceeded({
    required this.attemptedDepth,
    required this.hardDepthCap,
    required this.procedureId,
    this.version,
  });

  /// The depth the rejected call would have executed at (always greater
  /// than [hardDepthCap]).
  final int attemptedDepth;

  /// The hard ceiling that was breached.
  final int hardDepthCap;

  /// The id of the procedure the rejected invocation targeted.
  final String procedureId;

  /// The explicit version requested, when the caller pinned one.
  final int? version;

  /// The wire code carried by every recursion-limit failure.
  String get code => recursionLimitExceededCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final target = version == null ? procedureId : '$procedureId (v$version)';
    return 'runProcedure to "$target" would run at depth $attemptedDepth, '
        'exceeding the hard recursion cap of $hardDepthCap';
  }

  @override
  String toString() => 'RecursionLimitExceeded: $message';
}
