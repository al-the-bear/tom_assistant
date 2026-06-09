// ProcedureValidation — the result of the deterministic, LLM-free
// `validate(source)` dry-run (Todo 7 / G-PR2;
// `procedure_specification.md` § 7.205, § 8.3).
//
// The authoring loop (§ 8.3) drafts a candidate procedure with the
// `procedure_author` role, then calls `validate(draft.source)` to find out
// whether the draft is well-formed *before* it is ever parsed and run. The
// validation must never spend substrate budget and never depend on a model
// answering well-formed JSON, so it is a pure pass over the source. This file
// owns the typed result that pass produces: an `ok` flag plus the ordered
// list of findings, where each finding carries the same wire code the
// corresponding live validator would have thrown (so the re-draft prompt and
// any trail consumer route on the code, not on prose).

/// One fault found by [ProcedureValidationChain.validate].
///
/// Mirrors the typed validator exceptions (`ProcedureHeaderInvalid`,
/// `ProcedureSandboxViolation`, `ProcedureContractInvalid`,
/// `ProcedureRequiresMismatch`) but as plain data: a [code] (the wire code the
/// live validator carries), a human [message], and the offending [field] when
/// the layer attributes one (only the header layer does). Carrying the code
/// lets the authoring loop's re-draft and a Forge inspector branch on the
/// cause without string-matching the message.
final class ProcedureValidationFinding {
  /// The wire code of the layer that produced the fault (e.g.
  /// `procedure.sandbox.violation`).
  final String code;

  /// The human-readable explanation, taken verbatim from the live
  /// validator's message.
  final String message;

  /// The offending header field when the layer attributes one, else `null`.
  final String? field;

  const ProcedureValidationFinding({
    required this.code,
    required this.message,
    this.field,
  });

  /// Projects the finding into a plain map for the d4rt boundary. The
  /// `field` key is omitted when null so a script sees only the keys that
  /// carry information.
  Map<String, Object?> toMap() => <String, Object?>{
        'code': code,
        'message': message,
        if (field != null) 'field': field,
      };
}

/// The parsed-header facts a clean validation surfaces back to the authoring
/// loop.
///
/// The chain already parses the candidate's structured header (to run the
/// header-dependent checks); rather than make the authoring script re-parse the
/// YAML doc-comment in d4rt, the validation hands those facts back directly.
/// This keeps the validator the single source of truth for what the header
/// says, so `author_new_procedure_v1` can build its `Procedure` node's
/// `name` / `summary` / `requires` values without a second, divergent parser.
final class ProcedureValidationHeader {
  /// The procedure id (the header's `id` field) — used as the node `name`.
  final String id;

  /// The header's `version` field.
  final int version;

  /// The header's one-line `summary`.
  final String summary;

  /// The bridged primitives the header declares in `requires`, in order.
  final List<String> requires;

  const ProcedureValidationHeader({
    required this.id,
    required this.version,
    required this.summary,
    required this.requires,
  });

  /// Projects the header facts into a plain map for the d4rt boundary.
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'version': version,
        'summary': summary,
        'requires': List<String>.of(requires),
      };
}

/// The outcome of validating a candidate procedure source: [ok] when no layer
/// found a fault, plus the ordered [findings].
///
/// Returned by [ProcedureValidationChain.validate] and projected to a map by
/// [toMap] for the engine-native `validate` primitive. `findings` is ordered
/// by validator layer (header → sandbox → contract), so a reader sees the
/// faults in the same order the live engine gate would have hit them.
final class ProcedureValidation {
  /// Whether the source passed every validator layer.
  final bool ok;

  /// The faults found, ordered by validator layer. Empty when [ok].
  final List<ProcedureValidationFinding> findings;

  /// The parsed-header facts, present whenever the header parsed (even if a
  /// later layer faulted). `null` only when the header itself was malformed.
  final ProcedureValidationHeader? header;

  const ProcedureValidation({
    required this.ok,
    required this.findings,
    this.header,
  });

  /// A clean validation with no findings.
  static const ProcedureValidation clean =
      ProcedureValidation(ok: true, findings: <ProcedureValidationFinding>[]);

  /// Projects the validation into the plain map the d4rt boundary hands back
  /// to the authoring loop (`validation['ok']` / `validation['findings']` /
  /// `validation['header']`). The `header` key is omitted when the header could
  /// not be parsed, so a script sees it only when the facts are real.
  Map<String, Object?> toMap() => <String, Object?>{
        'ok': ok,
        'findings': <Map<String, Object?>>[
          for (final finding in findings) finding.toMap(),
        ],
        if (header != null) 'header': header!.toMap(),
      };
}
