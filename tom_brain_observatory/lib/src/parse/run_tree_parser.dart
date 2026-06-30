// Parser for the §5.7 combined run-tree file
// (`procedures/<proc>/<turnId>__<runId>.log`) into a [ProcedureRun] tree
// (`prompt_tracing.md` § 3.6 / § 6.1; PT-1.1 / PT-1.2).
//
// The file's exact rendering is owned by `tom_brain_run`'s `ProcedureTreeWriter`
// (read read-only as the contract). One line per structural step, indented with
// box-drawing prefixes:
//
//   procedure answer_with_memory_v1  run run-a0  turn 260101-120000.000001
//   ├─ subprocedure retrieve_for_prompt_v1  run run-a1  (accepted)
//   │  ├─ embed
//   │  └─ llm recall_planner → 64→24 tok  → ../../llm/recall_planner/…__01.raw.json
//   ├─ persist → n_…A1
//   └─ outcome accepted (entries=6, 2.1s)
//
// Each indentation unit is exactly three chars (`│  ` or `   `); the connector
// is `├─ ` or `└─ `. A line's *depth* is the number of indent units before its
// connector — a direct child of the run is depth 1. The file is in DFS order, so
// a single pass with a depth→owner map reconstructs the tree losslessly. The
// renderer's losses (no sub-run `version` / `depth` / `elapsedMs`) are reflected
// as `null`s on [ProcedureRun] (see `run_tree.dart`).

import '../model/run_tree.dart';

/// Parses one rendered §5.7 run-tree [content] into its top-level [ProcedureRun].
/// Returns `null` when the content has no recognisable header (so a malformed or
/// empty file degrades to "no run-tree", never an exception).
ProcedureRun? parseRunTree(String content) {
  final lines = content
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;

  final header = _parseHeader(lines.first);
  if (header == null) return null;

  // Mutable builders, since a run's nodes and outcome are discovered across the
  // DFS pass before the run is sealed into an immutable [ProcedureRun].
  final root = _RunBuilder(
    procedureId: header.procedureId,
    runId: header.runId,
    turnId: header.turnId,
  );
  // depth → the builder that owns nodes appearing at that depth. A direct child
  // of the root renders at depth 1.
  final ownerAtDepth = <int, _RunBuilder>{1: root};

  for (final raw in lines.skip(1)) {
    final line = _parseLine(raw);
    if (line == null) continue; // unrecognised indentation — skip defensively.

    final owner = ownerAtDepth[line.depth];
    if (owner == null) continue; // orphaned line (no parent at this depth).

    final sub = _subprocedure(line.content);
    if (sub != null) {
      final child = _RunBuilder(
        procedureId: sub.procedureId,
        runId: sub.runId,
        status: sub.status,
      );
      owner.nodes.add(_PendingSubRun(child));
      ownerAtDepth[line.depth + 1] = child;
      continue;
    }

    final outcome = _outcome(line.content);
    if (outcome != null) {
      owner
        ..status = outcome.status
        ..entryCount = outcome.entryCount
        ..elapsedMs = outcome.elapsedMs;
      continue;
    }

    owner.nodes.add(_PendingLeaf(_leafNode(line.content)));
  }

  return root.build();
}

// ─── Line classification ─────────────────────────────────────────────

/// One indent-stripped line: its [depth] (indent units before the connector)
/// and its [content] (everything after the connector).
class _Line {
  _Line(this.depth, this.content);
  final int depth;
  final String content;
}

/// Splits a node line into (depth, content). The prefix is a run of `│  ` / `   `
/// units followed by a `├─ ` / `└─ ` connector. Returns `null` when no connector
/// is found.
_Line? _parseLine(String raw) {
  var i = 0;
  var depth = 0;
  while (i + 3 <= raw.length) {
    final unit = raw.substring(i, i + 3);
    if (unit == '│  ' || unit == '   ') {
      depth++;
      i += 3;
      continue;
    }
    if (unit == '├─ ' || unit == '└─ ') {
      return _Line(depth + 1, raw.substring(i + 3));
    }
    return null;
  }
  return null;
}

class _Header {
  _Header(this.procedureId, this.runId, this.turnId);
  final String procedureId;
  final String runId;
  final String? turnId;
}

final RegExp _headerPattern =
    RegExp(r'^procedure (\S+)  run (\S+)(?:  turn (\S+))?$');

