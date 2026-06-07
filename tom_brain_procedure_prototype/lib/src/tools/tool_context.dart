// ToolContext — the *only* effect surface a `BrainTool` may touch (PE-1;
// `tom_brain_procedure_prototype_specification.md` § 21.2, § 21.4).
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
// or network handle: the file scope is a plain `String` path, the web/engine
// surfaces expose only their declared methods, and the todo store is in-memory
// scratch. Holding the context still grants a tool no open capability (PE-1) —
// it re-derives a constrained one (a path-checked file handle, a budget-gated
// memory write) when it runs.
//
// `web` / `engine` / `vscode` are nullable because the surfaces they wrap
// genuinely do not exist on every run (the `vscode` surface only when the
// prototype is colocated with a VS Code extension and the merge profile is on,
// § 21.8); a tool handed a context without the surface it needs raises
// `ToolSurfaceUnavailable` rather than silently degrading. `budget`,
// `memory`, and `fileScopeRoot` stay required.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TomBrainMemoryClient;

import '../budget/budget_ledger.dart' show BudgetLedger;
import 'todo_store.dart';
import 'tool_engine_surface.dart';
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

  /// The file-scope root as a path string. Not a `dart:io` handle: the file
  /// tools resolve and path-escape-check against it; the context itself
  /// exposes no open filesystem capability.
  final String fileScopeRoot;

  /// The in-process, run-scoped todo list the `todo.*` tools manage. Ephemeral
  /// and never persisted to memory; defaults to a fresh store per context.
  final TodoStore todos;

  /// The optional web surface the `web.*` tools route through, or `null` on a
  /// run that exposes no web tools.
  final ToolWebSurface? web;

  /// The optional engine surface the `procedure.*` / `script.run_d4rt` tools
  /// route through, or `null` on a run that exposes none.
  final ToolEngineSurface? engine;

  /// The optional VS Code extension surface the merged `vscode.*` tools
  /// (§ 21.8) route through, or `null` on a run not colocated with a VS Code
  /// extension (or with the merge profile off).
  final VsCodeToolSource? vscode;

  /// Builds the surface. [budget], [memory], and [fileScopeRoot] are required;
  /// [todos] defaults to a fresh run-scoped store; [web], [engine], and
  /// [vscode] are supplied only when the run exposes tools that need them.
  ToolContext({
    required this.budget,
    required this.memory,
    required this.fileScopeRoot,
    TodoStore? todos,
    this.web,
    this.engine,
    this.vscode,
  }) : todos = todos ?? TodoStore();
}
