// Todo 7 (G-PR2/G-PR3) — barrel for the procedure-role surface
// (`procedure_specification.md` § 8.2 / § 10.3).
//
// The three procedure-subsystem roles are config, not engine: a template per
// role (`procedure_roles.dart`), composed onto the bootstrap roster by
// `bootstrapRoleRegistryWithProcedure()`. This barrel is re-exported from
// `roles_barrel.dart` so a procedure-enabled facade and the procedure-layer
// `author_new_procedure_v1` procedure bind against the same surface under the
// `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `procedureRoleIds` / `procedureRoleTemplates()` /
//     `bootstrapProcedureRoleRegistry()` /
//     `bootstrapRoleRegistryWithProcedure()` — the roster + registry
//     factories. `bootstrapRoleRegistry()` is unchanged (still 6 roles).

export 'procedure_roles.dart';
