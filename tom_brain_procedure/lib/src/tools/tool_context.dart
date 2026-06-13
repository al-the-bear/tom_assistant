// ToolContext — the *only* effect surface a `BrainTool` may touch (PE-1;
// `tom_brain_procedure_specification.md` § 21.2, § 21.4).
//
// A tool is sandboxed to exactly the same surface a procedure is: it reaches
// nothing but the bridges its context hands it. The step-4 core carried three
// fields (budget, memory, fileScopeRoot) because that was all the tool-calling
// machinery needed before any tool existed. Step 7 ships the basic tool set
// (§ 21.4), and its tools route through three more run-scoped surfaces:
//
//   - [todos]  — the in-process `TodoStore` the `todo.*` tools manage
//                (ephemeral, run-scoped; defaults to a fresh store).
//   - [web]    — the optional [ToolWebSurface] the `web.*` tools route through
//                (a memory-only run carries none).
//   - [engine] — the optional [ToolEngineSurface] the `procedure.*` /
//                `script.run_d4rt` tools route through (likewise optional).
//
// Each new surface is a *value or method-only contract*, never a raw `dart:io`
// or network handle: the file scope is a [FileScope] value (two plain lists of
// `String` paths), the web/engine surfaces expose only their declared methods,
// and the todo store is in-memory scratch. Holding the context still grants a
// tool no open capability (PE-1) — it re-derives a constrained one (a
// path-checked file handle, a budget-gated memory write) when it runs.
//
// The file scope is a *two-tier* [FileScope], not one undifferentiated list: a
// deployment configures which directories may be *written* (and deleted in) and
// which may only be *read*. A read tool resolves against `readableRoots` (the
// union of write + read-only roots, since writeable implies readable); a
// write/delete tool resolves against `writeableRoots`. A read path is in scope
// when it resolves inside a readable root and a write path inside a writeable
// root; reads search the roots in order, writes target the primary (first)
// writeable root, and discovery tools (`grep.search` / `file.search` /
// `file.list`) span every readable root.
//
// `web` / `engine` / `process` / `vscode` are nullable because the surfaces
// they wrap genuinely do not exist on every run (the `process` surface only on
// a run that exposes the `analyze.*` / `test.*` creation tools, § 5.2 / § 5.3;
// the `vscode` surface only when the prototype is colocated with a VS Code
// extension and the merge profile is on, § 21.8); a tool handed a context
// without the surface it needs raises `ToolSurfaceUnavailable` rather than
// silently degrading. `budget`, `memory`, and `fileScope` stay required.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TomBrainMemoryClient;

import '../budget/budget_ledger.dart' show BudgetLedger;
import 'file_scope.dart';
import 'mcp_tool_source.dart';
import 'todo_store.dart';
import 'tool_dream_surface.dart';
import 'tool_engine_surface.dart';
import 'tool_process_surface.dart';
import 'tool_web_surface.dart';
import 'vscode_tool_source.dart';

/// The bridges a [BrainTool] may use, and nothing else (PE-1).
///
/// Built once per run by the engine over that run's ledger, memory client, and
/// surfaces, then threaded into every `tool.invoke` of the run. Immutable: a
/// tool may read the surface but cannot widen it.
final class ToolContext {
  /// The current run's budget ledger. A tool's effecting calls charge through
  /// this so they count against the same procedure-header caps (PE-8).
  final BudgetLedger budget;

  /// The memory client the memory-group tools route through — the consumer
  /// contract (`recall` / `persist` / `demote`), never the concrete store.
  final TomBrainMemoryClient memory;

  /// The two-tier file sandbox the `file.*` tools resolve against. Not
  /// `dart:io` handles: a read tool resolves and path-escape-checks against
  /// `fileScope.readableRoots`, a write/delete tool against
  /// `fileScope.writeableRoots`; the context itself exposes no open filesystem
  /// capability.
  ///
  /// A read path is in scope when it resolves inside at least one readable root
  /// (writeable roots are implicitly readable); a write path must resolve inside
  /// a writeable root. Reads search the roots in order; writes target the
  /// primary (first) writeable root; discovery tools (`grep.search` /
  /// `file.search` / `file.list`) span every readable root.
  final FileScope fileScope;

  /// The in-process, run-scoped todo list the `todo.*` tools manage. Ephemeral
  /// and never persisted to memory; defaults to a fresh store per context.
  final TodoStore todos;

  /// The optional web surface the `web.*` tools route through, or `null` on a
  /// run that exposes no web tools.
  final ToolWebSurface? web;

  /// The optional engine surface the `procedure.*` / `script.run_d4rt` tools
  /// route through, or `null` on a run that exposes none.
  final ToolEngineSurface? engine;

  /// The optional, allow-listed process surface the `analyze.*` / `test.*`
  /// tools route through (`creation_specification.md` § 5.2, § 5.3), or `null`
  /// on a run that exposes none. Never a raw `Process.run` handle: the surface
  /// admits only a fixed set of executables, so holding the context grants no
  /// general-shell capability (§ 5.4 / § 12.1 decision 2).
  final ToolProcessSurface? process;

  /// The optional VS Code extension surface the merged `vscode.*` tools
  /// (§ 21.8) route through, or `null` on a run not colocated with a VS Code
  /// extension (or with the merge profile off).
  final VsCodeToolSource? vscode;

  /// The optional external-MCP surface the merged `mcp__*` tools (§ 21.3) route
  /// through, or `null` on a run with no MCP servers configured. Like [vscode],
  /// it is a method-only port (never a raw socket): a merged tool handed a
  /// context without it raises `ToolSurfaceUnavailable`.
  final McpToolSource? mcp;

  /// The optional dreaming-control surface the `dream.control` tool routes
  /// through (`memory_specification.md` § 9.7), or `null` on a cognition booted
  /// without a dreaming cadence (the `dream:` block absent or disabled). Bound
  /// by the run assembly once its `DreamController` is built (post-boot); a tool
  /// handed a context without it raises `ToolSurfaceUnavailable`.
  final ToolDreamSurface? dream;

  /// Builds the surface. [budget], [memory], and [fileScope] are required;
  /// [fileScope] enforces its own non-empty invariant. [todos] defaults to a
  /// fresh run-scoped store; [web], [engine], [process], [vscode], [mcp], and
  /// [dream] are supplied only when the run exposes tools that need them.
  ToolContext({
    required this.budget,
    required this.memory,
    required this.fileScope,
    TodoStore? todos,
    this.web,
    this.engine,
    this.process,
    this.vscode,
    this.mcp,
    this.dream,
  }) : todos = todos ?? TodoStore();
}
