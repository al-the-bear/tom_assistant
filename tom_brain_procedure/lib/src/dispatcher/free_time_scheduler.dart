// Free-time scheduler stub (Plan steps D.33–D.35;
// `tom_brain_procedure_specification.md` § 10.5;
// `tom_brain_definition.md` § 5.3, § 7).
//
// ── What def § 5.3 asks for ─────────────────────────────────────────
//
// `free_time_scheduler_v1` reads stacks at the start of every cycle:
//
//   sizes = stack.list()
//   hot   = stacks with size above threshold OR with high-priority top entries
//   if any(hot):
//      pick the highest-priority hot stack
//      pop its top entry
//      route it to the appropriate procedure (research / triage / author / dream_*)
//   else:
//      pick a dreaming script by round-robin
//
// "This makes the system's behaviour observable: looking at stack sizes tells
// you what the brain has on its mind."
//
// ── What the D.33 prototype stub owns ───────────────────────────────
//
// D.33 implements the *hot-stack pick + background submission* half only.
// One [tick] is one scheduler cycle:
//
//   1. If any foreground work is pending (a foreground run is live *or* one
//      waits in the coordinator's FIFO queue), the scheduler yields the
//      background slot to it and does nothing — free-time work runs only
//      when the foreground is idle (Plan D.33: "when no foreground work is
//      pending").
//   2. If a background run is already live, the cycle is a no-op — the engine
//      runs at most one background task at a time (def § 7.1, PE-5). The
//      coordinator would reject a second `submitBackground` with
//      `RunSlotBusy`; the scheduler checks first so a busy slot is a clean
//      skip, not an error.
//   3. Otherwise it reads the schedulable stacks via `memory.stacks.list()`,
//      computes which are *hot* (§ 5.3: size above [hotSizeThreshold] OR top
//      priority at/above [hotPriorityThreshold]), picks the highest-priority
//      hot stack, pops its top entry, and submits a background run built by
//      the injected [workFactory].
//   4. If no stack is hot, the cycle is `idle`. Per Plan D.34 the prototype
//      stub is intentionally weak — the § 5.3 `else` branch (round-robin
//      dreaming) is **not** built yet (no dream scripts exist), so an idle
//      cycle simply does nothing rather than synthesising a dream run.
//
// ── Why a kernel class, not the `free_time_scheduler_v1` d4rt script ──
//
// Def § 2 distinguishes two things named "free_time_scheduler_v1": the
// well-known *script* (the dreaming round-robin path) and the *kernel* in
// `lib` that loops it and drives the single-foreground / single-background
// coordinator. D.33's behaviour — "pick one entry from a hot stack and submit
// it as background" — is the *kernel*: submitting to the background slot is a
// coordinator (native) concern a d4rt procedure running *inside* the engine
// cannot perform. So this is a Dart kernel ([FreeTimeScheduler]), named
// without the `_v1` suffix the prototype reserves for d4rt procedure scripts
// (`answer_with_memory_v1.dart`); the dreaming `free_time_scheduler_v1` script
// and the continuous loop that calls [tick] land with the dream phase
// (definition § 15 step 8), not here. See Q-D.33.1.
//
// ── What this is not ────────────────────────────────────────────────
//
// The scheduler does not decide *what* a popped entry's background run does —
// the § 5.3 routing ("research / triage / author / dream_*") is the injected
// [workFactory]'s job, and in the prototype the only consumer is the D.35
// preemption proof, which supplies a trivial body. The scheduler owns *which*
// stack to pick from, *that* the foreground is idle, and *that* exactly one
// background run is submitted per hot cycle. It never reads `inflight` /
// `recent_runs` (those are runtime-tracking stacks the preemption controller
// owns, not work the scheduler should pop and "run").

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        Node,
        StackEntry,
        StackSummary,
        TomBrainMemoryClient,
        procedureRunNodeType,
        recentRunsStackName;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Clock, HistoryConfig, HistorySizing, HistoryTurn, SystemClock;

import '../api/procedure_engine.dart' show ProcedureEngine;
import '../api/procedure_invocation.dart' show ProcedureInvocation;
import '../api/procedure_outcome.dart' show ProcedureOutcome;
import '../history/dream_lane_sessions.dart' show DreamLaneSessions;
import '../recorder/run_records.dart' show producedNodeIdsOutputKey;
import 'brain_process_boot.dart'
    show compactedSummaryArgumentKey, priorTurnsArgumentKey;
import 'run_coordinator.dart' show RunBody, RunCoordinator, RunSlotBusy;

