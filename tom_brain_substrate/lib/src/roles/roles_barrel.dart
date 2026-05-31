// Barrel for the `roles/` module — the *role-layer* surface of the
// substrate (B.21 / substrate_specification.md § 6).
//
// Module surface at B.21:
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
//
// What this barrel does NOT export at B.21:
//
//   * The role registry. Lives at B.22 (`roles_registry.dart`) and
//     will be added to this barrel in the same change.
//   * The `assemble(...)` method that produces a `WirePrompt`. Lives
//     at B.23 (`role_template_assemble.dart` or as an extension on
//     `RoleTemplate`; B.23 will pick the layout based on whether the
//     anchor-injection enforcement test needs static-method access).
//   * A `RoleId` strong type. The spec / api/ layer keep `String` as
//     the role key for the prototype (see `LlmCall.roleId` doc); a
//     dedicated id type would force a substrate-wide refactor for
//     zero structural benefit while the registry has fewer than ten
//     entries.
//
// Why this barrel is re-exported from the top-level package barrel:
//
//   * Future router code (B.40+) that wires `TomBrainSubstrateClient.
//     complete` against the registry needs `RoleTemplate` /
//     `AllowedAction` / `RoleBudgetDefaults` to bind contracts; the
//     dispatcher in Phase D consumes the same types. Both layers
//     import from the package barrel under the `lints/recommended`
//     "no `package:foo/src/...`" rule, so the roles surface must
//     surface there too.
//
//   * Tests that construct `RoleTemplate` directly (this step's
//     `b21_role_template_test.dart`, plus the B.23 anchor-enforcement
//     suite) consume the same exports.

export 'allowed_action.dart';
export 'role_budget_defaults.dart';
export 'role_template.dart';
