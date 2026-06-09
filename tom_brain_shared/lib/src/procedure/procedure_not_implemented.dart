// ProcedureNotImplemented — thrown from inside a clear-error stub verb when it
// is invoked before its real loop ships
// (`tom_brain_procedure_prototype_specification.md` § 5.2.1, § 11).
//
// The prototype ships `plan_v1` / `create_v1` / `critique_v1` / `decide_v1` as
// stubs so the sugar verbs (`plan()` / `create()` / `critique()` / `decide()`)
// and the explicit `procedure.<verb>` tools resolve to a real, listable,
// contract-valid target. Invoking one is a programming error during the
// prototype window — the loop it stands for has not landed yet — so it fails
// loudly with a fixed, actionable message naming the stub, the loop to build,
// and the verb. This is deliberately *not* `ProcedureNotFound`: the procedure
// resolved and ran; it simply has no implementation behind it.
//
// Contrast with `ProcedureNotFound` (which stays in `tom_brain_procedure`):
// that is a resolver miss raised before any run; this is raised mid-run from
// the `notImplemented` engine-native primitive, and it crosses component
// boundaries onto `outcome.error`, so it lives in the shared vocabulary.

/// The canonical wire code every not-implemented stub failure carries.
///
/// Mirrors the `procedure.not_found` constant convention so a trail entry /
/// failure-event mapping can route on the code without string-matching the
/// message.
const String procedureNotImplementedCode = 'procedure.not_implemented';

/// Raised when a clear-error stub verb is invoked before its real loop ships.
///
/// [verb] is the bare sugar verb (`plan` / `create` / `critique` / `decide`).
/// The stub procedure id is `<verb>_v1` and the loop it stands for is named by
/// [loopKind]. [message] is the fixed § 5.2.1 contract:
///
/// > `<verb>_v1 is a stub — implement the <kind> loop before calling <verb>()`
final class ProcedureNotImplemented implements Exception {
  /// Records an invocation of the stub for [verb].
  const ProcedureNotImplemented(this.verb);

  /// The bare sugar verb the stub stands in for.
  final String verb;

  /// The wire code carried by every not-implemented failure.
  String get code => procedureNotImplementedCode;

  /// The name of the loop this stub stands for, derived from [verb]. Falls
  /// back to the verb itself for an unmapped verb so the message stays
  /// well-formed rather than throwing while building an error.
  String get loopKind => _loopKinds[verb] ?? verb;

  /// The fixed, actionable § 5.2.1 message.
  String get message =>
      '${verb}_v1 is a stub — implement the $loopKind loop before '
      'calling $verb()';

  @override
  String toString() => 'ProcedureNotImplemented: $message';

  /// Verb → loop-name mapping for the five sugar verbs. `think` is included
  /// for completeness even though `think_v1` is a no-op rather than a
  /// clear-error stub in the prototype.
  static const Map<String, String> _loopKinds = <String, String>{
    'think': 'thinking',
    'plan': 'planning',
    'create': 'creation',
    'critique': 'critique',
    'decide': 'decision',
  };
}