/// Procedure-input key under which [FreeTimeScheduler.triggerMaintenance]
/// threads a dreaming lane's *own* prior-run history (todo 13).
///
/// A dream procedure that wants to avoid repeating work reads
/// `inputs.get('recentRuns')` — a list of compact maps, most recent first,
/// each describing one completed prior run of the *same procedure* (the lane):
/// `{runId, status, summary, finishedAt, producedNodeIds}`. The key is bound
/// only when the lane has at least one resolvable prior run, so a first-ever
/// run's argument map is byte-identical to the no-history case (mirroring the
/// answer lane's `priorTurns` / `compactedSummary` binding discipline). A
/// procedure that does not read the key is unaffected.
const String recentRunsArgumentKey = 'recentRuns';

/// Procedure-input key under which [FreeTimeScheduler.triggerMaintenance] seeds
/// a dreaming lane's recall focus — the term the dream "dreams about".
///
/// The recall-seeded dream agents (`dream_extract_v1`, `dream_connect_v1`, …)
/// declare `source` as a *required* input and read it (`inputs.get('source')`)
/// before any memory/LLM work. A scheduled cadence firing carries no inbound
/// prompt, so without this seam the body crashes at that first read with `no
/// input named "source"`. The seam supplies the seed at the single dream-fire
/// point so the agents need no defensive fallback of their own. A caller that
/// already supplied `source` (a test harness, a manual invocation) always wins.
const String dreamSeedArgumentKey = 'source';

/// Procedure-input key under which [FreeTimeScheduler.triggerMaintenance] seeds
/// a dreaming lane's *pass clock* — the epoch-millisecond instant the lane
/// measures its verdicts against.
///
/// `dream_decay_v1` declares `nowMs` as a *required* input and reads it
/// (`inputs.get<int>('nowMs')`) to compute coldness ages: the body has no
/// access to a wall clock inside the d4rt sandbox, so the caller must stamp
/// the instant. A scheduled cadence firing carries no inbound prompt, so
/// without this seam the body crashes at that first read with `no input named
/// "nowMs"`. The seam supplies the stamp from the scheduler's injected [Clock]
/// at the single dream-fire point so the agents need no ambient-clock escape of
/// their own. A caller that already supplied `nowMs` (a test harness, a
/// deep-lane driver replaying a fixed instant) always wins.
const String dreamClockArgumentKey = 'nowMs';

/// The mind-state stacks the dream-seed seam draws a recall focus from, in
/// priority order: the brain's active interests first, then its open questions.
/// "A dream dreams about what is on the brain's mind" — the seed is the salient
/// text of the top entry of the first of these stacks that yields one.
const List<String> dreamSeedStacks = <String>['interests', 'questions_open'];

/// How many entries of a [dreamSeedStacks] stack the seam peeks when resolving
/// a seed. "Top entry" is the intent, but a degenerate top node carrying no
/// salient text field is skipped for the next, so a small window is scanned.
const int dreamSeedScanDepth = 8;

/// The stable seed a dreaming lane is fired with when neither [dreamSeedStacks]
/// yields a salient term — so a dream cycle on an empty-minded brain still runs
/// (recalling around a neutral focus) rather than crashing on a missing input.
const String defaultDreamSeed = 'recent memory';

/// The node value fields the dream-seed seam reads a salient term from, in
/// priority order. The first non-empty string field of a mind-state node
/// becomes the seed — covering the bootstrap node types parked on the seed
/// stacks (`InterestItem.title`, `Question.statement`, …) and degrading to
/// generic text fields for any future type.
const List<String> _dreamSeedFields = <String>[
  'statement',
  'title',
  'question',
  'summary',
  'name',
  'text',
  'label',
];

/// The *floor* on how many `recent_runs` entries
/// [FreeTimeScheduler.triggerMaintenance] scans when building a lane's prior-run
/// context. The stack is global across all procedures, so the firing lane's own
/// runs are interleaved with every other lane's; scanning at least this deep
/// gives the per-lane filter enough entries to surface a lane's window even when
/// other lanes have run more recently. A lane whose configured `rawCount`
/// (history-compaction quest, todo #14) exceeds this floor widens the scan to
/// `rawCount` so its window can be filled.
const int recentRunsContextDepth = 32;

/// A stack is *hot* when its size is strictly greater than this threshold
/// (§ 5.3: "size above threshold"). The prototype default `0` makes any
/// non-empty schedulable stack a size-hot candidate, so the background slot is
/// exercised whenever the brain has anything on its mind (Plan D.34).
const int defaultHotSizeThreshold = 0;

