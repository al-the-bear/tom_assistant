// ProcedureNotFound — thrown by the resolver (C.25) when no procedure (or
// no requested version of one) is known
// (`tom_brain_procedure_specification.md` § 8 error table, § 9).
//
// § 8 lists `ProcedureNotFound` as a Store/resolver failure that lets the
// "unimplemented sugar verbs surface informatively" (the bridged `plan` /
// `create` / `critique` / `decide` aliases resolve to a missing
// `<name>_v1` until Phase D loads the system library, § 1.4 / § 5.5). The
// resolver is the layer that owns the `(id → version)` index, so it is the
// natural place this failure originates.
//
// Two shapes of miss:
//   - the `id` is unknown to the resolver entirely ([version] is `null`);
//   - the `id` is known but the specifically requested [version] is not.
// Both carry the same wire code so a trail entry / failure-event mapping
// (C.44) can route on the code without string-matching the message.

/// The canonical wire code every procedure-not-found failure carries.
///
/// Mirrors the `procedure.header.invalid` constant convention so the
/// resolver, the engine's failure-event mapping (C.44), and the dispatcher
/// fallback executor (D.29–D.32) all agree on the exact string.
const String procedureNotFoundCode = 'procedure.not_found';

/// Raised when the resolver cannot find a procedure for an `(id, version)`
/// request.
///
/// [id] is always the procedure id that was requested. [version] is the
/// specific version that was asked for and not found, or `null` when the
/// `id` is unknown altogether (no version of it exists). [code] is always
/// [procedureNotFoundCode].
final class ProcedureNotFound implements Exception {
  /// Records a failed lookup.
  const ProcedureNotFound(this.id, {this.version});

  /// The requested procedure id.
  final String id;

  /// The requested version that was not found, or `null` when no version
  /// of [id] exists at all.
  final int? version;

  /// The wire code carried by every procedure-not-found failure.
  String get code => procedureNotFoundCode;

  /// Human-readable explanation, reused by [toString].
  String get message {
    final what = version == null
        ? 'no procedure with id "$id" is known'
        : 'procedure "$id" has no version $version';
    return '$code: $what';
  }

  @override
  String toString() => 'ProcedureNotFound: $message';
}
