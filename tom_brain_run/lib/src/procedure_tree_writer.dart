// ProcedureTreeWriter — the §5.7 per-procedure combined log
// (`tom_brain_logging.md` §10 build-order step #9).
//
// The engine assembles one [ProcedureTreeRecord] per top-level (or turn-less
// dream) procedure run — the run's own trail entries as nodes, with each nested
// `runProcedure`'s sub-record spliced in at its call position — and hands it
// here. This writer renders that combined tree to one
// `procedures/<procedureId>/<turnId>__<runId>.log` file (a turn-less dream run
// keys by the bare `<runId>.log`).
//
// Link-only (§5.7 / §11 resolved-decision #2): the file shows the run's
// *structure* as indented box-drawing lines. An `llm` node renders its token
// counts and a relative link to the authoritative `llm/<role>/…raw.json` dump —
// never the prompt/answer body, which stays in the raw file. Memory primitives
// (`recall`, …) render as plain structural lines with no link. The link stem is
// built by [llmRawPathOf] — the same rule the raw `LlmTrailWriter` uses — so a
// tree's link and the raw file it points at agree byte-for-byte.
//
// Rendering shape (one combined run):
//
//   procedure answer_with_memory_v1  run disp-fg-run-7  turn turn_01JZ
//   ├─ recall (bm25+vector k=8 → 8)
//   ├─ llm recaller → 612→48 tok  → ../../llm/recaller/turn_01JZ__01.raw.json
//   ├─ subprocedure critique_v1  run disp-fg-run-8  (accepted)
//   │  └─ llm evaluator → 1200→30 tok  → ../../llm/evaluator/turn_01JZ__02.raw.json
//   ├─ llm assistant_to_user → 174→24 tok  → ../../llm/assistant_to_user/…
//   └─ outcome accepted (entries=16, 1.4s)
//
// Deviations from the illustrative §5.7 example (see §10 step #9 reconciliation
// note): the subtree's terminal status rides its `subprocedure …  (status)`
// header rather than a folded `(accepted)` on its last child, and only the
// top-level record renders an `outcome` line (a subtree shows its nodes only —
// its status is on the header). Token counts render as raw `<in>→<out> tok`
// (not the `1.2k` short form).
//
// Scope boundary (§10): this writer owns *only* the per-procedure `.log` files.
// The §8 count cap (N=300) is step #10's `TrailJanitor`, not here — consistent
// with the other trail writers, which do not prune their own trees.
//
// Best-effort and non-blocking (§9): a trail-write failure must never fail a
// run, so the whole write is guarded and a failure is swallowed.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        ProcedureErrorNode,
        ProcedureNoteNode,
        ProcedurePrimitiveNode,
        ProcedureSubtreeNode,
        ProcedureTreeNode,
        ProcedureTreeRecord;

import 'llm_raw_path.dart' show llmRawPathOf;

/// The `../../` hop from a `procedures/<proc>/` log back up to the trail root,
/// so a link resolves to `<root>/llm/<role>/<stem>.raw.json`.
const String _rootHop = '../../';

/// Writes the §5.7 per-procedure combined run tree, one file per top-level (or
/// turn-less dream) run (`tom_brain_logging.md` §10 step #9).
final class ProcedureTreeWriter {
  /// The trail tree root (`trail.root`). Per-procedure logs land under
  /// `<root>/procedures/<procedureId>/`.
  final Directory root;

  /// Builds a writer rooted at [root].
  ProcedureTreeWriter({required this.root});

  /// Renders [record] to its `procedures/<procedureId>/<key>.log` file, where
  /// the key is `<turnId>__<runId>` for a turn-bound run and the bare `<runId>`
  /// for a turn-less dream run. Best-effort: any failure is swallowed so a
  /// trail write never breaks the run (§9).
  void write(ProcedureTreeRecord record) {
    try {
      final key = record.turnId != null
          ? '${record.turnId}__${record.runId}'
          : record.runId;
      final file = File(
        '${root.path}/procedures/${record.procedureId}/$key.log',
      );
      final buffer = StringBuffer()..writeln(_header(record));
      _renderInto(buffer, record, prefix: '', isTop: true);

      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      file.writeAsStringSync(buffer.toString(), flush: true);
    } catch (_) {
      // Best-effort: a read-only root, a path collision, or a parent that
      // cannot be created must never propagate into the logging call site.
    }
  }

