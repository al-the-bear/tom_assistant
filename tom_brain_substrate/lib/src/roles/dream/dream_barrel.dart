// Barrel for the dreaming-role surface (`memory_specification.md` § 9).
//
// The seven dreaming-agent roles are config, not engine: a template per role
// (`dream_roles.dart`), composed onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()`. This
// barrel is re-exported from `roles_barrel.dart` so a dreaming-enabled facade
// and the `dream_*_v1` procedures bind against the same surface under the
// `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `dreamRoleIds` / `dreamRoleTemplates()` / `bootstrapDreamRoleRegistry()`
//     — the roster + registry factory.
//   * `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()` —
//     the full thirty-role live roster (core + retrieval + procedure +
//     creation + planning + dream). `bootstrapRoleRegistry()` is unchanged
//     (6 roles).

export 'dream_roles.dart';
