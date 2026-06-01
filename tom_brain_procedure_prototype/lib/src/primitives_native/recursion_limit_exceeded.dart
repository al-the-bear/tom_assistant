// RecursionLimitExceeded — thrown when a `runProcedure` call would push
// the procedure call chain past the hard depth cap of 10
// (`tom_brain_procedure_prototype_specification.md` § 8 error table, PE-3;
// `tom_brain_definition.md` § 7.3).
//
// PE-3: "`runProcedure(...)` may not exceed depth 10; the 11th level
// errors with `RecursionLimitExceeded`. `request_depth_extension` does
// **not** exist in the prototype." The cap is a *hard* ceiling: it cannot
// be raised from inside the engine in v1, so this error is terminal for
// the offending call chain.

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

  /// The hard ceiling that was breached (10 in v1).
  final int hardDepthCap;

  /// The id of the procedure the rejected invocation targeted.
  final String procedureId;

  /// The explicit version requested, when the caller pinned one.
  final int? version;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final target = version == null ? procedureId : '$procedureId (v$version)';
    return 'runProcedure to "$target" would run at depth $attemptedDepth, '
        'exceeding the hard recursion cap of $hardDepthCap';
  }

  @override
  String toString() => 'RecursionLimitExceeded: $message';
}
