// ProcedureValidationChain — the deterministic, LLM-free dry-run that backs
// the engine-native `validate(source)` primitive (Todo 7 / G-PR2;
// `procedure_specification.md` § 7.205, § 8.3, § 9.4).
//
// The three validator layers (`HeaderValidator`, `SandboxValidator`,
// `ContractValidator`) each throw on the *first* fault they find — the
// fail-fast contract the engine's runnable-gate wants. The authoring loop
// (§ 8.3) wants the opposite: it drafts a candidate, calls `validate`, and
// re-drafts once against *every* finding it can fix in one pass. This chain is
// that collecting pass — it runs each layer over the candidate source, catches
// the layer's typed exception, records a finding, and continues to the next
// layer wherever the next layer's inputs are still available.
//
// It executes nothing. The source is never parsed by d4rt and never run; only
// the lexical/structural validators touch it. This is the § 9.4 authoring
// sandbox rule: a candidate is held and validated before it can be parsed for
// execution, and the authoring branch never `run()`s an unvalidated body.

import '../procedure_store/procedure_header.dart';
import '../procedure_store/procedure_header_invalid.dart';
import '../procedure_store/procedure_loader.dart';
import 'contract_validator.dart';
import 'header_validator.dart';
import 'procedure_contract_invalid.dart';
import 'procedure_requires_mismatch.dart';
import 'procedure_sandbox_violation.dart';
import 'procedure_validation.dart';
import 'sandbox_validator.dart';

/// Runs the three-layer validator chain over a candidate procedure source and
/// collects every fault into a [ProcedureValidation].
///
/// Stateless — composes the const shared validators. Construct once and reuse,
/// or use the [shared] instance.
final class ProcedureValidationChain {
  /// Builds a chain over the given validator layers, defaulting to the const
  /// shared singletons.
  const ProcedureValidationChain({
    this.loader = ProcedureLoader.shared,
    this.headerValidator = HeaderValidator.shared,
    this.sandboxValidator = SandboxValidator.shared,
    this.contractValidator = ContractValidator.shared,
  });

  /// A shared, reusable chain over the default validator layers.
  static const ProcedureValidationChain shared = ProcedureValidationChain();

  /// Parses the structured header out of the candidate source.
  final ProcedureLoader loader;

  /// Validates required fields + success-criterion presence on the header.
  final HeaderValidator headerValidator;

  /// Statically rejects sources that reach outside the bridged surface.
  final SandboxValidator sandboxValidator;

  /// Validates the entry-point signature and the `requires`-vs-calls contract.
  final ContractValidator contractValidator;

  /// Validates [source] without executing it, returning the collected
  /// [ProcedureValidation].
  ///
  /// The layers run in the engine's gate order (header → sandbox → contract).
  /// Each layer's typed exception is caught and recorded as a finding; the
  /// pass then continues. The two header-dependent checks ([HeaderValidator]
  /// and the requires contract) are skipped when the header could not be
  /// parsed, because they have nothing to check against — but the
  /// source-only checks (sandbox, signature) still run, so even a
  /// header-less draft gets useful feedback.
  ProcedureValidation validate(String source) {
    final findings = <ProcedureValidationFinding>[];

    // 1. Parse the header. A structural/required-field fault here yields a
    //    finding and leaves the header unavailable for the checks that need it.
    ProcedureHeader? header;
    try {
      header = loader.parse(source);
    } on ProcedureHeaderInvalid catch (e) {
      findings.add(ProcedureValidationFinding(
        code: e.code,
        message: e.message,
        field: e.field,
      ));
    }

    // 2. Header-level checks (required fields, success-criterion, budget cap).
    if (header != null) {
      try {
        headerValidator.validateHeader(header);
      } on ProcedureHeaderInvalid catch (e) {
        findings.add(ProcedureValidationFinding(
          code: e.code,
          message: e.message,
          field: e.field,
        ));
      }
    }

    // 3. Sandbox — source-only, so it runs regardless of the header.
    try {
      sandboxValidator.validateSource(source);
    } on ProcedureSandboxViolation catch (e) {
      findings.add(ProcedureValidationFinding(code: e.code, message: e.message));
    }

    // 4. Entry-point signature — source-only.
    try {
      contractValidator.validateSignature(source);
    } on ProcedureContractInvalid catch (e) {
      findings.add(ProcedureValidationFinding(code: e.code, message: e.message));
    }

    // 5. requires-vs-actual-calls — needs the header.
    if (header != null) {
      try {
        contractValidator.validateRequires(header, source);
      } on ProcedureRequiresMismatch catch (e) {
        findings.add(
          ProcedureValidationFinding(code: e.code, message: e.message),
        );
      }
    }

    return ProcedureValidation(
      ok: findings.isEmpty,
      findings: findings,
      // Surface the parsed-header facts whenever the header parsed, so the
      // authoring loop can build its Procedure node's name/summary/requires
      // without a second parser (§ 8.3).
      header: header == null
          ? null
          : ProcedureValidationHeader(
              id: header.id,
              version: header.version,
              summary: header.summary,
              requires: header.requires,
            ),
    );
  }
}