/// A stack is *hot* when its top entry's priority is at or above this
/// threshold (§ 5.3: "high-priority top entries"), regardless of size. The
/// prototype default `0.0` makes any positive-priority top entry priority-hot;
/// combined with [defaultHotSizeThreshold] the two clauses are an OR, so a
/// non-empty stack is hot either way under the defaults.
const double defaultHotPriorityThreshold = 0.0;

/// The bootstrap stacks the free-time scheduler harvests work from (§ 5.1:
/// the stacks whose "Read by" column names `free_time_scheduler_v1`).
///
/// Deliberately excludes `inflight` / `recent_runs` (runtime-tracking stacks
/// the preemption controller owns) and `restructure_backlog` (harvested by the
/// `restructure_tree_v1` family, § 5.1). Injectable so a later phase can widen
/// the set as the dreaming / restructuring procedures land.
const List<String> defaultSchedulableStacks = <String>[
  'questions_open',
  'automation_ideas',
  'interests',
];

/// Builds the background run for a popped hot-stack entry (the § 5.3 routing
/// seam, D.33).
///
/// Given the [ScheduledPick] (which stack, which entry) the factory returns
/// the [ScheduledBackgroundWork] the scheduler submits — the run body plus the
/// procedure identity used for `inflight` tracking. In production this routes
/// to `research_v1` / `triage_automation_idea_v1` / `author_new_procedure_v1`
/// / `dream_*` by the entry's stack and node type; in the prototype the D.35
/// preemption proof supplies a trivial body. Returning `null` declines the
/// pick (the cycle reports it as `idle`), e.g. when a stack has no routable
/// procedure yet.
typedef BackgroundWorkFactory = ScheduledBackgroundWork? Function(
  ScheduledPick pick,
);

/// The entry a [FreeTimeScheduler.tick] popped from a hot stack, handed to the
/// [BackgroundWorkFactory] so it can build the matching background run.
final class ScheduledPick {
  /// Wraps the [stackName] the entry was popped from and the popped [entry].
  const ScheduledPick({required this.stackName, required this.entry});

  /// The hot stack the entry was popped from (one of the scheduler's
  /// schedulable stacks).
  final String stackName;

  /// The entry the scheduler popped (its node id, priority, and attrs).
  final StackEntry entry;
}

/// The background run a [BackgroundWorkFactory] produced for a [ScheduledPick].
final class ScheduledBackgroundWork {
  /// Wraps the [body] to submit, the [procedureId] it executes (used for
  /// `inflight` / `recent_runs` tracking, D.26/D.27), and its [version].
  const ScheduledBackgroundWork({
    required this.body,
    required this.procedureId,
    this.version = 1,
  });

  /// The background run body the coordinator submits into the background slot.
  final RunBody<void> body;

  /// The procedure id this background run executes — threaded into the
  /// coordinator's `inflight` push so the run is observable as mind-state.
  final String procedureId;

  /// The procedure version this run executes (default 1, the prototype's only
  /// version).
  final int version;
}

/// Why a [FreeTimeScheduler.tick] did what it did.
enum FreeTimeDecision {
  /// Foreground work is pending (a foreground run is live or one waits in the
  /// FIFO queue). The scheduler yielded the background slot and did nothing —
  /// free-time work runs only when the foreground is idle.
  foregroundPending,

  /// A background run is already live. The engine runs at most one background
  /// task at a time, so the cycle was a no-op.
  backgroundBusy,

  /// No schedulable stack was hot this cycle (and the prototype stub does not
  /// yet fall through to round-robin dreaming, Plan D.34) — nothing to do.
  idle,

  /// A hot-stack entry was popped and submitted as a background run.
  scheduled,
}

/// The result of one [FreeTimeScheduler.tick].
///
/// Carries the [decision] plus, when something was scheduled, the [pick] it
/// was built from and the [runFuture] of the submitted background run (so a
/// caller — the D.35 preemption proof — can await its completion). For every
/// non-`scheduled` decision [pick] and [runFuture] are `null`.
final class FreeTimeSchedulerTick {
  /// A non-scheduling cycle (`foregroundPending` / `backgroundBusy` / `idle`).
  const FreeTimeSchedulerTick.noop(this.decision)
      : pick = null,
        runFuture = null;

  /// A scheduling cycle: [pick] was popped and submitted, [runFuture] is the
  /// submitted background run.
  const FreeTimeSchedulerTick.scheduled(this.pick, this.runFuture)
      : decision = FreeTimeDecision.scheduled;

