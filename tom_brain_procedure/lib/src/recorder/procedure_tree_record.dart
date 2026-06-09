// ProcedureTreeRecord — the engine-layer combined run tree for one top-level
// procedure run, including its subprocedures (`tom_brain_logging.md` §5.7 /
// §9 / §10 step #9).
//
// The §5.7 per-procedure combined log (`procedures/<proc>/<turn>__<run>.log`)
// renders the *structure* of one run — every primitive call, sub-procedure
// entry/exit, LLM call, note, error, and the final outcome — as indented
// box-drawing lines that **link to the raw files but do not inline the
// prompts/answers**. It is the ideal lens for dreaming / sleep runs (which are
// procedures with no inbound prompt), so a whole cycle is one navigable tree.
//
// That tree is rooted at a top-level run but spans its nested runs, and the
// engine is the only layer that sees the whole shape: each nested run is a
// *separate* `RunRecorder` that completes before its parent's `runProcedure`
// returns, so no single recorder holds the combined structure. The engine
// therefore assembles this immutable record — the parent's own trail entries
// (as [ProcedureTreeNode]s) with each subprocedure's [ProcedureTreeRecord]
// spliced in at the call position — and hands it to the host's
// [ProcedureTreeSink]. Only the top-level (or a turn-less dream) run fires the
// sink; a nested run bubbles its sub-record up to its parent instead.
//
// Deliberately **link-only** (§5.7 / §11 resolved-decision #2): an LLM node
// carries just the facts a consumer needs to *find* the raw dump
// ([ProcedureTreeLlmRef]) — never the wire body or the answer, which stay in
// the `llm/<role>/…raw.json` file the writer links to. The tree is pure data:
// it computes no paths and touches no disk; the `tom_brain_run`
// `ProcedureTreeWriter` owns the rendering and the link construction.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TrailOutcomeStatus;

/// One node in a [ProcedureTreeRecord] — a single structural step of a run, in
/// trail order. A sealed hierarchy so the writer must render every kind.
sealed class ProcedureTreeNode {
  const ProcedureTreeNode();
}

/// A bridged-primitive call node (`recall`, `persist`, `edge`, `stackPush`,
/// `llm`, …) — the engine's `primitiveCall` trail entry.
///
/// [primitive] is the call name; [input] / [result] are the call's
/// JSON-encodable argument and return maps (the same maps the run trail
/// recorded). [llm] is non-`null` only for an `llm` primitive: it carries the
/// run-correlation a consumer needs to locate the call's raw dump (the body
/// itself is never inlined — §5.7).
final class ProcedurePrimitiveNode extends ProcedureTreeNode {
  /// The call name (`recall`, `persist`, `edge`, `stackPush`, `llm`, …).
  final String primitive;

  /// The call's JSON-encodable argument map.
  final Map<String, Object?> input;

  /// The call's JSON-encodable result map.
  final Map<String, Object?> result;

  /// The raw-dump reference for an `llm` primitive; `null` for every other
  /// primitive (which carries no raw LLM file to link).
  final ProcedureTreeLlmRef? llm;

  const ProcedurePrimitiveNode({
    required this.primitive,
    required this.input,
    required this.result,
    this.llm,
  });
}

/// A note node — the engine's `note` trail entry (`step_truncated`,
/// `run_cancelled`, an `automation_candidate` signal, …).
final class ProcedureNoteNode extends ProcedureTreeNode {
  /// The note category (`step_truncated`, `run_cancelled`, …).
  final String category;

  const ProcedureNoteNode({required this.category});
}

/// An error node — the engine's `error` trail entry (a captured exception or a
/// dropped-write surface).
final class ProcedureErrorNode extends ProcedureTreeNode {
  /// The typed error class (`procedure.runtime.crash`, …).
  final String errorKind;

  /// The error message.
  final String message;

  const ProcedureErrorNode({required this.errorKind, required this.message});
}

