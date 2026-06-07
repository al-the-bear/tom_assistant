// ToolContext — the *only* effect surface a `BrainTool` may touch (PE-1;
// `tom_brain_procedure_prototype_specification.md` § 21.2).
//
// A tool is sandboxed to exactly the same surface a procedure is: it reaches
// nothing but the bridges its context hands it. The context carries three —
// the current run's [BudgetLedger] (so a tool's side effects charge against
// the same per-run caps as the procedure's, PE-8), the [TomBrainMemoryClient]
// (the consumer contract the memory tools route through, never the concrete
// store), and the [fileScopeRoot].
//
// The file scope is a plain `String` path, deliberately — not a `dart:io`
// `Directory`/`File`. A value, not an open capability: holding the context
// gives a tool no raw filesystem or network handle (the Verify clause of
// plan step 4). The file tools (step 7) resolve and path-escape-check against
// this root when they run; until then the root is data the context carries,
// nothing a tool can dereference on its own.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TomBrainMemoryClient;

import '../budget/budget_ledger.dart' show BudgetLedger;

/// The bridges a [BrainTool] may use, and nothing else (PE-1).
///
/// Built once per run by the engine over that run's ledger and memory client,
/// then threaded into every `tool.invoke` of the run. Immutable: a tool may
/// read the surface but cannot widen it.
final class ToolContext {
  /// The current run's budget ledger. A tool's effecting calls charge through
  /// this so they count against the same procedure-header caps (PE-8).
  final BudgetLedger budget;

  /// The memory client the memory-group tools route through — the consumer
  /// contract (`recall` / `persist` / `demote`), never the concrete store.
  final TomBrainMemoryClient memory;

  /// The file-scope root as a path string. Not a `dart:io` handle: the file
  /// tools (step 7) resolve against it; the context itself exposes no open
  /// filesystem capability.
  final String fileScopeRoot;

  /// Builds the surface. All three bridges are required — there is no partial
  /// context.
  const ToolContext({
    required this.budget,
    required this.memory,
    required this.fileScopeRoot,
  });
}
