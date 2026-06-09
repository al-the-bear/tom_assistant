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
// or network handle: the file scope is a plain list of `String` paths, the
// web/engine surfaces expose only their declared methods, and the todo store
// is in-memory scratch. Holding the context still grants a tool no open
// capability (PE-1) — it re-derives a constrained one (a path-checked file
// handle, a budget-gated memory write) when it runs.
//
// The file scope is a *list* of roots, not one path: a deployment configures
// which directories the file tools may reach, and may add more as needed
// (e.g. a workspace folder plus a shared docs tree). A path is in scope when
// it resolves inside the *union* of the roots; reads search the roots in
// order, writes target the primary (first) root, and discovery tools
// (`grep.search` / `file.search`) span every root.
//
// `web` / `engine` / `process` / `vscode` are nullable because the surfaces
// they wrap genuinely do not exist on every run (the `process` surface only on
// a run that exposes the `analyze.*` / `test.*` creation tools, § 5.2 / § 5.3;
// the `vscode` surface only when the prototype is colocated with a VS Code
// extension and the merge profile is on, § 21.8); a tool handed a context
// without the surface it needs raises `ToolSurfaceUnavailable` rather than
// silently degrading. `budget`, `memory`, and `fileScopeRoots` stay required.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TomBrainMemoryClient;

import '../budget/budget_ledger.dart' show BudgetLedger;
import 'todo_store.dart';
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

  /// The file-scope roots as a non-empty list of path strings. Not `dart:io`
  /// handles: the file tools resolve and path-escape-check against the *union*
  /// of these roots; the context itself exposes no open filesystem capability.
  ///
  /// A path is in scope when it resolves inside at least one root. Reads search
  /// the roots in order; writes target the primary (first) root; discovery
  /// tools (`grep.search` / `file.search`) span every root. The first root is
  /// the deployment's primary directory.
  final List<String> fileScopeRoots;

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

  /// Builds the surface. [budget], [memory], and [fileScopeRoots] are required;
  /// [fileScopeRoots] must be non-empty (its first entry is the primary root).
  /// [todos] defaults to a fresh run-scoped store; [web], [engine], [process],
  /// and [vscode] are supplied only when the run exposes tools that need them.
  ToolContext({
    required this.budget,
    required this.memory,
    required List<String> fileScopeRoots,
    TodoStore? todos,
    this.web,
    this.engine,
    this.process,
    this.vscode,
  })  : assert(fileScopeRoots.isNotEmpty,
            'fileScopeRoots must carry at least one root'),
        fileScopeRoots = List<String>.unmodifiable(fileScopeRoots),
        todos = todos ?? TodoStore();
}