  /// The header line naming the procedure, run, and (when present) turn.
  String _header(ProcedureTreeRecord record) {
    final turn = record.turnId == null ? '' : '  turn ${record.turnId}';
    return 'procedure ${record.procedureId}  run ${record.runId}$turn';
  }

  /// Renders one record's nodes (and, for the top-level record, its trailing
  /// `outcome` line) under [prefix]. Each item is a `├─` connector except the
  /// last, which is `└─`; the `outcome` line — top-level only — is always last.
  void _renderInto(
    StringBuffer buffer,
    ProcedureTreeRecord record, {
    required String prefix,
    required bool isTop,
  }) {
    final nodes = record.nodes;
    final total = nodes.length + (isTop ? 1 : 0);
    for (var i = 0; i < nodes.length; i++) {
      final isLast = i == total - 1;
      _renderNode(
        buffer,
        nodes[i],
        prefix: prefix,
        connector: isLast ? '└─' : '├─',
        isLast: isLast,
      );
    }
    if (isTop) {
      buffer.writeln('$prefix└─ ${_outcomeLine(record)}');
    }
  }

  /// Renders one node line; a subprocedure additionally recurses its sub-tree
  /// indented under it (the continuation bar `│  ` when the subprocedure has
  /// siblings below, plain spaces when it is the last item).
  void _renderNode(
    StringBuffer buffer,
    ProcedureTreeNode node, {
    required String prefix,
    required String connector,
    required bool isLast,
  }) {
    switch (node) {
      case ProcedureSubtreeNode(:final tree):
        buffer.writeln('$prefix$connector subprocedure ${tree.procedureId}  '
            'run ${tree.runId}  (${tree.status.name})');
        final childPrefix = '$prefix${isLast ? '   ' : '│  '}';
        _renderInto(buffer, tree, prefix: childPrefix, isTop: false);
      case ProcedurePrimitiveNode():
        buffer.writeln('$prefix$connector ${_primitiveLine(node)}');
      case ProcedureNoteNode(:final category):
        buffer.writeln('$prefix$connector note $category');
      case ProcedureErrorNode(:final errorKind, :final message):
        buffer.writeln('$prefix$connector error $errorKind: $message');
    }
  }

  /// One primitive-call line. An `llm` node renders its token counts plus a
  /// relative link to its raw dump; a `recall` renders its modes / k / returned
  /// count, then the returned node ids the writer could resolve
  /// (`→ <count>: <id>, <id>` — the §4.7 cross-link source; no link — a memory
  /// primitive has no raw LLM file); any other primitive renders its name, with
  /// `→ <id>` when its result carries one.
  String _primitiveLine(ProcedurePrimitiveNode node) {
    final llm = node.llm;
    if (llm != null) {
      final link = '$_rootHop${llmRawPathOf(
        callType: llm.callType,
        turnId: llm.turnId,
        callSeq: llm.callSeq,
        runId: llm.runId,
        callId: llm.callId,
      )}';
      return 'llm ${llm.callType} → ${llm.tokensIn}→${llm.tokensOut} tok'
          '  → $link';
    }
    if (node.primitive == 'recall') {
      final modes = (node.input['modes'] as List?)
              ?.map((Object? m) => '$m')
              .join('+') ??
          '';
      final k = node.input['k'];
      final nodes = node.result['nodes'] as List?;
      final returned = nodes?.length ?? 0;
      final ids = <String>[
        for (final n in nodes ?? const <Object?>[])
          if (n is Map && n['id'] is String) n['id'] as String,
      ];
      final idSuffix = ids.isEmpty ? '' : ': ${ids.join(', ')}';
      return 'recall ($modes k=$k → $returned$idSuffix)';
    }
    final id = node.result['id'];
    return id == null ? node.primitive : '${node.primitive} → $id';
  }

  /// The §5.7 outcome line: `outcome <status> (entries=<n>, <elapsed>)`, where
  /// elapsed renders in seconds (one decimal) at or above a second, else in
  /// milliseconds.
  String _outcomeLine(ProcedureTreeRecord record) =>
      'outcome ${record.status.name} '
      '(entries=${record.entryCount}, ${_elapsed(record.elapsedMs)})';

  /// Human-scale elapsed: `1.4s` at or above a second, `800ms` below.
  String _elapsed(int ms) =>
      ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';
}
