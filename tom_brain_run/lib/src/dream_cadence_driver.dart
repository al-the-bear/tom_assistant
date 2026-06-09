// The scheduled dream cadence driver (Todo 10, G-M3).
//
// `memory_specification.md` § 7.3 is explicit: "memory does not auto-recompute
// on its own; the dream-cycle cadence is the *policy*." The cognitive-agent
// scripts (`dream_*_v1`, `research_v1`, the `restructure_tree_v1` family) are
// written once in `tom_brain_procedure/scripts/system/` and run on demand via
// `FreeTimeScheduler.triggerMaintenance(procedureId)`. What was missing — and
// what this file lands — is the *scheduled driver* that fires those passes on a
// cadence rather than only when a test or operator pokes them
// (`memory_specification.md` § 9.7).
//
// Why this lives in `tom_brain_run`, not in memory or procedure:
//
//   * Interval policy is a *deployment* concern. Big Beast, bomber, and a laptop
//     mirror have different appetites for heavy passes; baking intervals into
//     the reusable libraries would freeze that policy. `tom_brain_run` is where
//     the process is assembled, so it is where "when does the brain sleep" is
//     decided.
//   * The driver owns no write path. It only *invokes* agents through the fire
//     seam; every write still flows through each agent's registry scope
//     (`memory_specification.md` § 9.5) and idempotency keys (§ 9.1). Running an
//     agent on a schedule is therefore observably identical to running it on
//     demand — the no-overwrite invariant (hard principle 6) is the agents'
//     property, untouched by *when* they fire. A scheduled pass can never widen
//     a scope, so it can never overwrite an episodic original.
//
// The driver carries no substrate / embedding dependency: it fires procedure
// ids and nothing else. That is the G-S2 guarantee for Todo 10 — the cadence
// introduces no embedding call site; the agents own embedding access through
// the substrate `EmbeddingService` interface, unchanged.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Clock;

/// The timed lanes a [DreamCadenceDriver] fires on a cadence.
///
/// Each lane groups the cognitive agents that share an interval. The
/// shaking-event reconsolidation path is deliberately *not* a lane — it is
/// event-driven (see [DreamCadenceDriver.handleShakingEvent]), not on a timer.
enum DreamLane {
  /// Cheap, continuous consolidation — turns fresh trails/events into
  /// `Claim` / `Concept` nodes and edges.
  fast,

  /// The periodic sleep cycle — consolidation, procedure promotion/demotion,
  /// question-raising, centroid + repetition maintenance.
  slow,

  /// Deep sleep — expensive autonomous research and demotion/pruning.
  deep,

  /// Long-running, checkpointed schema/centroid re-migration.
  monthly,
}

/// Whether a fired agent actually ran or was deferred this cycle.
///
/// The production fire seam maps a busy background slot (`RunSlotBusy`) to
/// [deferred]; the driver treats a deferred agent as "not run this tick" and
/// does not advance the lane's clock, so the lane retries on the next tick
/// without waiting another full interval.
enum FireOutcome {
  /// The agent ran (was submitted to the background slot).
  fired,

  /// The agent could not run this cycle (e.g. the background slot was busy).
  deferred,
}

/// Fires one maintenance agent by its procedure id, reporting whether it ran.
///
/// In production this wraps `FreeTimeScheduler.triggerMaintenance`, mapping
/// `RunSlotBusy` to [FireOutcome.deferred]; tests inject a recording seam.
typedef MaintenanceFire = Future<FireOutcome> Function(String procedureId);

/// The lane → interval and lane → agent mapping the driver fires by
/// (`memory_specification.md` § 9.7).
///
/// The mapping is the contract; the intervals are deployment configuration.
/// The procedure-metrics promotion/demotion pass (`dream_procedure_metrics_v1`,
/// G-PR5) lives in the [DreamLane.slow] lane — it is the Synthesiser sleep
/// cadence the procedure spec names (`procedure_specification.md` § 6.4), so it
/// shares the slow interval rather than carrying its own.
final class CadenceSchedule {
  /// Builds a schedule from explicit [intervals] and [agents] maps plus the
  /// off-timer [shakingAgent].
  ///
  /// Both maps must name every [DreamLane]; [DreamCadenceDriver]'s constructor
  /// asserts completeness so a missing lane is a construction-time error, not a
  /// silent no-fire.
  const CadenceSchedule({
    required this.intervals,
    required this.agents,
    this.shakingAgent = 'dream_reconsolidate_v1',
  });