  /// Why the cycle did what it did.
  final FreeTimeDecision decision;

  /// The entry that was popped and scheduled, or `null` for a non-scheduling
  /// cycle.
  final ScheduledPick? pick;

  /// The submitted background run's future, or `null` for a non-scheduling
  /// cycle.
  final Future<void>? runFuture;

  /// Whether this cycle submitted a background run.
  bool get didSchedule => decision == FreeTimeDecision.scheduled;
}

/// The dispatcher's free-time scheduler stub (Plan D.33; spec § 10.5).
///
/// One [tick] picks at most one entry from the highest-priority hot stack and
/// submits it as a background run — but only when no foreground work is
/// pending and the background slot is free. It drives the same
/// [RunCoordinator] the inbound (foreground) path uses, so the background work
/// it starts cooperatively yields to a foreground arrival exactly as PE-5
/// requires; the D.35 tests prove that preemption boundary end-to-end.
final class FreeTimeScheduler {
  /// Builds a scheduler over the [coordinator] it submits background work to,
  /// the [memory] client it reads stacks from, and the [workFactory] that
  /// turns a popped entry into a background run.
  ///
  /// [schedulableStacks] is the set of stacks the scheduler harvests
  /// (default [defaultSchedulableStacks] — the § 5.1 work stacks, excluding
  /// the runtime-tracking `inflight` / `recent_runs`). [hotSizeThreshold] and
  /// [hotPriorityThreshold] define the § 5.3 hotness test (size strictly above
  /// the size threshold OR top priority at/above the priority threshold).
  /// [engine] is the optional procedure engine the explicit single-shot
  /// [triggerMaintenance] path runs a *named* maintenance procedure through
  /// (plan #23). It is genuinely optional: the stack-harvest [tick] path needs
  /// no engine (its background body comes from [workFactory]), so the D.33–D.35
  /// suites construct the scheduler without one. A scheduler built without an
  /// engine that is asked to [triggerMaintenance] throws [StateError] — the two
  /// background-driving modes are distinct and a caller picks one by what it
  /// supplies.
  FreeTimeScheduler({
    required this.coordinator,
    required this.memory,
    required this.workFactory,
    this.engine,
    List<String> schedulableStacks = defaultSchedulableStacks,
    this.hotSizeThreshold = defaultHotSizeThreshold,
    this.hotPriorityThreshold = defaultHotPriorityThreshold,
    this.historyConfig = const HistoryConfig.standard(),
    this.dreamSessions,
    this.clock = const SystemClock(),
  }) : schedulableStacks = List<String>.unmodifiable(schedulableStacks);

  /// The coordinator the scheduler submits background runs to and reads the
  /// foreground / background slot state from.
  final RunCoordinator coordinator;

  /// The procedure engine the explicit [triggerMaintenance] path runs a named
  /// maintenance procedure through, or `null` when the scheduler was built for
  /// the stack-harvest [tick] path only.
  final ProcedureEngine? engine;

  /// The memory client the scheduler reads stack sizes / priorities from and
  /// pops the chosen entry through.
  final TomBrainMemoryClient memory;

  /// Turns a popped hot-stack entry into the background run to submit.
  final BackgroundWorkFactory workFactory;

  /// The stacks this scheduler considers for background work (§ 5.1 work
  /// stacks), copied unmodifiable so a caller's later mutation cannot widen
  /// the set behind a constructed scheduler's back.
  final List<String> schedulableStacks;

  /// A stack is size-hot when its size is strictly greater than this.
  final int hotSizeThreshold;

  /// A stack is priority-hot when its top priority is at or above this.
  final double hotPriorityThreshold;

  /// The parsed `history:` block used to size each dreaming lane's own
  /// prior-run window (history-compaction quest, todo #14; hub § 22.6b/c).
  ///
  /// [triggerMaintenance] resolves the firing lane's [HistorySizing] through
  /// `historyConfig.sizingFor(procedureId)` (the Phase-B
  /// `lane override → defaults → code default` resolver), and uses its
  /// `rawCount` as the cap on the prior-run records the lane is handed — so a
  /// `history.lanes.<dreamLaneId>` override sizes a dream lane's window
  /// independently of the foreground answer lane. Defaults to
  /// [HistoryConfig.standard] (every lane on the code-default sizing) when no
  /// `history:` block is configured.
  final HistoryConfig historyConfig;

