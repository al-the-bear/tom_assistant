// Plan Extension-H step #29 — barrel for the retrieval-role surface
// (substrate § 6.2a).
//
// The six Extension-H retrieval roles are config, not engine: a template
// per role (`retrieval_roles.dart`), a default cheap `roleRoutes` map
// (`retrieval_role_routes.dart`), and a deterministic, never-throwing
// output parser per role (`retrieval_role_output.dart`). This barrel is
// re-exported from `roles_barrel.dart` so a retrieval-enabled facade and
// the procedure-layer `recall_*` procedures bind against the same surface
// under the `lints/recommended` "no `package:foo/src/...`" rule.
//
// Surface:
//
//   * `retrievalRoleIds` / `retrievalRoleTemplates()` /
//     `bootstrapRetrievalRoleRegistry()` /
//     `bootstrapRoleRegistryWithRetrieval()` — the roster + registry
//     factories. `bootstrapRoleRegistry()` is unchanged (still 6 roles).
//   * `defaultRetrievalRoleRoutes({providerId, model})` — the default
//     cheap-route config; merge into a `RouterPolicy.roleRoutes`.
//   * `parseRetrievalRoleOutput(roleId, json)` + the sealed
//     `RetrievalRoleParse` / `RetrievalRoleOutput` families +
//     `retrievalRoleOutputMalformed` — deterministic output parsing that
//     degrades gracefully (hub § 23.9), never crashes.

export 'retrieval_role_output.dart';
export 'retrieval_role_routes.dart';
export 'retrieval_roles.dart';
