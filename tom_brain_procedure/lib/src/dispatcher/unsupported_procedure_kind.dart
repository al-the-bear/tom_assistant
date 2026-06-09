// UnsupportedProcedureKind — thrown by dispatcher procedure selection
// (Plan step D.16; `tom_brain_procedure_specification.md` § 10.2,
// § 8 error table).
//
// Spec § 10.2: "For the prototype, every inbound classified as
// `user_prompt` routes to `answer_with_memory_v1`; anything else surfaces
// `UnsupportedProcedureKind`." § 8 error table: "Dispatcher selection —
// Non-`user_prompt` inbound rejected loudly."
//
// The prototype routes exactly one inbound kind. Selection deliberately
// fails *loudly* on any other kind rather than silently dropping the
// request or guessing a procedure: the dispatcher's classifier (D.15) emits
// open kind strings, so an unanticipated kind reaches selection and is
// rejected here with a named, inspectable error — not impossible to
// represent (Q-D.15.1). The error propagates unchanged through
// `Dispatcher.accept` (the D.14 failure-propagation contract).

/// The canonical wire code every unsupported-kind failure carries.
///
/// Kept as a named constant so the dispatcher failure-event mapping can
/// route on the wire code without string-matching the message — the same
/// idiom the loader/validator codes follow.
const String unsupportedProcedureKindCode = 'procedure.kind.unsupported';

/// Raised when dispatcher selection is asked to route an inbound kind the
/// prototype does not support.
///
/// Carries the offending [kind] (the classifier verdict that had no
/// procedure mapping) and the [supportedKinds] selection *does* understand,
/// so a trail entry or a caller can report exactly what was rejected and
/// what would have been accepted.
final class UnsupportedProcedureKind implements Exception {
  /// Records a rejected inbound kind.
  const UnsupportedProcedureKind({
    required this.kind,
    required this.supportedKinds,
  });

  /// The inbound kind selection could not map to a procedure.
  final String kind;

  /// The kinds selection has a procedure mapping for (the prototype routes
  /// only `user_prompt`). Listed in the message so the rejection names the
  /// accepted set, not just the offender.
  final List<String> supportedKinds;

  /// The wire code carried by every unsupported-kind failure.
  String get code => unsupportedProcedureKindCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final supported = supportedKinds.isEmpty
        ? '(none)'
        : supportedKinds.map((k) => '"$k"').join(', ');
    return 'inbound kind "$kind" has no procedure mapping; '
        'the prototype routes only: $supported';
  }

  @override
  String toString() => 'UnsupportedProcedureKind: $message';
}