  /// The per-dreaming-lane *activity* histories — a dreaming lane is one long
  /// session that remembers what it did across firings (history-compaction
  /// quest, todo 15; memory spec § 9.8). When supplied, [triggerMaintenance]
  /// feeds the firing lane its accumulated session turns (`priorTurns` + the
  /// bounded `compactedSummary`) *before* the run and records the firing as a
  /// new turn *after* it, compacting the lane's own history when it crosses its
  /// threshold.
  ///
  /// `null` in the stack-harvest [tick] suites and any caller that does not want
  /// per-lane session memory — the seam is byte-stable when absent (no
  /// `priorTurns` / `compactedSummary` bound, nothing recorded), mirroring the
  /// answer lane before its history store is wired.
  final DreamLaneSessions? dreamSessions;

  /// The injected time source the [triggerMaintenance] seam stamps a dreaming
  /// lane's pass clock from (under [dreamClockArgumentKey]).
  ///
  /// `dream_decay_v1` measures coldness against `nowMs` but cannot read a wall
  /// clock inside the d4rt sandbox, so the seam supplies the instant from here.
  /// Defaults to [SystemClock] (the production wall clock); tests inject a
  /// [Clock] double to fire dream lanes against a fixed, asserted instant. The
  /// no-global-clock rule holds: the clock is constructor-injected, never
  /// ambient.
  final Clock clock;

  /// Runs one scheduler cycle (§ 5.3, Plan D.33).
  ///
  /// Returns a [FreeTimeSchedulerTick] describing what happened: a no-op when
  /// foreground work is pending, the background slot is busy, or no stack is
  /// hot; otherwise a `scheduled` tick carrying the popped entry and the
  /// submitted background run's future.
  Future<FreeTimeSchedulerTick> tick() async {
    // 1. Free-time work runs only when the foreground is idle (Plan D.33).
    if (coordinator.hasForegroundRun || coordinator.foregroundQueueLength > 0) {
      return const FreeTimeSchedulerTick.noop(
        FreeTimeDecision.foregroundPending,
      );
    }
    // 2. Atomically reserve the background slot *before* any await (F.3.1). The
    // cycle must read the stacks, pop an entry, and build the run body — all
    // async — before it can submit; without an atomic reserve two concurrent
    // ticks (or a tick racing a `submitBackground`) could both observe the slot
    // free and double-admit, breaking the single-background invariant (PE-5).
    // A `null` reservation means the slot is already held (or the coordinator
    // is draining): at most one background run at a time (def § 7.1, PE-5).
    final reservation = coordinator.reserveBackground();
    if (reservation == null) {
      return const FreeTimeSchedulerTick.noop(FreeTimeDecision.backgroundBusy);
    }
    // From here every non-submitting exit must release the reservation so the
    // held slot does not leak.
    // 3. Read stacks and pick the highest-priority hot one (§ 5.3).
    final hottest = _pickHottest(await memory.stacks.list());
    if (hottest == null) {
      reservation.cancel();
      return const FreeTimeSchedulerTick.noop(FreeTimeDecision.idle);
    }
    // Pop the top entry of the chosen stack. A concurrent pop may have emptied
    // it since `list()`; treat that as an idle cycle rather than failing.
    final entry = await memory.stacks.pop(hottest.name);
    if (entry == null) {
      reservation.cancel();
      return const FreeTimeSchedulerTick.noop(FreeTimeDecision.idle);
    }
    final pick = ScheduledPick(stackName: hottest.name, entry: entry);
    final work = workFactory(pick);
    if (work == null) {
      // The factory declined to route this entry (no procedure for it yet).
      reservation.cancel();
      return const FreeTimeSchedulerTick.noop(FreeTimeDecision.idle);
    }
    // 4. Run the built body in the slot reserved in step 2 — the hold has been
    // continuous since then, so no other submitter could have taken it.
    final runFuture = reservation.submit<void>(
      work.body,
      procedureId: work.procedureId,
      version: work.version,
    );
    return FreeTimeSchedulerTick.scheduled(pick, runFuture);
  }

