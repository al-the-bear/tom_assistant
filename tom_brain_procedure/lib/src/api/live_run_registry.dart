// LiveRunRegistry — the process-lifetime view of the in-flight runs, so an
// out-of-band observer (the Telegram `/check_usage` command) can read the
// *live* budget of the prompt being processed right now.
//
// A `RunRecorder` accumulates a run's effort one bridged-primitive call at a
// time, but it lives entirely inside `_runInternal`'s scope and closes the
// moment the run finishes — by the time the effort reaches durable storage the
// run is over and its tally is final. There is therefore no way, from outside
// the engine, to ask "how much has the prompt currently being processed spent
// so far?". This registry is that seam: the engine opens a [LiveRun] for every
// run when its recorder starts and closes it the moment the run finishes, so an
// observer can read the live accumulating effort of the open runs at any time.
//
// The single foreground invariant (one user prompt in flight at a time) makes
// the read unambiguous: every open run that serves a user turn (a non-null
// `turnId`) belongs to the *one* prompt currently being processed — its
// top-level run plus whatever sub-procedures it has spawned. Turn-less runs
// (background dream / maintenance work) are excluded, so `/check_usage` reports
// exactly the user's prompt and never a background pass. [currentPromptUsage]
// folds the open turn-runs into one [LiveRunUsage] snapshot.

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;

/// One in-flight run, registered while its `RunRecorder` is open.
///
/// Carries the run's identity and a [readEffort] closure that reads the live
/// accumulating effort of the run's recorder — so the registry never has to
/// hold the recorder itself (and a test can register a [LiveRun] without one).
final class LiveRun {
  /// The run's id (the `RunRegistry` slot key for a top-level run).
  final String runId;

  /// The procedure the run is executing.
  final String procedureId;

  /// The parent run's id, or `null` for a top-level run (the prompt's own run).
  final String? parentRunId;

  /// The user turn this run serves, or `null` for a turn-less background run
  /// (a dream / maintenance pass). Runs with a non-null `turnId` belong to the
  /// single foreground prompt currently being processed.
  final String? turnId;

  /// When the run started (its recorder's stamped start instant).
  final DateTime startedAt;

  /// Reads the run recorder's live accumulated effort. Called on demand by
  /// [LiveRunRegistry.currentPromptUsage]; never cached, so it always reflects
  /// the calls recorded up to the read.
  final EffortMetrics Function() readEffort;

  /// Builds a live-run handle.
  LiveRun({
    required this.runId,
    required this.procedureId,
    required this.parentRunId,
    required this.turnId,
    required this.startedAt,
    required this.readEffort,
  });

  /// The run's live accumulated effort (a fresh read each call).
  EffortMetrics get effort => readEffort();
}

/// A folded snapshot of the prompt currently being processed, for the
/// `/check_usage` command.
///
/// [effort] is the field-wise sum of every open turn-run's live effort, so it
/// includes the sub-procedures the top-level run has spawned — `estimatedTokens`
/// / `llmCalls` / `toolCalls` reflect the whole prompt, not just its outer loop.
/// [startedAt] / [procedureId] / [runId] name the top-level run, so the elapsed
/// time is measured from when the prompt began.
final class LiveRunUsage {
  /// The top-level run's procedure (the prompt's entry procedure).
  final String procedureId;

  /// The top-level run's id.
  final String runId;

  /// When the top-level run started (elapsed is measured from here).
  final DateTime startedAt;

  /// How many runs of the prompt are open right now (the top-level run plus its
  /// in-flight sub-procedures).
  final int openRunCount;

  /// The summed live effort across every open run of the prompt.
  final EffortMetrics effort;

  /// Builds a usage snapshot.
  const LiveRunUsage({
    required this.procedureId,
    required this.runId,
    required this.startedAt,
    required this.openRunCount,
    required this.effort,
  });
}

/// A process-lifetime registry of the currently-open [LiveRun]s.
///
/// One instance is held by the engine for the whole process. The engine
/// [open]s a run when its recorder starts and [close]s it when the run
/// finishes, so at any moment the registry holds exactly the runs in flight.
/// [currentPromptUsage] reads the live effort of the single foreground prompt.
final class LiveRunRegistry {
  final Map<String, LiveRun> _open = <String, LiveRun>{};

  /// Registers an open [run]. Replacing an existing id is harmless (a run id is
  /// unique per run, so this only ever inserts).
  void open(LiveRun run) {
    _open[run.runId] = run;
  }

  /// Deregisters the run under [runId]. A no-op when it is already gone.
  void close(String runId) {
    _open.remove(runId);
  }

  /// Whether a user prompt is being processed right now — i.e. at least one
  /// open run serves a turn. `false` while only background work (or nothing)
  /// runs, so `/check_usage` can report "no prompt is being processed".
  bool get hasOpenPromptRun => _open.values.any((r) => r.turnId != null);

  /// A folded snapshot of the prompt currently being processed, or `null` when
  /// no user prompt is in flight.
  ///
  /// Sums the live effort of every open run that serves a turn (the prompt's
  /// top-level run plus its in-flight sub-procedures) and names the top-level
  /// run (`parentRunId == null`) for the started-at / procedure id. When no
  /// top-level run is found among the open turn-runs (a transient window the
  /// single-foreground invariant should preclude), it falls back to the
  /// earliest-started run so the snapshot is still well-formed.
  LiveRunUsage? currentPromptUsage() {
    final runs = _open.values.where((r) => r.turnId != null).toList();
    if (runs.isEmpty) return null;

    LiveRun top = runs.firstWhere(
      (r) => r.parentRunId == null,
      orElse: () => runs.reduce(
        (a, b) => a.startedAt.isBefore(b.startedAt) ? a : b,
      ),
    );

    var effort = EffortMetrics.zero;
    for (final run in runs) {
      effort = effort.plus(run.effort);
    }

    return LiveRunUsage(
      procedureId: top.procedureId,
      runId: top.runId,
      startedAt: top.startedAt,
      openRunCount: runs.length,
      effort: effort,
    );
  }
}
