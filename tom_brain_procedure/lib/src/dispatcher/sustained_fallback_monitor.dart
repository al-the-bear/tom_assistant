// `SustainedFallbackMonitor` — pushes an `AutomationIdea: revise procedure X`
// onto the `automation_ideas` stack when a procedure version falls back
// repeatedly (Plan step D.31;
// `tom_brain_procedure_specification.md` § 10.4 (PE-6);
// `tom_brain_definition.md` § 6).
//
// ── What def § 6 asks for ───────────────────────────────────────────
//
// "Every fallback emits a fallback event. **Sustained** fallback against a
// specific version emits an `AutomationIdea: revise procedure X` pushed to the
// `automation_ideas` stack." D.30 wired the per-edge `FallbackTried` event;
// D.31 is the *aggregate* signal on top of it: a windowed counter over those
// events, keyed by the failing **(procedure id, version)** pair, that fires one
// `AutomationIdea` the moment the count crosses the sustained threshold.
//
// Keying by `(id, version)` rather than id alone is what def § 6's "against a
// specific version" wording demands: a revision idea is about the version that
// proved unreliable, so two different versions of the same procedure falling
// back are two independent episodes. The failing version is each event's
// `fromVersion` (the version the executor stepped *down from* / surfaced on).
// In the prototype every chain is a singleton (`v1`), so every edge keys to
// `(id, 1)` and the behaviour is identical to id-keying — the version axis is
// wired now so it is correct the moment multiple versions exist (todo #30).
//
// ── Windowing + fire-once-per-episode ───────────────────────────────
//
// For each `(id, version)` the monitor keeps a sliding window of the fallback
// edges seen in the last [window] (timestamped by each `FallbackTried`'s
// own `occurredAt`, so a test drives the window deterministically and a
// replayed historical event windows against its real time). On each event:
//
//   1. append the edge, then prune edges older than `occurredAt - window`;
//   2. if the surviving count is below [threshold], the episode is *re-armed*
//      (a future crossing will fire again) and nothing is pushed;
//   3. otherwise, if this episode has not already fired, push exactly one
//      `AutomationIdea` and mark the episode fired.
//
// This is the "exactly at threshold" contract (Plan D.32): the 3rd edge in a
// 24 h window pushes once; the 4th, 5th, … in the *same* sustained episode do
// not re-push. The episode only re-arms once activity subsides below the
// threshold (old edges age out of the window), so a genuinely fresh burst
// later produces a fresh idea.
//
// ── What this is not ────────────────────────────────────────────────
//
// The monitor does not decide *whether* a failure is a fallback — that is the
// `FallbackExecutor` (D.29), which emits a `FallbackTried` only on the
// four typed run-failure classes. The monitor counts the edges the executor
// already classified; every `FallbackTried` it receives counts. It writes
// only the `AutomationIdea` node + its `automation_ideas` membership; it never
// reads or mutates the failing procedure.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show NodeDraft, Scope, TomBrainMemoryClient;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import 'dispatcher_event.dart' show FallbackTried;
import 'fallback_executor.dart' show FallbackEventSink, FallbackTrigger;

/// The protocol-significant `producer` namespace every dispatcher-side memory
/// write attributes itself under (F.5.1).
///
/// The `Scope.producer` of a write is matched on by the trace stitcher and the
/// run inspector, so the `dispatcher` token is a contract, not a cosmetic
/// label. The monitor is now the only dispatcher writer that touches memory
/// (the run registry became a pure in-memory view at Q-D.26.1), so the prefix
/// lives here beside its single use rather than in `run_registry.dart`.
const String dispatcherScopeProducerPrefix = 'dispatcher';

/// The bootstrap stack that holds candidate procedures to author / revise
/// (memory bootstrap stack #2 — `tom_brain_memory` `bootstrap_stacks_installer`).
const String automationIdeasStackName = 'automation_ideas';

/// The node type a sustained-fallback idea is persisted as (memory bootstrap
/// node type #14 — fields `description` + `motivation`).
const String automationIdeaNodeType = 'AutomationIdea';