  /// Explicitly runs a single *named* maintenance procedure on the background
  /// slot — the minimal, manual, single-shot trigger of plan #23.
  ///
  /// This is the deliberately weak counterpart to [tick]: where [tick] harvests
  /// a hot-stack entry and routes it through [workFactory], this path takes a
  /// [procedureId] the caller names (e.g. a dreaming agent such as
  /// `dream_extract_v1`) and submits one engine-backed run into the background
  /// slot. It fires *only when invoked* — there is no timer, no loop, no
  /// autonomous dreaming — so the prototype exercises the background slot (and
  /// the PE-5 preemption boundary) on demand without an autonomous scheduler.
  ///
  /// The run is driven through the same [coordinator] the inbound (foreground)
  /// path uses, so a foreground arrival cooperatively preempts it at the
  /// procedure's next `yield_if_foreground_waiting()` checkpoint and it resumes
  /// once the foreground chain drains (PE-5). [arguments] are the procedure's
  /// inputs; [version] selects the procedure version (the prototype's only
  /// version is 1).
  ///
  /// Returns the run's [ProcedureOutcome] future. Throws [RunSlotBusy]
  /// synchronously when a background run is already live — at most one
  /// background run at a time (def § 7.1, PE-5) — and [StateError] when the
  /// scheduler was constructed without an [engine] (stack-harvest mode only).
  Future<ProcedureOutcome> triggerMaintenance(
    String procedureId, {
    Map<String, Object?> arguments = const <String, Object?>{},
    int version = 1,
  }) {
    final engine = this.engine;
    if (engine == null) {
      throw StateError(
        'FreeTimeScheduler.triggerMaintenance($procedureId) requires an '
        'engine, but this scheduler was constructed without one '
        '(stack-harvest tick mode only).',
      );
    }
    // The lane's prior-run history is read *inside* the background body, not
    // here: the `recent_runs` lookup is async, and reading it before
    // `submitBackground` would defer the synchronous `RunSlotBusy` throw a
    // busy-slot caller relies on (p2_23). Enriching within the body keeps the
    // slot decision synchronous and the memory read off the hot path.
    return coordinator.submitBackground<ProcedureOutcome>(
      () async {
        var enriched = await _withRecentRunsContext(procedureId, arguments);
        enriched = _withLaneSessionContext(procedureId, enriched);
        enriched = await _withDreamSeedContext(enriched);
        enriched = _withDreamClockContext(enriched);
        final outcome = await engine
            .invoke(
              ProcedureInvocation(
                procedureId: procedureId,
                arguments: enriched,
                version: version,
              ),
            )
            .outcome;
        await _recordLaneFiring(procedureId, outcome);
        return outcome;
      },
      procedureId: procedureId,
      version: version,
    );
  }

  /// Returns [arguments] augmented with the firing lane's own *session* history
  /// — its accumulated firing turns under [priorTurnsArgumentKey] and the
  /// bounded [compactedSummaryArgumentKey] — or [arguments] unchanged when no
  /// [dreamSessions] registry is wired or the lane has no session yet (todo 15).
  ///
  /// A dreaming lane is one long session: each prior firing is rendered as a
  /// `{user, assistant}` map (the trigger and the run's summary), most-recent
  /// last, exactly as the answer lane renders its `priorTurns`. The *full* raw
  /// window is rendered — unlike the answer lane, which drops its last
  /// (in-flight, answer-less) turn, a dream lane's firing turn is recorded
  /// *after* the run, so every turn already in the window is a completed firing.
  /// A caller that already supplied either key wins — the seam never clobbers an
  /// explicit context. A first-ever firing (no session) is byte-stable with the
  /// no-registry case.
  Map<String, Object?> _withLaneSessionContext(
    String procedureId,
    Map<String, Object?> arguments,
  ) {
    final sessions = dreamSessions;
    if (sessions == null) {
      return arguments;
    }
    final history = sessions.peek(procedureId);
    if (history == null) {
      return arguments;
    }
    final window = history.rawWindow;
    final summary = history.compactedSummary;
    final bindTurns =
        window.isNotEmpty && !arguments.containsKey(priorTurnsArgumentKey);
    final bindSummary =
        summary.isNotEmpty && !arguments.containsKey(compactedSummaryArgumentKey);
    if (!bindTurns && !bindSummary) {
      return arguments;
    }
    return <String, Object?>{
      ...arguments,
      if (bindTurns)
        priorTurnsArgumentKey: <Map<String, Object?>>[
          for (final HistoryTurn turn in window)
            <String, Object?>{
              'user': turn.userPrompt,
              'assistant': turn.brainAnswer,
            },
        ],
      if (bindSummary) compactedSummaryArgumentKey: summary,
    };
  }

