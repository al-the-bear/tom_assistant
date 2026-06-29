// Barrel for the conversation-history-role surface
// (`tom_brain_procedure_specification.md` § 22.4).
//
// The single `history_compactor` role is config, not engine: one template
// (`history_roles.dart`), composed onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory()`.
// This barrel is re-exported from `roles_barrel.dart` so the run assembly and
// the engine-side `HistoryCompactor` bind against the same surface under the
// `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `historyRoleIds` / `historyRoleTemplates()` /
//     `bootstrapHistoryRoleRegistry()` — the roster + registry factory.
//   * `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory()`
//     — the full thirty-two-role live roster (core + retrieval + procedure +
//     creation + planning + dream + history). `bootstrapRoleRegistry()` is
//     unchanged (6 roles).

export 'history_roles.dart';