/// The number of fallback edges within [defaultSustainedFallbackWindow] that
/// count as *sustained* fallback for one procedure id (Plan D.31: "≥ 3").
const int defaultSustainedFallbackThreshold = 3;

/// The sliding window over which fallback edges are counted (Plan D.31:
/// "within 24 h").
const Duration defaultSustainedFallbackWindow = Duration(hours: 24);

/// Watches the [FallbackTried] stream and pushes an `AutomationIdea`
/// onto `automation_ideas` on sustained fallback for a procedure version
/// (D.31).
///
/// One monitor instance tracks every `(procedure id, version)` pair it sees,
/// each with its own independent sliding window and fire-once-per-episode latch.
/// Wire it to the `FallbackExecutor` either by passing [asSink] as the
/// executor's `FallbackEventSink` (fire-and-forget) or by calling [record]
/// directly (and awaiting the returned id, as the tests do).
final class SustainedFallbackMonitor {
  /// Builds a monitor over the interface-boundary [memory] client (PE-10 — the
  /// monitor never reaches into `tom_brain_memory/lib/src/`). [threshold] and
  /// [window] define what "sustained" means; both default to the Plan D.31
  /// values (≥ 3 within 24 h).
  SustainedFallbackMonitor(
    this.memory, {
    int threshold = defaultSustainedFallbackThreshold,
    Duration window = defaultSustainedFallbackWindow,
  })  : assert(threshold >= 1, 'threshold must be at least 1'),
        assert(window > Duration.zero, 'window must be positive'),
        _threshold = threshold,
        _window = window;

  /// The memory client every write delegates to.
  final TomBrainMemoryClient memory;

  final int _threshold;
  final Duration _window;

  /// Per-`(procedure id, version)` sliding window + fire latch. The version is
  /// the failing `FallbackTried.fromVersion`, so each procedure version is an
  /// independent sustained-fallback episode (def § 6: "against a specific
  /// version").
  final Map<(String, int), _FallbackEpisode> _episodes =
      <(String, int), _FallbackEpisode>{};

  /// The sustained-fallback threshold (edges within [window]) this monitor
  /// fires at.
  int get threshold => _threshold;

  /// The sliding window over which fallback edges are counted.
  Duration get window => _window;

  /// A `FallbackEventSink` that feeds every emitted [FallbackTried] into
  /// [record], discarding the returned id (fire-and-forget).
  ///
  /// This is the wiring the composition root uses to attach the monitor to a
  /// `FallbackExecutor`'s `onFallback`. The executor's sink is synchronous and
  /// `void`, so the async [record] is launched with [unawaited]; callers that
  /// need the pushed node id (tests, future inspectors) call [record] directly.
  FallbackEventSink get asSink => (event) => unawaited(record(event));

  /// Records one fallback [event] against its `(procedure id, version)` sliding
  /// window and, when the window has just crossed the sustained threshold for
  /// the first time this episode, pushes one `AutomationIdea` onto
  /// `automation_ideas`.
  ///
  /// The window is keyed by the failing [FallbackTried.fromVersion], so two
  /// versions of the same procedure accumulate independently (def § 6).
  ///
  /// Returns the persisted idea's [NodeId] when this call fired the push, or
  /// `null` when the window is still below threshold or the episode has
  /// already fired.
  Future<NodeId?> record(FallbackTried event) async {
    final episode = _episodes.putIfAbsent(
      (event.procedureId, event.fromVersion),
      _FallbackEpisode.new,
    );
    final at = event.occurredAt.toUtc();
    episode.edges.add(_FallbackEdge(at, event.trigger));

    // Slide the window forward relative to the newest edge: drop edges that
    // fall outside [window] from this event.
    final cutoff = at.subtract(_window);
    episode.edges.removeWhere((edge) => edge.at.isBefore(cutoff));

    if (episode.edges.length < _threshold) {
      // Activity has subsided below the sustained threshold — re-arm so a
      // genuinely fresh burst later produces a fresh idea.
      episode.fired = false;
      return null;
    }
    if (episode.fired) {
      // Still sustained, but this episode already pushed its idea — the 4th,
      // 5th, … edge in the same burst must not re-push (Plan D.32).
      return null;
    }
    // Latch only after a *confirmed* write (F.3.3). Setting `fired` before the
    // push would, on a failed write, both lose the alert and latch the episode
    // as already-sent so it never retries. Mark fired only once the push
    // succeeds; on failure leave the latch clear so the next edge in the still-
    // sustained window re-attempts, and rethrow so the error is not swallowed.
    try {
      final ideaId = await _pushIdea(
        event.procedureId,
        event.fromVersion,
        episode.edges,
      );
      episode.fired = true;
      return ideaId;
    } catch (_) {
      episode.fired = false;
      rethrow;
    }
  }