  /// Records one firing of [procedureId] as a turn in the lane's own session
  /// history (todo 15), so the *next* firing remembers it.
  ///
  /// A no-op when no [dreamSessions] registry is wired. The turn's "assistant"
  /// answer is the run's summary — read best-effort from the persisted
  /// `ProcedureRun` node ([ProcedureOutcome.record]), falling back to the run's
  /// status name when the node is unreadable or carries no summary. Recording a
  /// firing (and any threshold compaction it triggers) never fails the dream
  /// run: a session-store problem is swallowed, since the lane's narrative
  /// memory is an enhancement, never a precondition.
  Future<void> _recordLaneFiring(
    String procedureId,
    ProcedureOutcome outcome,
  ) async {
    final sessions = dreamSessions;
    if (sessions == null) {
      return;
    }
    try {
      await sessions.recordFiring(
        procedureId,
        trigger: 'dream cycle ${outcome.runId}',
        outcome: await _firingSummary(outcome),
      );
    } on Object {
      // Narrative memory is best-effort — never crash a dream run over it.
    }
  }

  /// The summary text recorded for a firing: the persisted `ProcedureRun`
  /// node's `summary`, or the run's status name when no usable summary exists.
  Future<String> _firingSummary(ProcedureOutcome outcome) async {
    try {
      final node = await memory.get(outcome.record.runNodeId);
      final summary = node?.values['summary'];
      if (summary is String && summary.isNotEmpty) {
        return summary;
      }
    } on Object {
      // Fall through to the status name.
    }
    return outcome.status.name;
  }

  /// Returns [arguments] augmented with the firing lane's own prior-run
  /// history under [recentRunsArgumentKey], or [arguments] unchanged when the
  /// lane has no resolvable prior run (so a first-ever run is byte-stable).
  ///
  /// A caller that already supplied a `recentRuns` argument wins — the seam
  /// never clobbers an explicit context.
  Future<Map<String, Object?>> _withRecentRunsContext(
    String procedureId,
    Map<String, Object?> arguments,
  ) async {
    if (arguments.containsKey(recentRunsArgumentKey)) {
      return arguments;
    }
    final priorRuns = await _recentRunsForLane(procedureId);
    if (priorRuns.isEmpty) {
      return arguments;
    }
    return <String, Object?>{
      ...arguments,
      recentRunsArgumentKey: priorRuns,
    };
  }

  /// Returns [arguments] augmented with a dreaming-lane recall seed under
  /// [dreamSeedArgumentKey], or [arguments] unchanged when a caller already
  /// supplied one.
  ///
  /// The recall-seeded dream agents require `source`; a scheduled cadence
  /// firing carries no inbound prompt, so the seam supplies the seed here —
  /// always, since the seed always resolves (to [defaultDreamSeed] in the
  /// worst case). An explicit caller-supplied `source` is never clobbered.
  Future<Map<String, Object?>> _withDreamSeedContext(
    Map<String, Object?> arguments,
  ) async {
    if (arguments.containsKey(dreamSeedArgumentKey)) {
      return arguments;
    }
    return <String, Object?>{
      ...arguments,
      dreamSeedArgumentKey: await _resolveDreamSeed(),
    };
  }

  /// Returns [arguments] augmented with the dreaming-lane pass clock under
  /// [dreamClockArgumentKey], or [arguments] unchanged when a caller already
  /// supplied one.
  ///
  /// `dream_decay_v1` requires `nowMs` to age coldness but cannot read a wall
  /// clock inside the sandbox, so the seam stamps the instant from the
  /// scheduler's injected [clock] here — always, since the clock always yields
  /// a value. An explicit caller-supplied `nowMs` (a test, a deep-lane driver
  /// replaying a fixed instant) is never clobbered.
  Map<String, Object?> _withDreamClockContext(
    Map<String, Object?> arguments,
  ) {
    if (arguments.containsKey(dreamClockArgumentKey)) {
      return arguments;
    }
    return <String, Object?>{
      ...arguments,
      dreamClockArgumentKey: clock.nowMs(),
    };
  }

  /// Resolves the term a dream cycle "dreams about": the salient text of the
  /// top entry of the first [dreamSeedStacks] stack that yields one, falling
  /// back to [defaultDreamSeed] when neither does.
  ///
  /// Best-effort: a stack-read failure, a dangling entry, or a node with no
  /// salient text field is skipped rather than failing the dream run — the
  /// brain's mind-state seed is an enhancement, never a precondition (mirroring
  /// the `recent_runs` scan's best-effort discipline).
  Future<String> _resolveDreamSeed() async {
    for (final stackName in dreamSeedStacks) {
      final List<StackEntry> entries;
      try {
        entries = await memory.stacks.peek(stackName, k: dreamSeedScanDepth);
      } on Object {
        continue;
      }
      for (final entry in entries) {
        final node = await memory.get(entry.nodeId);
        if (node == null) {
          continue;
        }
        final salient = _salientText(node);
        if (salient != null) {
          return salient;
        }
      }
    }
    return defaultDreamSeed;
  }

