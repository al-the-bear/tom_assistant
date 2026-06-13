// Builds the §4.1 prompt list — the last-N processed turns, newest-first, one
// [PromptListRow] each — by correlating the `incoming/`, `procedures/`, and
// `sessions/` surfaces by `turnId`. The `incoming/` records are the spine (every
// admitted turn has one); the run-tree, when present, supplies the outcome,
// wall-clock, and the LLM-call + memory-access counts.
//
// In unconfigured mode (§ 8.1 — no structured trail tree) there are no
// `incoming/` records, so the list is empty. Absence is never an error.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/prompt_trace.dart';
import '../model/run_tree.dart';
import 'inbound_parser.dart';
import 'run_tree_parser.dart';
import 'run_tree_walk.dart';
import 'trail_host.dart';

/// The suffix every `incoming/` record carries; stripped from the basename to
/// recover the `turnId` (which itself contains a `.`, so extension-stripping is
/// wrong — the suffix is removed verbatim).
const String _incomingSuffix = '.raw.json';

/// The longest prompt preview a row carries (§ 4.1 — a one-line preview).
const int _previewMaxLength = 120;

/// The last [limit] turns for [host], newest-first by `receivedAt`. Returns an
/// empty list in unconfigured mode (§ 8.1).
List<PromptListRow> promptList(TrailHost host, {int limit = 10}) {
  if (host.isUnconfigured) return const <PromptListRow>[];

  final rows = <PromptListRow>[
    for (final file in host.incomingFiles()) ?_rowFor(host, file),
  ]..sort(_newestFirst);

  return rows.length <= limit ? rows : rows.sublist(0, limit);
}

/// Builds one row from an `incoming/` record [file], correlating its run-trees
/// by `turnId`. Counts span **all** of the turn's top-level runs (classifier +
/// answer + …); the outcome + wall-clock are the substantive answer run's (the
/// latest-started, last in start order). Returns `null` when the record does not
/// parse.
PromptListRow? _rowFor(TrailHost host, File file) {
  final inbound = parseInbound(file.readAsStringSync());
  if (inbound == null) return null;

  final turnId = _turnIdOf(file);
  final runTrees = _runTreesFor(host, turnId);
  final substantive = runTrees.isEmpty ? null : runTrees.last;

  return PromptListRow(
    turnId: turnId,
    receivedAt: inbound.receivedAt,
    channel: inbound.channel,
    principalId: inbound.principalId,
    persona: inbound.persona,
    preview: _preview(inbound.text),
    outcomeStatus: substantive?.status,
    wallClockMs: substantive?.elapsedMs,
    llmCallCount: <int>[for (final run in runTrees) llmCallCount(run)]
        .fold(0, (a, b) => a + b),
    memoryAccessCount: <int>[for (final run in runTrees) memoryAccessCount(run)]
        .fold(0, (a, b) => a + b),
  );
}

/// Parses every top-level run-tree for [turnId] in start order, or an empty list
/// when no `procedures/` log exists (an in-flight turn with no completed run).
List<ProcedureRun> _runTreesFor(TrailHost host, String turnId) => <ProcedureRun>[
      for (final log in host.procedureLogsFor(turnId))
        if (parseRunTree(log.readAsStringSync()) case final ProcedureRun run)
          run,
    ];

/// Recovers the `turnId` from an `incoming/<channel>/<turnId>.raw.json` path.
String _turnIdOf(File file) {
  final name = p.basename(file.path);
  return name.endsWith(_incomingSuffix)
      ? name.substring(0, name.length - _incomingSuffix.length)
      : name;
}

/// A one-line, length-capped preview of the prompt [text] (§ 4.1).
String _preview(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).first.trim();
  return firstLine.length <= _previewMaxLength
      ? firstLine
      : '${firstLine.substring(0, _previewMaxLength)}…';
}

/// Newest-first by `receivedAt`; rows without an instant sort last.
int _newestFirst(PromptListRow a, PromptListRow b) {
  final at = a.receivedAt;
  final bt = b.receivedAt;
  if (at == null && bt == null) return 0;
  if (at == null) return 1;
  if (bt == null) return -1;
  return bt.compareTo(at);
}
