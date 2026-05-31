// Barrel for the `roles/` module — the *role-layer* surface of the
// substrate (B.21 / B.22 / substrate_specification.md § 6).
//
// Module surface at B.22:
//
//   * `AllowedAction`        — closed enum of action tokens a role
//                              may declare in its allow / forbid sets
//                              (`tool_call`, `sub_thinking`,
//                              `user_facing_answer`, `memory_read`,
//                              `memory_write`, `llm_call`).
//   * `RoleBudgetDefaults`   — `(modelPreference, temperature,
//                              maxOutputTokens, wallClockMsDefault,
//                              tokenSpendDefault)`. The router (B.18+)
//                              merges these with per-call `LlmOptions`
//                              per the resolution order documented on
//                              `LlmOptions.model`.
//   * `RoleTemplate`         — `(id, personaText, objective,
//                              allowedActions, forbiddenActions,
//                              outputSchema?, budgetDefaults)`. The
//                              value class the registry holds (B.22)
//                              and the assemble path consumes (B.23).
//   * `RoleRegistry`         — *(B.22)* Immutable holder of
//                              `RoleTemplate` instances. Constructor
//                              rejects duplicate ids; lookup APIs are
//                              `get(id)` (throws on miss),
//                              `lookup(id)` (null on miss),
//                              `contains(id)`, `ids`, `templates`,
//                              `length`.
//   * `RoleTemplateNotFound` — *(B.22)* The typed exception
//                              `RoleRegistry.get(id)` throws on a miss.
//                              Carries the requested id and the known-
//                              ids roster. Distinct from
//                              `RoleNotFound` (router-level) — see the
//                              `role_registry.dart` header for the
//                              two-layer split rationale.
//   * `bootstrapRoleRegistry`— *(B.22)* Top-level factory that
//                              constructs the five prototype roles in
//                              code (no IO, no global state) and
//                              returns a fresh `RoleRegistry`. The
//                              file-backed loader (`_ai/prompts/<role>.
//                              system.md`) is deferred to B.36 (see
//                              the `bootstrap_roles.dart` header for
//                              the deferral rationale and the
//                              Q-B.22.1 / Q-B.22.2 entries in
//                              `prototype_implementation_questions.md`).
//   * `prototypeRoleIds`     — *(B.22)* The canonical iteration order
//                              of the five bootstrap role ids
//                              (`assistant_to_user`, `analyser`,
//                              `sub_thinker`, `recaller`, `evaluator`).
//                              Tests use this to assert the registry's
//                              stable order; the trail / observability
//                              layer relies on the same iteration order
//                              for diagnostic dumps.
//
// What this barrel does NOT export at B.22:
//
//   * The `assemble(...)` method that produces a `WirePrompt`. Lives
//     at B.23 (`role_template_assemble.dart` or as an extension on
//     `RoleTemplate`; B.23 will pick the layout based on whether the
//     anchor-injection enforcement test needs static-method access).
//   * A `RoleId` strong type. The spec / api/ layer keep `String` as
//     the role key for the prototype (see `LlmCall.roleId` doc); a
//     dedicated id type would force a substrate-wide refactor for
//     zero structural benefit while the registry has fewer than ten
//     entries.
//   * A file-backed `RoleRegistry.openFromDisk(Directory)` factory.
//     Deferred to B.36 (SubstrateConfig YAML loader). See the
//     `bootstrap_roles.dart` header for the rationale.
//   * The `templateRef` / git-sha field on `RoleTemplate`. Meaningful
//     only when templates are loaded from versioned files; deferred
//     with the file-backed loader. See Q-B.22.3 for the audit trail.
//
// Why this barrel is re-exported from the top-level package barrel:
//
//   * Future router code (B.40+) that wires `TomBrainSubstrateClient.
//     complete` against the registry needs `RoleTemplate` /
//     `AllowedAction` / `RoleBudgetDefaults` / `RoleRegistry` to bind
//     contracts; the dispatcher in Phase D consumes the same types.
//     Both layers import from the package barrel under the
//     `lints/recommended` "no `package:foo/src/...`" rule, so the
//     roles surface must surface there too.
//
//   * Tests that construct `RoleTemplate` directly (B.21's
//     `b21_role_template_test.dart`, B.22's `b22_role_registry_test.
//     dart`, plus the B.23 anchor-enforcement suite) consume the same
//     exports.

export 'allowed_action.dart';
export 'bootstrap_roles.dart';
export 'role_budget_defaults.dart';
export 'role_registry.dart';
export 'role_template.dart';
