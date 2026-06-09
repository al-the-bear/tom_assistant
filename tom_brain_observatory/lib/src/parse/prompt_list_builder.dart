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

/// Builds one row from an `incoming/` record [file], correlating its run-tree by
/// `turnId`. Returns `null` when the record does not parse.
PromptListRow? _rowFor(TrailHost host, File file) {
  final inbound = parseInbound(file.readAsStringSync());
  if (inbound == null) return null;

  final turnId = _turnIdOf(file);
  final runTree = _runTreeFor(host, turnId);

  return PromptListRow(
    turnId: turnId,
    receivedAt: inbound.receivedAt,
    channel: inbound.channel,
    principalId: inbound.principalId,
    persona: inbound.persona,
    preview: _preview(inbound.text),
    outcomeStatus: runTree?.status,
    wallClockMs: runTree?.elapsedMs,
    llmCallCount: runTree == null ? 0 : llmCallCount(runTree),
    memoryAccessCount: runTree == null ? 0 : memoryAccessCount(runTree),
  );
}

/// Parses the run-tree for [turnId], or `null` when no `procedures/` log exists
/// (an in-flight turn with no completed run yet).
ProcedureRun? _runTreeFor(TrailHost host, String turnId) {
  final log = host.procedureLogFor(turnId);
  return log == null ? null : parseRunTree(log.readAsStringSync());
}

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
