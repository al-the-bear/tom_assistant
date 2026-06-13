// Depth-first traversal helpers over a parsed [ProcedureRun] tree
// (`prompt_tracing.md` § 3.6 / § 4.1). One traversal definition, reused by the
// configuration builder (which needs every `llm` call) and the prompt-list
// builder (which needs the per-turn LLM-call + memory-access counts) — so the
// "what counts as a memory access" rule lives in exactly one place.

import '../model/run_tree.dart';

/// Every node in the run, in DFS order, descending into each [SubRunNode]'s own
/// tree so counts and lookups span the whole turn — not just the top run.
Iterable<RunNode> allNodes(ProcedureRun run) sync* {
  for (final node in run.nodes) {
    yield node;
    if (node is SubRunNode) yield* allNodes(node.run);
  }
}

/// Every substrate call in the run, across all depths.
Iterable<LlmCallNode> allLlmCalls(ProcedureRun run) =>
    allNodes(run).whereType<LlmCallNode>();

/// The count of substrate calls across the whole turn's run-tree (§ 4.1).
int llmCallCount(ProcedureRun run) => allLlmCalls(run).length;

/// The count of memory/primitive accesses (every non-`llm` primitive call)
/// across the whole turn's run-tree (§ 4.1). `llm` and `tool` are their own node
/// kinds ([LlmCallNode] / [ToolCallNode]), so both are already excluded — a
/// `tool.invoke` is an effect, not a memory access.
int memoryAccessCount(ProcedureRun run) =>
    allNodes(run).whereType<PrimitiveCallNode>().length;

/// Every `tool.invoke` call in the run, across all depths (§5.7.1).
Iterable<ToolCallNode> allToolCalls(ProcedureRun run) =>
    allNodes(run).whereType<ToolCallNode>();

/// The count of `tool.invoke` calls across the whole turn's run-tree. A tool
/// call is a distinct node kind, so it never inflates [memoryAccessCount] or
/// [llmCallCount].
int toolCallCount(ProcedureRun run) => allToolCalls(run).length;
