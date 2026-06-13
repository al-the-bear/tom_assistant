// The run-tree projection of a traced prompt (`prompt_tracing.md` § 3.2 / § 3.6).
//
// A [ProcedureRun] is the parser's reconstruction of the §5.7 combined run tree
// the brain writes to `procedures/<proc>/<turnId>__<runId>.log` (the rendered
// `ProcedureTreeRecord` — see `procedure_tree_writer.dart`). The recursion lives
// in the data: a run's nodes include [SubRunNode]s, each carrying its own
// [ProcedureRun], to whatever depth the run reached.
//
// Fidelity note (load-bearing — the spec must not drift from the writers).
// The parser reads the **rendered** `.log`, not the in-memory `ProcedureTreeRecord`.
// The renderer is deliberately lossy: a subtree shows its nodes and a status on
// its header, but no `outcome` line — and the renderer never writes a procedure
// `version`, a run `depth`, or a sub-run's `elapsedMs` / `entryCount` at all.
// So those fields are nullable here and are populated only where the file
// carries them: `status` / `elapsedMs` / `entryCount` for the top-level run
// (from its `outcome` line) and `status` for a sub-run (from its `subprocedure …
// (status)` header). Everything else the file omits stays `null`. This matches
// the §3.6 shape projected onto the bytes the §5.7 file actually carries.

/// One reconstructed procedure run — a node of the PromptTrace run-tree
/// (`prompt_tracing.md` § 3.6). The top-level run is the tree root; nested runs
/// hang off [SubRunNode]s in [nodes].
final class ProcedureRun {
  /// The procedure script this run executed (`answer_with_memory_v1`, …).
  final String procedureId;

  /// The run-correlation id (`run-…`).
  final String runId;

  /// The turn this run served, present only on a top-level run (the file
  /// header carries it); `null` on a sub-run and on a turn-less dream run.
  final String? turnId;

  /// The terminal outcome status name (`accepted`, `errored`, `rejected`, …).
  /// Read from the top-level `outcome` line or a sub-run's header. Never `null`
  /// for a well-formed run.
  final String status;

  /// Wall-clock elapsed in milliseconds — top-level only (from the `outcome`
  /// line). `null` for a sub-run (the rendered subtree omits it).
  final int? elapsedMs;

  /// Trail-entry count — top-level only (from the `outcome` line). `null` for a
  /// sub-run.
  final int? entryCount;

  /// The structural steps of the run, in trail order, with each sub-run spliced
  /// in at its call position.
  final List<RunNode> nodes;

  ProcedureRun({
    required this.procedureId,
    required this.runId,
    required this.status,
    this.turnId,
    this.elapsedMs,
    this.entryCount,
    List<RunNode> nodes = const <RunNode>[],
  }) : nodes = List<RunNode>.unmodifiable(nodes);

  /// The locked § 3.6 JSON projection. Optional fields are omitted when `null`
  /// so the shape mirrors what the trail file carried.
  Map<String, Object?> toJson() => <String, Object?>{
        'procedureId': procedureId,
        'runId': runId,
        if (turnId != null) 'turnId': turnId,
        'status': status,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        if (entryCount != null) 'entryCount': entryCount,
        'nodes': <Object?>[for (final node in nodes) node.toJson()],
      };
}

/// One structural step of a [ProcedureRun] — a sealed hierarchy mirroring the
/// shipped `ProcedureTreeNode` kinds so every kind is rendered (`prompt_tracing.md`
/// § 3.2). The `kind` discriminator in [toJson] is the UI's render selector.
sealed class RunNode {
  const RunNode();

  /// The locked JSON projection, tagged by `kind` (§ 3.2).
  Map<String, Object?> toJson();
}

/// A bridged-primitive call other than `llm` — `recall`, `recallMulti`,
/// `persist`, `edge`, `embed`, `stackPush`, … (`prompt_tracing.md` § 3.8 / § 4.4).
///
/// The rendered `.log` carries only what the writer chose to show: the primitive
/// name always, a `→ <id>` result id for an id-returning primitive (`persist`,
/// `edge`), a parsed [recall] descriptor (modes / k / returned) for a `recall`,
/// and a parsed [edge] descriptor (type / from / to) for an `edge`. The richer
/// `input` / `result` maps live in `memory/<profile>.log` (§ 3.8) and are wired
/// in a later phase.
final class PrimitiveCallNode extends RunNode {
  /// The primitive name (`recall`, `recallMulti`, `persist`, `edge`, `embed`, …).
  final String primitive;

  /// The `→ <id>` target the writer rendered for an id-returning primitive, or
  /// `null` when the line carried none.
  final String? resultId;

  /// The parsed `recall (<modes> k=<k> → <returned>)` descriptor, present only
  /// for a `recall` primitive.
  final RecallDescriptor? recall;

  /// The parsed `<from> -<type>-> <to>` descriptor, present only for an `edge`
  /// primitive whose endpoints the writer rendered — the §4.7 endpoint
  /// deep-link source. Absent on a bare `edge → <id>` line.
  final EdgeDescriptor? edge;

  const PrimitiveCallNode({
    required this.primitive,
    this.resultId,
    this.recall,
    this.edge,
  });

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'primitive',
        'primitive': primitive,
        if (resultId != null) 'resultId': resultId,
        if (recall != null) 'recall': recall!.toJson(),
        if (edge != null) 'edge': edge!.toJson(),
      };
}

