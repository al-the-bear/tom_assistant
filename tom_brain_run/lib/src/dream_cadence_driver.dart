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
//
// ── Config-defined named lanes (dream-redesign parts b + e) ─────────────
//
// Lanes are no longer a closed Dart enum. A lane is a [DreamLaneSpec] value
// object keyed by a `String` id, and a [CadenceSchedule] is an ordered list of
// them. This makes both the per-lane interval (part b) and the lane set itself
// (part e) deployment configuration: a new lane is "author the
// `scripts/system/<agent>_v1.dart`, add a `lanes:` entry naming it" — no enum,
// no Dart change. `CadenceSchedule.defaults()` reproduces the canonical four
// lanes (`memory_specification.md` § 9.7).
//
// ── Serial lane queue (dream-redesign part c) ───────────────────────────
//
// Dreaming lanes never run in parallel. [tick] no longer fires inline: it
// *enqueues* every due lane whose id is not already queued (dedupe), advancing
// each enqueued lane's baseline so it is not re-enqueued on every heartbeat
// while it waits its turn, then pumps. [_pump] runs at most one agent at a time
// — it dequeues the head lane, fires its agents in order (each awaited to
// completion before the next), and only then moves to the next lane. A deferred
// agent (busy background slot, or — part d — a spent throttle budget)
// re-enqueues its lane at the tail and stops the pump until the next tick, so no
// dream work is lost and the slot is never busy-spun. The lane resumes from the
// agent that did not run (a per-lane cursor), so the already-run prefix is never
// re-fired on the retry — the property that lets the throttle *pace* a lane
// rather than livelock one whose LLM-using agents outnumber its window budget.

import 'dart:collection';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Clock;

import 'dream_throttle.dart';

/// One timed lane a [DreamCadenceDriver] fires on a cadence.
///
/// A lane groups the cognitive agents that share an interval, keyed by a stable
/// string [id] (`fast` / `slow` / `deep` / `monthly` in the default schedule,
/// but any id a deployment configures). The shaking-event reconsolidation path
/// is deliberately *not* a lane — it is event-driven (see
/// [DreamCadenceDriver.handleShakingEvent]), not on a timer.
final class DreamLaneSpec {
  /// Builds a lane that fires [agents] (in order) every [interval].
  ///
  /// [maxLlmCallsPerWindow] is the optional per-lane override the dream
  /// throttle (dream-redesign part d) consults; `null` means "use the global
  /// throttle budget" (or unthrottled when no global budget is configured).
  const DreamLaneSpec({
    required this.id,
    required this.interval,
    required this.agents,
    this.maxLlmCallsPerWindow,
  });

  /// The stable lane id (the durable queue key and the config handle).
  final String id;

  /// How long the lane waits between fires.
  final Duration interval;

  /// The agents the lane fires, in fire order.
  final List<String> agents;

  /// Optional per-lane LLM-call budget for the dream throttle (part d).
  final int? maxLlmCallsPerWindow;
}

/// Whether a fired agent actually ran or was deferred this cycle.
///
/// The production fire seam maps a busy background slot (`RunSlotBusy`) to
/// [deferred]; the driver treats a deferred agent as "not run this cycle",
/// re-enqueues its lane, and retries on a later tick without waiting another
/// full interval.
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

/// The ordered set of timed [DreamLaneSpec]s the driver fires by, plus the
/// off-timer [shakingAgent] (`memory_specification.md` § 9.7).
///
/// The lanes are the contract; intervals and the lane set are deployment
/// configuration (dream-redesign parts b + e). The procedure-metrics
/// promotion/demotion pass (`dream_procedure_metrics_v1`, G-PR5) lives in the
/// `slow` lane — it is the Synthesiser sleep cadence the procedure spec names
/// (`procedure_specification.md` § 6.4), so it shares the slow interval rather
/// than carrying its own.
final class CadenceSchedule {
  /// Builds a schedule from an ordered [lanes] list plus the off-timer
  /// [shakingAgent].
  ///
  /// Validates the lane set up front so a malformed schedule is a
  /// construction-time error, not a silent no-fire: at least one lane, unique
  /// non-empty ids, a strictly positive interval per lane, and at least one
  /// agent per lane.
  CadenceSchedule({
    required this.lanes,
    this.shakingAgent = 'dream_reconsolidate_v1',
  }) {
    if (lanes.isEmpty) {
      throw ArgumentError.value(lanes, 'lanes', 'must name at least one lane');
    }
    final seen = <String>{};
    for (final lane in lanes) {
      if (lane.id.isEmpty) {
        throw ArgumentError.value(lane.id, 'lane.id', 'must be non-empty');
      }
      if (!seen.add(lane.id)) {
        throw ArgumentError.value(lane.id, 'lane.id', 'duplicate lane id');
      }
      if (lane.interval <= Duration.zero) {
        throw ArgumentError.value(
            lane.interval, 'lane.interval', 'must be positive for "${lane.id}"');
      }
      if (lane.agents.isEmpty) {
        throw ArgumentError.value(
            lane.agents, 'lane.agents', 'must be non-empty for "${lane.id}"');
      }
    }
  }