_Header? _parseHeader(String line) {
  final match = _headerPattern.firstMatch(line.trimRight());
  if (match == null) return null;
  return _Header(match.group(1)!, match.group(2)!, match.group(3));
}

class _Subprocedure {
  _Subprocedure(this.procedureId, this.runId, this.status);
  final String procedureId;
  final String runId;
  final String status;
}

final RegExp _subprocedurePattern =
    RegExp(r'^subprocedure (\S+)  run (\S+)  \((\w+)\)$');

_Subprocedure? _subprocedure(String content) {
  final match = _subprocedurePattern.firstMatch(content);
  if (match == null) return null;
  return _Subprocedure(match.group(1)!, match.group(2)!, match.group(3)!);
}

class _Outcome {
  _Outcome(this.status, this.entryCount, this.elapsedMs);
  final String status;
  final int entryCount;
  final int elapsedMs;
}

final RegExp _outcomePattern =
    RegExp(r'^outcome (\w+) \(entries=(\d+), (.+)\)$');

_Outcome? _outcome(String content) {
  final match = _outcomePattern.firstMatch(content);
  if (match == null) return null;
  return _Outcome(
    match.group(1)!,
    int.parse(match.group(2)!),
    _parseElapsed(match.group(3)!),
  );
}

/// Reverses `ProcedureTreeWriter._elapsed`: `2.1s` → 2100, `800ms` → 800.
int _parseElapsed(String text) {
  if (text.endsWith('ms')) {
    return int.tryParse(text.substring(0, text.length - 2)) ?? 0;
  }
  if (text.endsWith('s')) {
    final seconds = double.tryParse(text.substring(0, text.length - 1)) ?? 0;
    return (seconds * 1000).round();
  }
  return 0;
}

// ─── Leaf-node decoding ──────────────────────────────────────────────

final RegExp _llmPattern =
    RegExp(r'^llm (\S+) → (\d+)→(\d+) tok  → (\S+)$');
final RegExp _recallPattern =
    RegExp(r'^recall \((.*?) k=(\S*) → (\d+)(?:: (.+))?\)$');
// `note <category>` or `note <category> — <detail>`. The category is matched
// non-greedily so the optional ` — <detail>` tail (the compact payload summary
// the writer appends) splits off cleanly; a payload-less note has no tail.
final RegExp _notePattern = RegExp(r'^note (.+?)(?: — (.+))?$');
final RegExp _errorPattern = RegExp(r'^error (\S+): (.+)$');
// `stackPeek <name> (k=<k> → <n> entries)` — a mind-state stack read, with the
// stack name, requested depth, and returned entry count the bare line elided.
final RegExp _stackPeekPattern =
    RegExp(r'^stackPeek (\S+) \(k=(\S*) → (\d+) entries\)$');
// `tool <name>(<argSummary>) → <outcome>` (§5.7.1). The name carries no spaces or
// `(`; the arg summary is everything between the parens (it never contains ` → `,
// which the writer elides). The outcome tail is then sub-classified below.
final RegExp _toolPattern = RegExp(r'^tool ([^\s(]+)\((.*)\) → (.+)$');
final RegExp _toolOkPattern = RegExp(r'^ok \((\d+) chars\)$');
final RegExp _edgePattern =
    RegExp(r'^edge (\S+) -(\S+)-> (\S+) → (\S+)$');
final RegExp _primitiveWithIdPattern = RegExp(r'^(\S+) → (\S+)$');

