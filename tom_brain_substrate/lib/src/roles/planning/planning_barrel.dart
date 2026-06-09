// Todo 8 (G-P3) — barrel for the planning-role surface
// (`planning_specification.md` § 8).
//
// The five planning-subsystem roles are config, not engine: a template per
// role (`planning_roles.dart`), composed onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning()`. This
// barrel is re-exported from `roles_barrel.dart` so a planning-enabled facade
// and the `plan_v1` procedure bind against the same surface under the
// `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `planningRoleIds` / `planningRoleTemplates()` /
//     `bootstrapPlanningRoleRegistry()` — the roster + registry factory.
//   * `bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning()` — the
//     full twenty-three-role live roster (core + retrieval + procedure +
//     creation + planning). `bootstrapRoleRegistry()` is unchanged (6 roles).

export 'planning_roles.dart';
