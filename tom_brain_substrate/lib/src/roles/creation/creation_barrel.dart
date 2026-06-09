// Todo 9 (G-C4) — barrel for the creation-role surface
// (`creation_specification.md` § 6).
//
// The three creation-subsystem roles are config, not engine: a template per
// role (`creation_roles.dart`), composed onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()`. This barrel is
// re-exported from `roles_barrel.dart` so a creation-enabled facade and the
// `create_v1` procedure bind against the same surface under the
// `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `creationRoleIds` / `creationRoleTemplates()` /
//     `bootstrapCreationRoleRegistry()` — the roster + registry factory.
//   * `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()` — the full
//     eighteen-role live roster (core + retrieval + procedure + creation).
//     `bootstrapRoleRegistry()` is unchanged (still 6 roles).

export 'creation_roles.dart';