  /// The § 9.7 default schedule — the canonical four lanes.
  factory CadenceSchedule.defaults() => CadenceSchedule(
        lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
            id: 'fast',
            interval: Duration(minutes: 5),
            agents: <String>['dream_extract_v1', 'dream_connect_v1'],
          ),
          const DreamLaneSpec(
            id: 'slow',
            interval: Duration(hours: 1),
            agents: <String>[
              'dream_synthesise_v1',
              'dream_procedure_metrics_v1',
              'dream_inquisitor_v1',
              'dream_recentroid_v1',
              'dream_repetition_detect_v1',
            ],
          ),
          const DreamLaneSpec(
            id: 'deep',
            interval: Duration(days: 1),
            agents: <String>[
              'research_v1',
              'dream_prune_v1',
              'dream_decay_v1',
            ],
          ),
          const DreamLaneSpec(
            id: 'monthly',
            interval: Duration(days: 30),
            agents: <String>['restructure_tree_v1'],
          ),
        ],
      );

  /// The timed lanes, in fire order.
  final List<DreamLaneSpec> lanes;

  /// The agent the off-timer shaking-event path fires
  /// (`memory_specification.md` § 9.4 / § 9.7).
  final String shakingAgent;

  /// The lane with [id], or `null` when no lane carries it.
  DreamLaneSpec? laneById(String id) {
    for (final lane in lanes) {
      if (lane.id == id) {
        return lane;
      }
    }
    return null;
  }
}