/// The parsed parenthetical of a `recall` primitive line
/// (`recall (bm25+vector k=8 → 8: n_a, n_b)`).
final class RecallDescriptor {
  /// The recall modes the call ran (`bm25`, `vector`, `graphWalk`, `symbolic`).
  final List<String> modes;

  /// The requested `k`, verbatim as rendered (the writer prints the raw value);
  /// `null` when the line carried none.
  final String? k;

  /// The number of fused nodes the recall returned.
  final int returned;

  /// The returned node ids the writer could resolve, in fused order — the §4.7
  /// recall deep-link source. Empty when the line carried none; may be shorter
  /// than [returned] when a fused node had no attributable id.
  final List<String> returnedIds;

  RecallDescriptor({
    required List<String> modes,
    required this.returned,
    this.k,
    List<String> returnedIds = const <String>[],
  })  : modes = List<String>.unmodifiable(modes),
        returnedIds = List<String>.unmodifiable(returnedIds);

  Map<String, Object?> toJson() => <String, Object?>{
        'modes': modes,
        if (k != null) 'k': k,
        'returned': returned,
        if (returnedIds.isNotEmpty) 'returnedIds': returnedIds,
      };
}

/// The parsed body of an `edge` primitive line
/// (`edge n_alpha -supports-> n_beta → e_…`): the relation [type] and its two
/// endpoint node ids [from] / [to]. Both endpoints are §4.7 node deep-links; the
/// edge's own id (`resultId` on the [PrimitiveCallNode]) is an edge, not a node.
final class EdgeDescriptor {
  /// The closed-alphabet edge relation (`supports`, `derived_from`, `mentions`, …).
  final String type;

  /// The source endpoint node id.
  final String from;

  /// The target endpoint node id.
  final String to;

  const EdgeDescriptor({
    required this.type,
    required this.from,
    required this.to,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        'from': from,
        'to': to,
      };
}

/// One substrate call node (`prompt_tracing.md` § 3.7 / § 4.5). The rendered
/// `.log` carries the link facts (role, tokens, raw path); the full wire body +
/// answer stay in the linked `llm/<role>/…raw.json` (read in Phase 2).
final class LlmCallNode extends RunNode {
  /// The role the call was assembled for (`assistant_to_user`, `recall_planner`, …).
  final String callType;

  /// Prompt tokens the call consumed.
  final int tokensIn;

  /// Completion tokens the call produced.
  final int tokensOut;

  /// The relative link to the authoritative raw dump, exactly as the `.log`
  /// rendered it (`../../llm/<role>/<stem>.raw.json`).
  final String rawPath;

  const LlmCallNode({
    required this.callType,
    required this.tokensIn,
    required this.tokensOut,
    required this.rawPath,
  });

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'llm',
        'callType': callType,
        'tokensIn': tokensIn,
        'tokensOut': tokensOut,
        'rawPath': rawPath,
      };
}

/// One `tool.invoke` call node (`prompt_tracing.md` § 3.2; `tom_brain_logging.md`
/// §5.7.1). The rendered `.log` carries the tool **name**, a one-line truncated
/// **arg summary**, the **outcome**, and — on success only — the result **size**
/// (`resultChars`, never the payload). `tool.list` enumerations are not rendered,
/// so every tool node here is an `invoke` of one of the three [ToolCallOutcome]s.
final class ToolCallNode extends RunNode {
  /// The registered tool name (`file.read`, `memory.persistNote`, …) — one token.
  final String name;

  /// The one-line, length-capped arg summary as the writer rendered it; empty
  /// when the tool took no args.
  final String argSummary;

  /// How the call ended.
  final ToolCallOutcome outcome;

  /// The character length of the rendered result — present only on
  /// [ToolCallOutcome.invoked] (a *size*, never the payload); `null` otherwise.
  final int? resultChars;

  /// The failure / denial message — present only on [ToolCallOutcome.failed] /
  /// [ToolCallOutcome.denied]; `null` on success.
  final String? reason;

  const ToolCallNode({
    required this.name,
    required this.argSummary,
    required this.outcome,
    this.resultChars,
    this.reason,
  });

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'tool',
        'name': name,
        'argSummary': argSummary,
        'outcome': outcome.name,
        if (resultChars != null) 'resultChars': resultChars,
        if (reason != null) 'reason': reason,
      };
}

/// The terminal state of a [ToolCallNode] — the three `tool.invoke` outcomes the
/// §5.7.1 writer renders (`ok` / `failed` / `denied`).
enum ToolCallOutcome { invoked, failed, denied }

/// A note node — the engine's `note` entry (`step_truncated`, `run_cancelled`, …).
final class NoteNode extends RunNode {
  /// The note category.
  final String category;

  const NoteNode({required this.category});

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'note',
        'category': category,
      };
}

/// A typed error node — the engine's `error` entry.
final class ErrorNode extends RunNode {
  /// The typed error class (`substrateTimeout`, `procedure.runtime.crash`, …).
  final String errorKind;

  /// The error message.
  final String message;

  const ErrorNode({required this.errorKind, required this.message});

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'error',
        'errorKind': errorKind,
        'message': message,
      };
}

/// A nested run spliced at its call position — the recursion (`prompt_tracing.md`
/// § 3.6 / § 6.1).
final class SubRunNode extends RunNode {
  /// The nested run's own tree.
  final ProcedureRun run;

  const SubRunNode({required this.run});

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'kind': 'subRun',
        'run': run.toJson(),
      };
}
