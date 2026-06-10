// ToolGroup — the closed family a `BrainTool` belongs to
// (`tom_brain_procedure_specification.md` § 21.2, § 21.4, § 21.8).
//
// The group is one of the two policy axes (alongside `readOnly`) the
// `ToolPolicy` profiles key on (§ 21.8): a `groups` profile allows whole
// groups, an `explicit` profile names individual tools. The members mirror the
// basic tool set (§ 21.4): `memory.*` → memory, `file.*` / `grep.*` → file,
// `todo.*` → todo, `web.*` → web, `procedure.*` → procedure, `script.run_d4rt`
// → script, `analyze.*` → analyze and `test.*` → test (the creation
// code-understanding / test-execution families, `creation_specification.md`
// § 5.2 / § 5.3), MCP-surfaced tools → mcp, and the VS Code tool registry the
// two registries unify with (§ 21.8) → vscode.

/// The closed set of tool groups (§ 21.2). Each member's `.name` is its wire
/// token (`memory`, `file`, …) — the same string the policy config and the
/// `tool.list` filter use.
enum ToolGroup {
  /// Memory reads/writes (`memory.read`, `memory.write`, `memory.delete`).
  memory,

  /// File-scope operations (`file.read`, `file.write`, `grep.search`).
  file,

  /// Ephemeral run/session-scoped todos (`todo.list`, `todo.add`, …).
  todo,

  /// Substrate web tools (`web.search`, `web.fetch`).
  web,

  /// Procedure introspection and nested runs (`procedure.list`,
  /// `procedure.run`).
  procedure,

  /// Sandboxed nested d4rt evaluation (`script.run_d4rt`).
  script,

  /// Code-understanding tools that run an allow-listed analysis process
  /// (`analyze.dart`, `analyze.format`, `analyze.schema`;
  /// `creation_specification.md` § 5.2).
  analyze,

  /// Test-execution tools that run an allow-listed test process (`test.run`,
  /// `test.baseline`; `creation_specification.md` § 5.3).
  test,

  /// Tools surfaced from a remote MCP server.
  mcp,

  /// Tools bridged from the VS Code tool registry (the two registries unify,
  /// § 21.8).
  vscode,

  /// Dreaming-cadence control (`dream.control`) — start/stop/resume the
  /// background dream loop and report its state (`memory_specification.md`
  /// § 9.7).
  dream,
}