  /// The § 9.7 default schedule.
  factory CadenceSchedule.defaults() => const CadenceSchedule(
        intervals: <DreamLane, Duration>{
          DreamLane.fast: Duration(minutes: 5),
          DreamLane.slow: Duration(hours: 1),
          DreamLane.deep: Duration(days: 1),
          DreamLane.monthly: Duration(days: 30),
        },
        agents: <DreamLane, List<String>>{
          DreamLane.fast: <String>['dream_extract_v1', 'dream_connect_v1'],
          DreamLane.slow: <String>[
            'dream_synthesise_v1',
            'dream_procedure_metrics_v1',
            'dream_inquisitor_v1',
            'dream_recentroid_v1',
            'dream_repetition_detect_v1',
          ],
          DreamLane.deep: <String>['research_v1', 'dream_prune_v1'],
          DreamLane.monthly: <String>['restructure_tree_v1'],
        },
      );

  /// How long a lane waits between fires.
  final Map<DreamLane, Duration> intervals;

  /// The agents a lane fires, in fire order.
  final Map<DreamLane, List<String>> agents;

  /// The agent the off-timer shaking-event path fires
  /// (`memory_specification.md` § 9.4 / § 9.7).
  final String shakingAgent;
}

/// Fires the dreaming agents on their cadence (`memory_specification.md`
/// § 9.7).
///
/// One [tick] is one heartbeat: every lane whose interval has elapsed since it
/// last fired runs its agents, in lane order (fast → slow → deep → monthly),
/// each through the [fire] seam. A lane that defers (busy background slot) does
/// not advance — it retries on the next tick. The shaking-event path is off the
/// timer: [handleShakingEvent] fires the reconsolidator on demand, routed from
/// memory's `ShakingEvent` stream.
///
/// The driver is pure timing: it reads [clock], decides which lanes are due,
/// and calls [fire]. It holds no store, no substrate, and no write path, so it
/// cannot affect *what* an agent writes — only *when* it runs.
final class DreamCadenceDriver {
  /// Builds a driver over the [clock] it reads "now" from, the [fire] seam it
  /// invokes agents through, and the [schedule] (default
  /// [CadenceSchedule.defaults]).
  ///
  /// The construction instant baselines every lane: a lane first fires one
  /// interval *after* construction, not on the first tick — so a freshly booted
  /// brain does not immediately run every expensive pass at once.
  DreamCadenceDriver({
    required this.clock,
    required this.fire,
    CadenceSchedule? schedule,
  }) : schedule = schedule ?? CadenceSchedule.defaults() {
    final start = clock.nowMs();
    for (final lane in DreamLane.values) {
      assert(
        this.schedule.intervals.containsKey(lane) &&
            this.schedule.agents.containsKey(lane),
        'CadenceSchedule must map every DreamLane; missing $lane',
      );
      _lastFiredMs[lane] = start;
    }
  }

  /// The injected time source (UTC). Tests pass a `MutableTestClock`.
  final Clock clock;

  /// The seam each due agent is fired through.
  final MaintenanceFire fire;

  /// The lane → interval / lane → agent mapping fired by.
  final CadenceSchedule schedule;

  /// Per-lane last-fired instant (ms since epoch), seeded at construction.
  final Map<DreamLane, int> _lastFiredMs = <DreamLane, int>{};

  /// Runs one heartbeat: fires every due lane's agents and returns the ids that
  /// actually ran this cycle, in fire order.
  ///
  /// A lane is due when `clock - lastFired >= interval`. Its agents fire in
  /// order; if any defers (busy slot) the lane stops there, records no fire
  /// (so the elapsed interval still counts next tick), and the remaining agents
  /// do not run. A lane that fires every agent records the current instant.
  Future<List<String>> tick() async {
    final now = clock.nowMs();
    final ran = <String>[];
    for (final lane in DreamLane.values) {
      if (!_isDue(lane, now)) {
        continue;
      }
      var laneComplete = true;
      for (final procedureId in schedule.agents[lane]!) {
        final outcome = await fire(procedureId);
        if (outcome == FireOutcome.deferred) {
          laneComplete = false;
          break;
        }
        ran.add(procedureId);
      }
      if (laneComplete) {
        _lastFiredMs[lane] = now;
      }
    }
    return ran;
  }

  /// Whether [lane]'s interval has elapsed since it last fired, as of [nowMs].
  ///
  /// A lane is due the moment `now - lastFired >= interval`; a deferred lane
  /// keeps its old last-fired baseline, so the elapsed interval still counts on
  /// the next tick rather than restarting the wait.
  bool _isDue(DreamLane lane, int nowMs) =>
      nowMs - _lastFiredMs[lane]! >= schedule.intervals[lane]!.inMilliseconds;

  /// Fires the reconsolidator for a raised `ShakingEvent`
  /// (`memory_specification.md` § 9.4) — the event-driven path, off the timer.
  ///
  /// Production subscribes to memory's event stream and routes each
  /// `ShakingEvent` here; the lane scheduler never fires the reconsolidator.
  Future<void> handleShakingEvent() async {
    await fire(schedule.shakingAgent);
  }
}
