// UnknownProcedureHint — thrown by dispatcher hint routing
// (Plan step D.16 / Q-E.50.1; `tom_brain_procedure_prototype_specification.md`
// § 10.2, § 8 error table).
//
// The Phase-E heuristic classifier (E.33) pre-fills `Access.envelope.kindHint`
// with a *procedure id* — memory's `bestMatch` over the procedure centroids
// (`classify(embedding, ClassificationTarget.procedure)`). When that hint is
// confident the dispatcher routes it **directly** as a procedure id, bypassing
// the kind→procedure map that the no-hint fallback path uses. This is the
// separation Q-E.50.1 settles: a centroid hint names the *procedure to run*,
// not an inbound *kind*, so it survives the moment a second procedure exists
// (the old prototype coincidence — `user_prompt` being both a kind and the
// routing key — no longer holds).
//
// A confident hint that names a procedure the prototype does not ship is a
// classifier/centroid drift the dispatcher must surface, never silently route:
// it fails loudly here with a named, inspectable error, mirroring
// `UnsupportedProcedureKind` on the no-hint path.

/// The canonical wire code every unknown-procedure-hint failure carries.
///
/// Kept as a named constant so the dispatcher failure-event mapping can route
/// on the wire code without string-matching the message — the same idiom the
/// loader/validator/`UnsupportedProcedureKind` codes follow.
const String unknownProcedureHintCode = 'procedure.hint.unknown';

/// Raised when dispatcher hint routing is handed a confident kind-hint that
/// names a procedure id the prototype does not ship.
///
/// Carries the offending [procedureId] (the centroid hint that had no shipped
/// procedure) and the [knownProcedureIds] routing *does* recognise, so a trail
/// entry or a caller can report exactly what was rejected and what would have
/// been accepted. Propagates unchanged through `Dispatcher.accept` (the D.14
/// failure-propagation contract).
final class UnknownProcedureHint implements Exception {
  /// Records a rejected procedure-id hint.
  const UnknownProcedureHint({
    required this.procedureId,
    required this.knownProcedureIds,
  });

  /// The procedure-id hint routing could not recognise (the confident
  /// centroid verdict that names no shipped procedure).
  final String procedureId;

  /// The procedure ids routing recognises (the prototype ships only
  /// `answer_with_memory_v1`). Listed in the message so the rejection names
  /// the accepted set, not just the offender.
  final List<String> knownProcedureIds;

  /// The wire code carried by every unknown-procedure-hint failure.
  String get code => unknownProcedureHintCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final known = knownProcedureIds.isEmpty
        ? '(none)'
        : knownProcedureIds.map((id) => '"$id"').join(', ');
    return 'procedure-id hint "$procedureId" names no shipped procedure; '
        'the prototype routes only: $known';
  }

  @override
  String toString() => 'UnknownProcedureHint: $message';
}
