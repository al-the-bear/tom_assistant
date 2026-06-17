// DreamLaneSessions — the per-lane persistent activity history of the dreaming
// subsystem (history-compaction quest, todo 15; memory spec § 9.8; procedure
// spec § 10.5; decisions HC-60…HC-65, supersede HC-57…HC-59).
//
// A dreaming lane is *one long session* that continues whenever the lane is
// fired again: it must remember what it did while dreaming last time. This
// registry holds one [ConversationHistory] per lane (keyed by the lane's
// `procedureId`, the same id the scheduler fires through
// `triggerMaintenance`). Each firing appends one turn — its trigger and the
// run's summary — so the next firing can be fed the accumulated narrative under
// `priorTurns` (and the bounded `compactedSummary` once the lane has folded).
//
// This is the *narrative* complement to the `recentRuns` view the free-time
// scheduler binds (todos 13/14): `recentRuns` is run-bookkeeping over the graph
// ("which runs already touched this source"); the session history is a
// continuous record of what the lane has been doing ("what have I been doing
// while dreaming"). The two answer different questions and are not a second
// source of truth (HC-62).
//
// Reuse, not rebuild (umbrella principle 12; HC-61): the lane's session is a
// plain [ConversationHistory] sized through the same [HistoryConfig] resolver
// the answer lane uses, and it compacts through the same engine-side
// [HistoryCompactor] — there is no dream-specific history machinery. The
// registry is pure (no memory / `dart:io`): persistence to disk so the session
// survives a process restart rides the [toJson] / [restore] codec, mirroring
// the access layer's `SessionHistoriesSnapshot` shape, and is wired durably by
// a later phase (HC-64) exactly as the answer lane's store is.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ConversationHistory, HistoryConfig, HistoryTurn;

import 'history_compactor.dart' show HistoryCompactor;

/// The brain's per-dreaming-lane activity histories — one long, compactable
/// [ConversationHistory] per lane, continued across firings (todo 15).
///
/// Each lane is keyed by its `procedureId`. [laneHistory] gets-or-creates a
/// lane's history, sized through [historyConfig] (the
/// `lane override → defaults → code default` resolver); [peek] reads it without
/// creating one; [recordFiring] appends a firing's turn and folds the lane's
/// own activity history when it crosses its threshold. The registry is pure —
/// the substrate call lives behind the injected [compactor], and durable
/// persistence rides [toJson] / [restore].
final class DreamLaneSessions {
  /// Builds a registry whose lane histories are sized through [historyConfig]
  /// (defaults to the standard sizing for every lane) and compacted through the
  /// optional [compactor].
  ///
  /// [compactor] is genuinely optional — when `null` (the prototype's current
  /// state, mirroring the foreground answer lane whose `sub.llm` compaction seam
  /// is not yet wired, HC-64) a lane's `pending` batch simply keeps growing and
  /// is never folded; nothing is lost because the durable record holds every
  /// firing. When supplied, a lane that crosses its `compactionThreshold` folds
  /// its pending batch into the bounded summary on the next [recordFiring].
  DreamLaneSessions({
    this.historyConfig = const HistoryConfig.standard(),
    HistoryCompactor? compactor,
  }) : _compactor = compactor;

  /// The sizing source for each lane's history — the same parsed `history:`
  /// block the scheduler and the answer lane resolve through, so a
  /// `history.lanes.<dreamLaneId>` override sizes a dream lane's session
  /// independently of the foreground answer lane.
  final HistoryConfig historyConfig;

  final HistoryCompactor? _compactor;

  final Map<String, ConversationHistory> _lanes = <String, ConversationHistory>{};

  /// The lane ids that currently have a session history.
  Iterable<String> get laneIds => _lanes.keys;

  /// The [ConversationHistory] for [laneId], creating an empty one sized for
  /// the lane when it has none yet.
  ///
  /// Sizing is resolved through `historyConfig.sizingFor(laneId)`
  /// (`lane override → defaults → code default`), so each dreaming lane sizes
  /// its own session window and fold threshold independently.
  ConversationHistory laneHistory(String laneId) =>
      _lanes[laneId] ??= ConversationHistory(
        sizing: historyConfig.sizingFor(laneId),
      );

  /// The [ConversationHistory] for [laneId], or `null` when the lane has no
  /// session history yet — the read-only view the scheduler binds from, so a
  /// first-ever firing is byte-stable with the no-session case (no empty
  /// history is created merely by reading).
  ConversationHistory? peek(String laneId) => _lanes[laneId];

  /// Records one firing of [laneId] as a turn in the lane's own session
  /// history, then folds the lane's activity history when it has crossed its
  /// threshold.
  ///
  /// [trigger] is what caused the firing (rendered as the turn's "user"
  /// prompt — e.g. `'dream cycle <runId>'`); [outcome] is what the firing did
  /// (the run's summary, rendered as the turn's "assistant" answer). The append
  /// grows the lane's verbatim window and spills older turns into `pending`
  /// exactly as the answer lane's history does.
  ///
  /// When a [compactor] is wired and the append pushed `pending` to the lane's
  /// `compactionThreshold`, the lane compacts its own history (folds `pending`
  /// into the bounded `compactedSummary`, clears `pending`) — derivation, not
  /// deletion, since the durable record keeps every firing. The compactor never
  /// throws out (it swallows a substrate failure and keeps `pending` for the
  /// next firing), so recording a firing never fails on a compaction problem.
  Future<void> recordFiring(
    String laneId, {
    required String trigger,
    required String outcome,
  }) async {
    final history = laneHistory(laneId);
    history.append(HistoryTurn(userPrompt: trigger, brainAnswer: outcome));
    final compactor = _compactor;
    if (compactor != null && history.needsCompaction) {
      await compactor.compact(history);
    }
  }

  /// The registry as a JSON-encodable map — the durable-persistence codec
  /// (HC-64). Mirrors the access layer's `SessionHistoriesSnapshot` shape: a
  /// `lanes` map of laneId → the lane history's own `toJson`.
  Map<String, Object?> toJson() => <String, Object?>{
        'lanes': <String, Object?>{
          for (final entry in _lanes.entries) entry.key: entry.value.toJson(),
        },
      };

  /// Rehydrates the registry from a [toJson] map, replacing any current lane
  /// histories.
  ///
  /// Tolerant parsing (mirroring `SessionHistoriesSnapshot.fromJson`): a missing
  /// or non-map `lanes` block, or a non-map lane entry, is skipped rather than
  /// failing — a partial or older snapshot still rehydrates what it can. Each
  /// restored history is rebuilt through [ConversationHistory.fromJson], so it
  /// shares no mutable state with the decoded map.
  void restore(Map<String, Object?> json) {
    _lanes.clear();
    final lanes = json['lanes'];
    if (lanes is! Map<String, Object?>) return;
    for (final entry in lanes.entries) {
      final laneJson = entry.value;
      if (laneJson is! Map<String, Object?>) continue;
      _lanes[entry.key] = ConversationHistory.fromJson(laneJson);
    }
  }
}
