// The top-level assembler: re-assembles one [PromptTrace] (`prompt_tracing.md`
// § 3.2) for a `turnId` from the trail files the brain already wrote, reading
// each surface read-only through a [TrailHost]. It introduces no persisted model
// — it projects `incoming/` + `procedures/` + `llm/` + `sessions/` into one view
// keyed by the turn (§ 3.1).
//
// Each section degrades independently: a missing `incoming/` record yields a
// `null` [PromptTrace.inbound], no `procedures/` logs yield an empty
// [PromptTrace.runTrees], and so on. The whole trace is `null` only when *no*
// surface carries the turn at all (§ 4.1 — absence is never an error).

import '../model/prompt_trace.dart';
import '../model/run_tree.dart';
import 'configuration_builder.dart';
import 'inbound_parser.dart';
import 'reply_parser.dart';
import 'run_tree_parser.dart';
import 'trail_host.dart';

/// Re-assembles the [PromptTrace] for [turnId] from [host]'s trail tree, or
/// `null` when the turn has no `incoming/`, no run-tree, and no reply — i.e. the
/// turn is unknown to this host.
PromptTrace? promptTraceFor(TrailHost host, String turnId) {
  final inbound = _readInbound(host, turnId);

  // Every top-level run of the turn (classifier first, answer last), each paired
  // with the `.log` its `llm` links are relative to.
  final logs = host.procedureLogsFor(turnId);
  final runs = <ParsedRun>[
    for (final log in logs)
      if (parseRunTree(log.readAsStringSync()) case final ProcedureRun run)
        (run: run, log: log),
  ];

  final configuration = buildConfiguration(
    runs: runs,
    host: host,
    memoryProfile: inbound?.profile,
  );

  // Outcome + wall-clock come from the substantive answer run (the last,
  // latest-started), not the sub-second classifier.
  final substantive = runs.isEmpty ? null : runs.last.run;
  final reply = _buildReply(host, turnId, inbound, substantive);

  if (inbound == null && runs.isEmpty && reply == null) return null;

  return PromptTrace(
    turnId: turnId,
    inbound: inbound,
    configuration: configuration,
    reply: reply,
    runTrees: <ProcedureRun>[for (final r in runs) r.run],
  );
}

/// Reads + parses the `incoming/` record for [turnId], or `null` when none.
Inbound? _readInbound(TrailHost host, String turnId) {
  final file = host.incomingFile(turnId);
  return file == null ? null : parseInbound(file.readAsStringSync());
}

/// Joins the §5.4 session-summary answer with the run-tree outcome into a
/// [Reply], or `null` when neither surface carries anything for the turn.
Reply? _buildReply(
  TrailHost host,
  String turnId,
  Inbound? inbound,
  ProcedureRun? runTree,
) {
  String? finalAnswer;
  if (inbound != null) {
    final summary = host.sessionSummaryFile(inbound.sessionId);
    if (summary != null) {
      finalAnswer = finalAnswerFor(summary.readAsStringSync(), turnId);
    }
  }

  final outcomeStatus = runTree?.status;
  final wallClockMs = runTree?.elapsedMs;

  if (finalAnswer == null && outcomeStatus == null && wallClockMs == null) {
    return null;
  }
  return Reply(
    finalAnswer: finalAnswer,
    outcomeStatus: outcomeStatus,
    wallClockMs: wallClockMs,
  );
}