  /// The first non-empty string value of [node] among [_dreamSeedFields], or
  /// `null` when the node carries no salient text — the seed term harvested
  /// from a mind-state node (an `InterestItem`'s title, a `Question`'s
  /// statement, …).
  String? _salientText(Node node) {
    for (final field in _dreamSeedFields) {
      final value = node.values[field];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Reads the global `recent_runs` stack and distils the completed
  /// `ProcedureRun` records that belong to [procedureId] (the firing lane)
  /// into compact "what was already done" maps, most recent first — capped at
  /// the lane's own configured window.
  ///
  /// The window size is the lane's [HistorySizing.rawCount], resolved through
  /// [historyConfig] (`lane override → defaults → code default`), so each
  /// dreaming lane sizes its prior-run history independently of the answer lane
  /// (history-compaction quest, todo #14). The global stack interleaves every
  /// lane's runs, so the scan reaches at least [recentRunsContextDepth] entries
  /// — widened to `rawCount` when a lane configures a larger window — before the
  /// per-lane filter, and stops collecting once `rawCount` of the firing lane's
  /// own runs have been gathered.
  ///
  /// Best-effort: a stack-read failure or a dangling / wrong-type entry yields
  /// no context rather than failing the dream run — prior-run history is an
  /// optimisation (skip repeated work), never a precondition.
  Future<List<Map<String, Object?>>> _recentRunsForLane(
    String procedureId,
  ) async {
    final HistorySizing sizing = historyConfig.sizingFor(procedureId);
    final int scanDepth = sizing.rawCount > recentRunsContextDepth
        ? sizing.rawCount
        : recentRunsContextDepth;
    final List<StackEntry> entries;
    try {
      entries = await memory.stacks.peek(
        recentRunsStackName,
        k: scanDepth,
      );
    } on Object {
      return const <Map<String, Object?>>[];
    }
    final laneRuns = <Map<String, Object?>>[];
    for (final entry in entries) {
      if (laneRuns.length >= sizing.rawCount) {
        break;
      }
      final node = await memory.get(entry.nodeId);
      if (node == null || node.typeName != procedureRunNodeType) {
        continue;
      }
      final values = node.values;
      if (values['procedureId'] != procedureId) {
        continue;
      }
      laneRuns.add(<String, Object?>{
        'runId': values['runId'],
        'status': values['status'],
        'summary': values['summary'],
        'finishedAt': values['finishedAt'],
        producedNodeIdsOutputKey:
            values[producedNodeIdsOutputKey] ?? const <String>[],
      });
    }
    return List<Map<String, Object?>>.unmodifiable(laneRuns);
  }

  /// Picks the highest-priority hot stack among the [summaries], restricted to
  /// [schedulableStacks], or `null` when none is hot (§ 5.3).
  ///
  /// Hotness (per stack): `size > hotSizeThreshold` OR
  /// `topPriority >= hotPriorityThreshold`. Among the hot stacks the winner is
  /// the one with the highest top priority; ties break on larger size, then on
  /// name (ascending) for a deterministic, observable choice.
  StackSummary? _pickHottest(List<StackSummary> summaries) {
    final hot = <StackSummary>[
      for (final s in summaries)
        if (schedulableStacks.contains(s.name) && _isHot(s)) s,
    ];
    if (hot.isEmpty) {
      return null;
    }
    hot.sort((a, b) {
      final byPriority = b.topPriority.compareTo(a.topPriority);
      if (byPriority != 0) {
        return byPriority;
      }
      final bySize = b.size.compareTo(a.size);
      if (bySize != 0) {
        return bySize;
      }
      return a.name.compareTo(b.name);
    });
    return hot.first;
  }

  /// Whether [summary] is hot (§ 5.3): size strictly above [hotSizeThreshold]
  /// OR top priority at/above [hotPriorityThreshold]. An empty stack
  /// (`size == 0`) is never hot regardless of the priority clause — there is
  /// nothing to pop.
  bool _isHot(StackSummary summary) {
    if (summary.size <= 0) {
      return false;
    }
    return summary.size > hotSizeThreshold ||
        summary.topPriority >= hotPriorityThreshold;
  }
}