/// A sub-procedure node — one nested `runProcedure` call, spliced in at the
/// position it was issued. [tree] is the nested run's own combined tree, so the
/// whole structure recurses to arbitrary depth.
final class ProcedureSubtreeNode extends ProcedureTreeNode {
  /// The nested run's combined tree.
  final ProcedureTreeRecord tree;

  const ProcedureSubtreeNode({required this.tree});
}

/// The run-correlation a consumer needs to locate one `llm` call's raw dump
/// (`tom_brain_logging.md` §5.2 / §5.7). The writer turns these facts into the
/// relative `llm/<callType>/<stem>.raw.json` link — never the body itself.
final class ProcedureTreeLlmRef {
  /// The role the call was assembled for (`recaller`, `assistant_to_user`, …)
  /// — the `llm/<callType>/…` path segment.
  final String callType;

  /// The turn id this call belonged to, or `null` for a turn-less / dream
  /// call (then the stem falls back to `<runId>__<callId>`).
  final String? turnId;

  /// The call's ordinal within its turn, or `null` when [turnId] is `null`.
  final int? callSeq;

  /// The substrate-assigned call id — the path-stem fallback for a turn-less
  /// call.
  final String callId;

  /// The run that issued the call (the raw-stem fallback owner).
  final String runId;

  /// Prompt tokens the call consumed.
  final int tokensIn;

  /// Completion tokens the call produced.
  final int tokensOut;

  const ProcedureTreeLlmRef({
    required this.callType,
    required this.turnId,
    required this.callSeq,
    required this.callId,
    required this.runId,
    required this.tokensIn,
    required this.tokensOut,
  });
}

/// The combined structural tree of one procedure run, including its
/// subprocedures (`tom_brain_logging.md` §5.7). Pure data — the
/// `ProcedureTreeWriter` renders it to `procedures/<procedureId>/…log`.
final class ProcedureTreeRecord {
  /// The run's procedure id.
  final String procedureId;

  /// The run's procedure version.
  final int version;

  /// The run id.
  final String runId;

  /// The parent run id when this is a nested run; `null` for a top-level (or
  /// turn-less dream) run.
  final String? parentRunId;

  /// The turn this run served (`TurnId.value`), or `null` for a turn-less
  /// (internal / free-time / dream) run. The file is keyed
  /// `<turnId>__<runId>.log` when present, bare `<runId>.log` otherwise.
  final String? turnId;

  /// The run's depth in the `runProcedure` chain (top-level is `1`).
  final int depth;

  /// The run's terminal outcome status.
  final TrailOutcomeStatus status;

  /// The run's wall-clock elapsed, in milliseconds (the outcome figure).
  final int elapsedMs;

  /// The total number of trail entries the run recorded (including the
  /// `outcome`) — the `entries=<n>` figure on the outcome line.
  final int entryCount;

  /// The run's structural nodes, in trail order, with each subprocedure
  /// spliced in at its call position. Does **not** include the synthetic
  /// outcome line (the writer renders that from [status] / [entryCount] /
  /// [elapsedMs]).
  final List<ProcedureTreeNode> nodes;

  ProcedureTreeRecord({
    required this.procedureId,
    required this.version,
    required this.runId,
    required this.parentRunId,
    required this.turnId,
    required this.depth,
    required this.status,
    required this.elapsedMs,
    required this.entryCount,
    required List<ProcedureTreeNode> nodes,
  }) : nodes = List<ProcedureTreeNode>.unmodifiable(nodes);
}

/// The engine-level sink one combined [ProcedureTreeRecord] is handed to per
/// top-level (or turn-less dream) run (`tom_brain_logging.md` §10 step #9).
/// Bound by the host to a `ProcedureTreeWriter.write`; `null` leaves the engine
/// emitting no per-procedure tree. Best-effort and non-blocking (logging-spec
/// §9) — a throwing sink must not break the run.
typedef ProcedureTreeSink = void Function(ProcedureTreeRecord record);