  /// Persists the `AutomationIdea` node and pushes it onto `automation_ideas`,
  /// returning the new node id. [version] is the failing procedure version this
  /// episode tracks; [edges] is the current in-window burst, used to build the
  /// motivation's trigger breakdown.
  ///
  /// The `producer` and `idempotencyKey` are both version-scoped so two
  /// versions of the same procedure crossing the threshold produce two distinct
  /// ideas, while a re-delivery of the *same* crossing collapses onto the
  /// original node.
  Future<NodeId> _pushIdea(
    String procedureId,
    int version,
    List<_FallbackEdge> edges,
  ) async {
    final count = edges.length;
    final newestAt = edges.last.at;
    final scope = Scope(
      producer: '$dispatcherScopeProducerPrefix:sustained-fallback:'
          '$procedureId:v$version',
      // The episode fires once; key on the version + triggering edge so a
      // re-delivery of the same crossing collapses to the original node rather
      // than a second.
      idempotencyKey:
          'automation-idea:sustained-fallback:$procedureId:v$version:'
          '${newestAt.toIso8601String()}',
    );
    final ideaId = await memory.persist(
      NodeDraft(
        typeName: automationIdeaNodeType,
        values: <String, Object?>{
          'description': 'revise procedure $procedureId',
          'motivation': _motivation(procedureId, version, count, edges),
        },
      ),
      scope: scope,
    );
    await memory.stacks.push(automationIdeasStackName, ideaId, scope: scope);
    return ideaId;
  }

  /// Human-readable motivation surfaced in an `automation_ideas` peek.
  String _motivation(
    String procedureId,
    int version,
    int count,
    List<_FallbackEdge> edges,
  ) {
    final breakdown = _triggerBreakdown(edges);
    return 'Procedure "$procedureId" v$version fell back $count times within '
        '${_window.inHours}h ($breakdown). Sustained fallback indicates this '
        'version is unreliable; author a revised version.';
  }

  /// A compact `kind×n` breakdown of the in-window triggers, ordered by the
  /// `FallbackTrigger` declaration order for a stable string.
  String _triggerBreakdown(List<_FallbackEdge> edges) {
    final counts = <FallbackTrigger, int>{};
    for (final edge in edges) {
      counts[edge.trigger] = (counts[edge.trigger] ?? 0) + 1;
    }
    final parts = <String>[
      for (final trigger in FallbackTrigger.values)
        if (counts[trigger] != null) '${trigger.failureKind}×${counts[trigger]}',
    ];
    return parts.join(', ');
  }
}

/// One procedure id's sliding window of recent fallback edges plus the latch
/// that makes the idea push fire exactly once per sustained episode.
final class _FallbackEpisode {
  /// The in-window fallback edges, oldest first.
  final List<_FallbackEdge> edges = <_FallbackEdge>[];

  /// Whether this sustained episode has already pushed its `AutomationIdea`.
  /// Reset to `false` once the window count drops below the threshold.
  bool fired = false;
}

/// A single fallback edge as the monitor tracks it: when it occurred and which
/// typed failure class triggered it.
final class _FallbackEdge {
  _FallbackEdge(this.at, this.trigger);

  /// UTC timestamp from the `FallbackTried`'s `occurredAt`.
  final DateTime at;

  /// The typed run-failure class that triggered the fallback.
  final FallbackTrigger trigger;
}
