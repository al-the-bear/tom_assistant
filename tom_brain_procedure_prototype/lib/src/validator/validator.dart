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
//   - C.29 — contract validator.
//   - C.30 — per-branch malformed-input tests.

export 'header_validator.dart';
export 'procedure_sandbox_violation.dart';
export 'sandbox_validator.dart';