/// Fires the dreaming agents on their cadence (`memory_specification.md`
/// § 9.7), one lane — and within a lane, one agent — at a time.
///
/// One [tick] is one heartbeat: every lane whose interval has elapsed since it
/// last fired is *enqueued* (deduped), then the queue is pumped serially. Lanes
/// never run in parallel; a lane that defers (busy background slot) is
/// re-enqueued at the tail and retried on a later tick. The shaking-event path
/// is off the timer: [handleShakingEvent] fires the reconsolidator on demand,
/// routed from memory's `ShakingEvent` stream.
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
    this.throttle,
  }) : schedule = schedule ?? CadenceSchedule.defaults() {
    final start = clock.nowMs();
    for (final lane in this.schedule.lanes) {
      _lastFiredMs[lane.id] = start;
    }
  }

  /// The injected time source (UTC). Tests pass a `MutableTestClock`.
  final Clock clock;

  /// The seam each due agent is fired through.
  final MaintenanceFire fire;

  /// The ordered lane set fired by.
  final CadenceSchedule schedule;

  /// The optional dream LLM-call throttle (part d). `null` ⇒ unthrottled. When
  /// present, an LLM-using agent must acquire a token before it fires; a denied
  /// acquire defers its lane (re-enqueued, like a busy slot) so no dream work is
  /// dropped — only paced.
  final DreamThrottle? throttle;

  /// Per-lane last-fired instant (ms since epoch), seeded at construction and
  /// advanced when a lane is enqueued (so a waiting lane is not re-enqueued on
  /// every heartbeat).
  final Map<String, int> _lastFiredMs = <String, int>{};

  /// The durable serial run queue (lane ids, in-order). Survives across ticks
  /// so a deferred lane retries on a later tick.
  final Queue<String> _laneQueue = Queue<String>();

  /// Per-lane resume cursor: the agent index a mid-pass lane resumes from after
  /// a defer. Absent ⇒ start from the first agent. A lane that defers part-way
  /// (busy slot or spent throttle budget) records the index of the agent that
  /// did *not* run, so the retry continues from there rather than re-firing —
  /// and, for the throttle, re-charging — the agents that already ran this pass.
  /// Cleared when the lane completes a full pass. This is what makes the
  /// throttle pace (not livelock) a lane with more LLM-using agents than its
  /// per-window budget.
  final Map<String, int> _laneResumeIndex = <String, int>{};

  /// Guards the pump so lanes never run in parallel even if [tick] is re-entered
  /// (e.g. a heartbeat firing while a slow lane is still pumping).
  bool _running = false;

  /// Runs one heartbeat: enqueues every due lane (deduped, in lane order),
  /// advancing each enqueued lane's baseline, then pumps the queue serially and
  /// returns the agent ids that actually ran this cycle, in fire order.
  ///
  /// A lane is due when `clock - lastFired >= interval`. Enqueuing advances the
  /// baseline immediately, so a lane awaiting its turn is not re-enqueued on the
  /// next heartbeat; the queue dedupes by id regardless.
  Future<List<String>> tick() async {
    final now = clock.nowMs();
    for (final lane in schedule.lanes) {
      if (!_isDue(lane.id, now)) {
        continue;
      }
      _lastFiredMs[lane.id] = now;
      if (!_laneQueue.contains(lane.id)) {
        _laneQueue.add(lane.id);
      }
    }
    return _pump();
  }

  /// Drains the lane queue one lane — and within a lane, one agent — at a time.
  ///
  /// Re-entrant calls return immediately (the [_running] guard), so a heartbeat
  /// that fires mid-pump never starts a parallel drain. A lane whose agent
  /// defers (busy slot) is re-enqueued at the tail and the pump stops until the
  /// next tick, so the busy slot is never spun on.
  Future<List<String>> _pump() async {
    if (_running) {
      return const <String>[];
    }
    _running = true;
    final ran = <String>[];
    try {
      while (_laneQueue.isNotEmpty) {
        final laneId = _laneQueue.removeFirst();
        final lane = schedule.laneById(laneId);
        if (lane == null) {
          _laneResumeIndex.remove(laneId);
          continue;
        }
        var deferred = false;
        var i = _laneResumeIndex[laneId] ?? 0;
        for (; i < lane.agents.length; i++) {
          final procedureId = lane.agents[i];
          // Part d: an LLM-using agent must acquire a throttle token before it
          // fires. Embedding-only agents are exempt. A denied acquire defers the
          // lane (re-enqueued below) so the paced work is retried, not lost.
          if (throttle != null &&
              !throttle!.isExempt(procedureId) &&
              !throttle!.tryAcquire(laneId, clock.nowMs())) {
            deferred = true;
            break;
          }
          final outcome = await fire(procedureId);
          if (outcome == FireOutcome.deferred) {
            deferred = true;
            break;
          }
          ran.add(procedureId);
        }
        if (deferred) {
          // Resume from the agent that did not run (index [i]) on the retry, so
          // the already-run prefix is neither re-fired nor re-charged.
          _laneResumeIndex[laneId] = i;
          if (!_laneQueue.contains(laneId)) {
            _laneQueue.add(laneId);
          }
          break;
        }
        // A full pass completed: drop the cursor so the lane restarts cleanly
        // on its next due interval.
        _laneResumeIndex.remove(laneId);
      }
    } finally {
      _running = false;
    }
    return ran;
  }

  /// Whether [laneId]'s interval has elapsed since it last fired, as of [nowMs].
  bool _isDue(String laneId, int nowMs) =>
      nowMs - _lastFiredMs[laneId]! >= schedule.laneById(laneId)!.interval.inMilliseconds;

  /// Fires the reconsolidator for a raised `ShakingEvent`
  /// (`memory_specification.md` § 9.4) — the event-driven path, off the timer.
  ///
  /// Production subscribes to memory's event stream and routes each
  /// `ShakingEvent` here; the lane scheduler never fires the reconsolidator.
  Future<void> handleShakingEvent() async {
    await fire(schedule.shakingAgent);
  }
}
