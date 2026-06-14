// PT-3.3 / PT-4.x — the source-authoring write results (§ 6.3, AUTH-1…AUTH-3).
// The web client marshals a `PUT /api/procedures/<id>` (a d4rt script) or
// `PUT /api/prompts/<roleId>/<part>` (a role's externalized prose) into one of
// these, so an edit view can show "saved" or surface the brain's own validator
// findings on a `422` — never silently swallow a rejected save.

/// One validator finding behind a rejected procedure save (§ 6.3, AUTH-3). It is
/// a verbatim echo of the brain's `ProcedureValidationFinding.toMap()`: a stable
/// [code] (`procedure.header.invalid`, `procedure.sandbox.violation`, …), a
/// human [message], and the optional [field] the finding pins to.
class AuthoringFinding {
  final String code;
  final String message;
  final String? field;

  const AuthoringFinding({
    required this.code,
    required this.message,
    this.field,
  });

  factory AuthoringFinding.fromJson(Map<String, dynamic> json) =>
      AuthoringFinding(
        code: json['code'] as String? ?? 'unknown',
        message: json['message'] as String? ?? '',
        field: json['field'] as String?,
      );
}

/// The outcome of a source-authoring `PUT`. [ok] is true on a `200` (the save
/// landed and the brain will pull it on its next run, AUTH-5); on a `422` it is
/// false and [findings] carries why the brain's validator refused it — the
/// on-disk file is left untouched server-side, so the editor keeps the buffer.
class AuthoringResult {
  final bool ok;
  final List<AuthoringFinding> findings;

  const AuthoringResult({required this.ok, this.findings = const []});

  /// A clean success with no findings — the `200` path.
  static const AuthoringResult saved = AuthoringResult(ok: true);

  factory AuthoringResult.rejected(List<AuthoringFinding> findings) =>
      AuthoringResult(ok: false, findings: findings);
}
