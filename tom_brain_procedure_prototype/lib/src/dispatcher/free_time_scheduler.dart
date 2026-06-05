// Free-time scheduler stub (Plan steps D.33–D.35;
// `tom_brain_procedure_prototype_specification.md` § 10.5;
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
    show StackEntry, StackSummary, TomBrainMemoryClient;

import '../api/procedure_engine.dart' show ProcedureEngine;
import '../api/procedure_invocation.dart' show ProcedureInvocation;
import '../api/procedure_outcome.dart' show ProcedureOutcome;
import 'run_coordinator.dart' show RunBody, RunCoordinator, RunSlotBusy;

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
    return coordinator.submitBackground<ProcedureOutcome>(
      () => engine
          .invoke(
            ProcedureInvocation(
              procedureId: procedureId,
              arguments: arguments,
              version: version,
            ),
          )
          .outcome,
      procedureId: procedureId,
      version: version,
    );
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
