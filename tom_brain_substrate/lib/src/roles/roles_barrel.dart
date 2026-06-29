// Barrel for the `roles/` module — the *role-layer* surface of the
// substrate (B.21 / B.22 / B.23 / substrate_specification.md § 6).
//
// Module surface at B.23:
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
//                              value class the registry holds (B.22).
//                              `assemble({inputs})` (B.23) wraps the
//                              composed body via
//                              `AssistantDedicationAnchor.wrap(...)`
//                              and stamps `AnchorRegistry.currentHash`
//                              on the resulting `WirePrompt`.
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
//                              constructs the six core roles in
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
// What this barrel does NOT export at B.23:
//
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
// `loadFileBackedRoleRegistry({base, rolesDir})` (Plan-2 item 11 →
// increment 8): the on-disk counterpart to the in-code role factories.
// Overlays each role's prose — `personaText` from `<rolesDir>/<role>.
// persona.md` and `objective` from `<rolesDir>/<role>.objective.md` — onto
// an arbitrary base roster, falling back to the in-code template for any
// role (or half) whose file is absent or blank. Only the prose is sourced
// from disk; the capability surface (allowed/forbidden actions, output
// schema, budgets) stays the in-code authority. The anchor stays injected
// unconditionally on every assembled prompt regardless of source.
export 'file_backed_role_loader.dart';
// The refreshable holder around the prose-overlaid registry: lets an operator
// edit `<role>.persona.md` / `<role>.objective.md` and have the next LLM call
// pick the edit up without a restart (`prompt_tracing.md` § 6.3, AUTH-5). A
// `fixed` holder wraps an immutable registry and never reloads; a `reloading`
// holder rebuilds the overlay only when the prose files' cheap signature
// changes. The roster and capability surface stay invariant across reloads.
export 'reloading_role_registry.dart';
// Plan Extension-H step #29 — the six retrieval roles (substrate § 6.2a).
// A separate, optional roster (template + cheap-route config + a
// deterministic, never-throwing output parser per role). The bootstrap
// roster is untouched: `bootstrapRoleRegistry()` still returns exactly the
// six core roles; `bootstrapRoleRegistryWithRetrieval()` composes
// the twelve-role thinking + retrieval roster. Adding the roles is
// config-only — no router / registry / template engine change.
export 'retrieval/retrieval_barrel.dart';
// Todo 7 (G-PR2/G-PR3) — the three procedure-subsystem roles
// (`procedure_specification.md` § 8.2 / § 10.3): `procedure_author`,
// `procedure_critic`, `procedure_selector`. A separate, optional roster (like
// the Extension-H retrieval roster): `bootstrapRoleRegistry()` still returns
// exactly the six core roles; `bootstrapRoleRegistryWithProcedure()` composes
// the nine-role thinking + procedure roster.
export 'procedure/procedure_barrel.dart';
// Todo 9 (G-C4) — the three creation-subsystem roles
// (`creation_specification.md` § 6): `creator`, `tester`, `reviewer`. A
// separate, optional roster (like the retrieval and procedure rosters):
// `bootstrapRoleRegistry()` still returns exactly the six core roles;
// `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()` composes the full
// eighteen-role live roster (core + retrieval + procedure + creation).
export 'creation/creation_barrel.dart';
// Todo 8 (G-P3) — the five planning-subsystem roles
// (`planning_specification.md` § 8): `planner`, `decomposer`, `estimator`,
// `plan_evaluator`, `re_planner`. A separate, optional roster (like the
// retrieval / procedure / creation rosters): `bootstrapRoleRegistry()` still
// returns exactly the six core roles;
// `bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning()` composes
// the full twenty-three-role live roster (core + retrieval + procedure +
// creation + planning).
export 'planning/planning_barrel.dart';
// The seven dreaming-agent roles (`memory_specification.md` § 9): `extractor`,
// `connector`, `synthesiser`, `inquisitor`, `pruner`, `reconsolidator`,
// `repetition_detector`. A separate, optional roster (like the retrieval /
// procedure / creation / planning rosters): `bootstrapRoleRegistry()` still
// returns exactly the six core roles;
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()`
// composes the full thirty-role live roster (core + retrieval + procedure +
// creation + planning + dream).
export 'dream/dream_barrel.dart';
// Completion-plan item 4 (HC-81) — the single conversation-history role
// (`history_compactor`). A separate, optional roster (like the retrieval /
// procedure / creation / planning / dream rosters): `bootstrapRoleRegistry()`
// still returns exactly the six core roles;
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory()`
// composes the full thirty-two-role live roster (core + retrieval + procedure +
// creation + planning + dream + history). It is the dedicated home the
// engine-side `HistoryCompactor` routes under, replacing the `recaller` stopgap.
export 'history/history_barrel.dart';
export 'role_budget_defaults.dart';
export 'role_registry.dart';
export 'role_template.dart';
// Prompt-restructuring plan step 6 (Phase 3) — the shared, placeholder-bearing
// role-preamble system scaffold (`prompt_configuration.md` § 13.1).
// `RoleTemplate._composeSystem` renders it; exported so the observatory /
// tests can read `SystemScaffold.template` directly.
export 'system_scaffold.dart';