/// Decodes one non-subprocedure, non-outcome content string into its [RunNode].
RunNode _leafNode(String content) {
  final llm = _llmPattern.firstMatch(content);
  if (llm != null) {
    return LlmCallNode(
      callType: llm.group(1)!,
      tokensIn: int.parse(llm.group(2)!),
      tokensOut: int.parse(llm.group(3)!),
      rawPath: llm.group(4)!,
    );
  }

  final recall = _recallPattern.firstMatch(content);
  if (recall != null) {
    final modesRaw = recall.group(1)!;
    final kRaw = recall.group(2)!;
    final idsRaw = recall.group(4);
    return PrimitiveCallNode(
      primitive: 'recall',
      recall: RecallDescriptor(
        modes: modesRaw.isEmpty ? const <String>[] : modesRaw.split('+'),
        k: kRaw.isEmpty ? null : kRaw,
        returned: int.parse(recall.group(3)!),
        returnedIds:
            idsRaw == null ? const <String>[] : idsRaw.split(', '),
      ),
    );
  }

  final error = _errorPattern.firstMatch(content);
  if (error != null) {
    return ErrorNode(errorKind: error.group(1)!, message: error.group(2)!);
  }

  final note = _notePattern.firstMatch(content);
  if (note != null) {
    return NoteNode(category: note.group(1)!, detail: note.group(2));
  }

  // A `stackPeek` read — its name / k / entry count surfaced as the node's
  // `detail` (the §4.7 deep-link machinery does not apply to a stack read).
  final stackPeek = _stackPeekPattern.firstMatch(content);
  if (stackPeek != null) {
    return PrimitiveCallNode(
      primitive: 'stackPeek',
      detail: '${stackPeek.group(1)!} '
          '(k=${stackPeek.group(2)!} → ${stackPeek.group(3)!} entries)',
    );
  }

  // A `tool.invoke` node — checked before the generic id fallback. The outcome
  // tail decides the variant: `ok (<n> chars)` (size only), `failed: <reason>`,
  // or `denied: <reason>` (§5.7.1).
  final tool = _toolPattern.firstMatch(content);
  if (tool != null) {
    final name = tool.group(1)!;
    final argSummary = tool.group(2)!;
    final tail = tool.group(3)!;
    final ok = _toolOkPattern.firstMatch(tail);
    if (ok != null) {
      return ToolCallNode(
        name: name,
        argSummary: argSummary,
        outcome: ToolCallOutcome.invoked,
        resultChars: int.parse(ok.group(1)!),
      );
    }
    if (tail.startsWith('failed: ')) {
      return ToolCallNode(
        name: name,
        argSummary: argSummary,
        outcome: ToolCallOutcome.failed,
        reason: tail.substring('failed: '.length),
      );
    }
    if (tail.startsWith('denied: ')) {
      return ToolCallNode(
        name: name,
        argSummary: argSummary,
        outcome: ToolCallOutcome.denied,
        reason: tail.substring('denied: '.length),
      );
    }
  }

  // An `edge` line carrying its endpoints (`edge <from> -<type>-> <to> → <id>`)
  // — checked before the generic id pattern, which would otherwise miss the
  // endpoints. `resultId` keeps the edge's own id; `edge` carries the endpoints.
  final edge = _edgePattern.firstMatch(content);
  if (edge != null) {
    return PrimitiveCallNode(
      primitive: 'edge',
      resultId: edge.group(4)!,
      edge: EdgeDescriptor(
        from: edge.group(1)!,
        type: edge.group(2)!,
        to: edge.group(3)!,
      ),
    );
  }

  final withId = _primitiveWithIdPattern.firstMatch(content);
  if (withId != null) {
    return PrimitiveCallNode(
      primitive: withId.group(1)!,
      resultId: withId.group(2)!,
    );
  }

  // A bare primitive (`embed`, `recallMulti`, …).
  return PrimitiveCallNode(primitive: content.trim());
}

// ─── Mutable build scaffolding ───────────────────────────────────────

/// A node slot collected during the DFS pass — either a finished leaf or a
/// sub-run whose own subtree is still being filled in.
sealed class _Pending {
  RunNode seal();
}

class _PendingLeaf extends _Pending {
  _PendingLeaf(this.node);
  final RunNode node;
  @override
  RunNode seal() => node;
}

class _PendingSubRun extends _Pending {
  _PendingSubRun(this.builder);
  final _RunBuilder builder;
  @override
  RunNode seal() => SubRunNode(run: builder.build());
}

/// A mutable [ProcedureRun] under construction.
class _RunBuilder {
  _RunBuilder({
    required this.procedureId,
    required this.runId,
    this.turnId,
    this.status = 'unknown',
  });

  final String procedureId;
  final String runId;
  final String? turnId;
  String status;
  int? elapsedMs;
  int? entryCount;
  final List<_Pending> nodes = <_Pending>[];

  ProcedureRun build() => ProcedureRun(
        procedureId: procedureId,
        runId: runId,
        turnId: turnId,
        status: status,
        elapsedMs: elapsedMs,
        entryCount: entryCount,
        nodes: <RunNode>[for (final pending in nodes) pending.seal()],
      );
}
