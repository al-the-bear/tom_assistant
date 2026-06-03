// Barrel for the `validator/` module (Plan step C.8).
//
// Owns the three-layer procedure validation chain
// (`tom_brain_procedure_prototype_specification.md` § 7, Plan steps
// C.27–C.30):
//
//   - Header validator — required fields, version monotonicity,
//     success-criterion presence.
//   - Sandbox validator — rejects scripts that import disallowed
//     packages or call disallowed top-level identifiers (the
//     static-analysis half of the PE-1 surface lock).
//   - Contract validator — declared inputs/outputs match the
//     procedure's signature.
//
// Wiring across later Phase C steps:
//
//   - C.27 ✅ — header validator (`HeaderValidator`): required fields +
//     success-criterion presence on a single header, version monotonicity
//     across an id's version set. Failures carry `procedure.header.invalid`.
//   - C.28 ✅ — sandbox validator (`SandboxValidator`): rejects `import`/
//     `export` directives and references to disallowed top-level
//     identifiers (SDK gateways) via a comment-and-string-aware code
//     projection. Failures carry `procedure.sandbox.violation`.
//   - C.29 ✅ — contract validator (`ContractValidator`): checks the
//     `Future<ProcedureResult> run(ProcedureInputs inputs) async { … }`
//     entry-point signature (`procedure.contract.invalid`) and that the
//     declared `requires` set exactly matches the bridged primitives the
//     body calls (`procedure.requires.mismatch`). The comment-and-string-
//     aware projection C.28 introduced is now the shared `CodeProjection`.
//   - C.30 ✅ — per-branch malformed-input tests + cross-layer gate
//     (`test/c30_validator_branch_coverage_test.dart`): one malformed case per
//     documented rejection branch of all three layers, plus the three-layer
//     gate driven in the engine's order (header → sandbox → contract).

export 'bridged_primitive_catalog.dart' show BridgedPrimitiveCatalog;
export 'code_projection.dart' show CodeProjection;
export 'contract_validator.dart' show ContractValidator;
export 'header_validator.dart' show HeaderValidator;
export 'procedure_contract_invalid.dart'
    show ContractViolationKind, ProcedureContractInvalid, procedureContractInvalidCode;
export 'procedure_requires_mismatch.dart'
    show
        ProcedureRequiresMismatch,
        RequiresMismatchKind,
        procedureRequiresMismatchCode;
export 'procedure_sandbox_violation.dart'
    show
        ProcedureSandboxViolation,
        SandboxViolationKind,
        procedureSandboxViolationCode;
export 'sandbox_validator.dart' show SandboxValidator;
