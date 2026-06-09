// Conversation-history value/store module (Plan step G.21; hub spec § 22.3;
// access spec § 21.3).
//
// What this module owns:
//
//   The brain's own running record of a conversation — the local half of the
//   two history sources (hub § 22.0): a verbatim raw window of the newest
//   turns, a `pending` batch of older turns accumulated behind it, and a
//   bounded `compactedSummary` of everything older still. Plus a durable,
//   append-only `record` of every turn ever appended, so compaction can be
//   **derivation, not deletion** (umbrella overview, Hard principle 6).
//
//     * `HistoryTurn`         — one exchange: the user prompt, the brain's
//                               answer, and an optional tool-call/tool-result
//                               round between them (so replay is faithful on
//                               both sides). An immutable value.
//     * `HistorySizing`       — the four window/summary knobs with their
//                               documented defaults. Sized off the model's
//                               context budget (hub § 22.6b); parsed from the
//                               model config at a later step — this module
//                               carries only the value type + defaults.
//     * `ConversationHistory` — the store: append-with-eviction, the
//                               `needsCompaction` flag, and `applyCompaction`
//                               (the success path of the engine-side
//                               compactor, access spec § 21.10).
//
// What this module does NOT do:
//
//   * No substrate call. Compaction is itself an LLM call expressed as a
//     prompt template (hub § 22.4); that orchestration lives in the engine
//     (`tom_brain_procedure_prototype`), which reads this store, runs the
//     call, and hands the rewritten summary back via [applyCompaction]. The
//     shared layer carries no I/O (A.9 dependency discipline).
//   * No file I/O. This module stays pure (A.9 dependency discipline): it
//     offers `toJson` / `fromJson` as a structural codec, but the actual
//     persistence — writing a session's history to disk so it survives a
//     process restart ("nothing is ever lost") — is the access layer's
//     `JsonFileHistoryStore` (access spec § 21.10). Turns are *also* persisted
//     as memory nodes by the answer procedure (hub § 22.3); the two are
//     complementary (the JSON store rehydrates the live session window, the
//     memory nodes feed recall).

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show listEquals, textPreview;

/// One exchange in a conversation history: the user prompt, the brain's
/// answer, and — when present — the tool-call/tool-result round that ran
/// between them (hub § 22.3).
///
/// Immutable value object. All three parts are kept verbatim so replaying the
/// history into a chat model is faithful on both sides. A turn body may be
/// empty (e.g. a client-tool follow-up carries an empty user prompt,
/// hub § 22.8) — the store does not police content; it records what happened.
final class HistoryTurn {
  /// The user's prompt for this turn. May be empty.
  final String userPrompt;

  /// The brain's answer for this turn. May be empty.
  final String brainAnswer;

  /// The tool-call/tool-result round that ran between prompt and answer, or
  /// `null` when the turn involved no tools.
  final String? toolRound;

  /// Builds an immutable turn from its [userPrompt], [brainAnswer], and an
  /// optional [toolRound].
  const HistoryTurn({
    required this.userPrompt,
    required this.brainAnswer,
    this.toolRound,
  });

  /// Rebuilds a turn from its [toJson] map. A missing prompt/answer reads as
  /// empty (a turn body is allowed to be empty, hub § 22.8); a missing or null
  /// `tool` key reads as no tool round, so the codec round-trips
  /// `toolRound == null` faithfully.
  factory HistoryTurn.fromJson(Map<String, Object?> json) => HistoryTurn(
        userPrompt: (json['user'] as String?) ?? '',
        brainAnswer: (json['answer'] as String?) ?? '',
        toolRound: json['tool'] as String?,
      );

  /// The turn as a JSON-encodable map. The optional `tool` key is omitted when
  /// there was no tool round, so the encoding distinguishes "no tools ran" from
  /// "an empty tool round ran".
  Map<String, Object?> toJson() => <String, Object?>{
        'user': userPrompt,
        'answer': brainAnswer,
        if (toolRound != null) 'tool': toolRound,
      };

  @override
  bool operator ==(Object other) =>
      other is HistoryTurn &&
      other.userPrompt == userPrompt &&
      other.brainAnswer == brainAnswer &&
      other.toolRound == toolRound;

  @override
  int get hashCode => Object.hash(userPrompt, brainAnswer, toolRound);

  @override
  String toString() => 'HistoryTurn(userPrompt: '
      '${textPreview(userPrompt, limit: 32)}, brainAnswer: '
      '${textPreview(brainAnswer, limit: 32)}'
      '${toolRound == null ? '' : ', tool: ${textPreview(toolRound!, limit: 24)}'})';
}

/// The four sizing knobs that shape a [ConversationHistory] (hub § 22.6b).
///
/// Immutable value object with the documented defaults. The brain scales the
/// window with the model's context budget, so these are parsed from the model
/// config (`models/<id>.yaml`) at a later step; a missing block falls back to
/// these defaults (hub § 22.6, "not an error").
final class HistorySizing {
  /// The number of newest turns kept verbatim in the raw window (default 10).
  final int rawCount;

  /// The number of pending turns that triggers the next compaction
  /// (default 40).
  final int compactionThreshold;

  /// The advisory token bound on the compacted summary (default 1024).
  final int maxCompactedTokens;

  /// The hard character bound the compacted summary is truncated to
  /// (default 6000).
  final int maxCompactedChars;

  /// Builds a sizing. Every knob defaults to its documented value and must be
  /// positive — a non-positive window or bound could not hold a conversation.
  const HistorySizing({
    this.rawCount = 10,
    this.compactionThreshold = 40,
    this.maxCompactedTokens = 1024,
    this.maxCompactedChars = 6000,
  })  : assert(rawCount > 0, 'rawCount must be positive'),
        assert(compactionThreshold > 0, 'compactionThreshold must be positive'),
        assert(maxCompactedTokens > 0, 'maxCompactedTokens must be positive'),
        assert(maxCompactedChars > 0, 'maxCompactedChars must be positive');

  /// The standard sizing — every knob at its documented default.
  const HistorySizing.standard() : this();

  /// Rebuilds a sizing from its [toJson] map. A missing or non-numeric knob
  /// falls back to its documented default (hub § 22.6, "not an error"), so an
  /// old or partial persisted sizing still rehydrates.
  factory HistorySizing.fromJson(Map<String, Object?> json) => HistorySizing(
        rawCount: (json['rawCount'] as num?)?.toInt() ?? 10,
        compactionThreshold:
            (json['compactionThreshold'] as num?)?.toInt() ?? 40,
        maxCompactedTokens:
            (json['maxCompactedTokens'] as num?)?.toInt() ?? 1024,
        maxCompactedChars: (json['maxCompactedChars'] as num?)?.toInt() ?? 6000,
      );

  /// The sizing as a JSON-encodable map.
  Map<String, Object?> toJson() => <String, Object?>{
        'rawCount': rawCount,
        'compactionThreshold': compactionThreshold,
        'maxCompactedTokens': maxCompactedTokens,
        'maxCompactedChars': maxCompactedChars,
      };

  @override
  bool operator ==(Object other) =>
      other is HistorySizing &&
      other.rawCount == rawCount &&
      other.compactionThreshold == compactionThreshold &&
      other.maxCompactedTokens == maxCompactedTokens &&
      other.maxCompactedChars == maxCompactedChars;

  @override
  int get hashCode => Object.hash(
        rawCount,
        compactionThreshold,
        maxCompactedTokens,
        maxCompactedChars,
      );

  @override
  String toString() => 'HistorySizing(rawCount: $rawCount, '
      'compactionThreshold: $compactionThreshold, '
      'maxCompactedTokens: $maxCompactedTokens, '
      'maxCompactedChars: $maxCompactedChars)';
}

/// The brain's running record of one conversation — the local history of a
/// session (hub § 22.3).
///
/// A mutable store (one per session / per global default session), not a flow
/// value: it accumulates state across turns. Three working views plus a
/// durable record:
///
///   * [rawWindow]       — the newest [HistorySizing.rawCount] turns, verbatim.
///   * [pending]         — older turns accumulated behind the window, up to
///                         [HistorySizing.compactionThreshold].
///   * [compactedSummary]— one bounded text covering everything older than
///                         [pending].
///   * [durableRecord]   — every turn ever appended, append-only. Compaction
///                         folds [pending] into [compactedSummary] but never
///                         removes a turn from here (Hard principle 6).
///
/// [append] grows the window and evicts the oldest into [pending] when the
/// window overflows. When [needsCompaction] flips, the engine-side compactor
/// (access spec § 21.10) runs the substrate call and calls [applyCompaction]
/// with the rewritten summary; on a failed run it calls neither, so the prior
/// summary and the pending batch are retried next turn (hub § 22.10).
final class ConversationHistory {
  /// The sizing knobs governing this history.
  final HistorySizing sizing;

  final List<HistoryTurn> _rawWindow = <HistoryTurn>[];
  final List<HistoryTurn> _pending = <HistoryTurn>[];
  final List<HistoryTurn> _record = <HistoryTurn>[];
  String _compactedSummary;

  /// Builds a history with the given [sizing] (defaults to the standard
  /// sizing) and an initial [compactedSummary] (empty for a fresh session).
  ConversationHistory({
    this.sizing = const HistorySizing.standard(),
    String compactedSummary = '',
  }) : _compactedSummary = compactedSummary;

  /// Rehydrates a history from a snapshot of its four working views.
  ///
  /// The restart seam (access spec § 21.10; hub Hard principle 6): a persisted
  /// session is rebuilt from its [sizing], its [compactedSummary], and its
  /// three turn views ([rawWindow], [pending], [durableRecord]). Each list is
  /// copied into the store's own backing list, so the restored history shares
  /// no mutable state with its source — a later append on either side cannot
  /// leak into the other. [HistoryTurn] is immutable, so copying the list
  /// references is a full deep copy of the turn data.
  ConversationHistory.restore({
    required this.sizing,
    required String compactedSummary,
    required List<HistoryTurn> rawWindow,
    required List<HistoryTurn> pending,
    required List<HistoryTurn> durableRecord,
  }) : _compactedSummary = compactedSummary {
    _rawWindow.addAll(rawWindow);
    _pending.addAll(pending);
    _record.addAll(durableRecord);
  }

  /// Rehydrates a history from its [toJson] map — the on-disk restart seam.
  ///
  /// Delegates to [ConversationHistory.restore], so the rebuilt store shares no
  /// mutable state with the decoded lists. A missing `sizing` block falls back
  /// to the standard sizing; missing turn lists read as empty; a missing
  /// summary reads as empty (a fresh session).
  factory ConversationHistory.fromJson(Map<String, Object?> json) {
    final sizingJson = json['sizing'];
    return ConversationHistory.restore(
      sizing: sizingJson is Map<String, Object?>
          ? HistorySizing.fromJson(sizingJson)
          : const HistorySizing.standard(),
      compactedSummary: (json['compactedSummary'] as String?) ?? '',
      rawWindow: _turnsFromJson(json['rawWindow']),
      pending: _turnsFromJson(json['pending']),
      durableRecord: _turnsFromJson(json['durableRecord']),
    );
  }

  /// Decodes a JSON list of turn maps; a missing or non-list value reads as an
  /// empty list.
  static List<HistoryTurn> _turnsFromJson(Object? value) {
    if (value is! List) return <HistoryTurn>[];
    return value
        .whereType<Map<String, Object?>>()
        .map(HistoryTurn.fromJson)
        .toList();
  }

  /// The history as a JSON-encodable map covering all four working views.
  ///
  /// The durable record is included in full so the "nothing is ever lost"
  /// invariant (Hard principle 6) survives a process restart, not just the
  /// live window.
  Map<String, Object?> toJson() => <String, Object?>{
        'sizing': sizing.toJson(),
        'compactedSummary': _compactedSummary,
        'rawWindow': _rawWindow.map((t) => t.toJson()).toList(),
        'pending': _pending.map((t) => t.toJson()).toList(),
        'durableRecord': _record.map((t) => t.toJson()).toList(),
      };

  /// The newest [HistorySizing.rawCount] turns, kept verbatim. Unmodifiable.
  List<HistoryTurn> get rawWindow => List.unmodifiable(_rawWindow);

  /// The older turns accumulated behind the raw window, awaiting compaction.
  /// Unmodifiable.
  List<HistoryTurn> get pending => List.unmodifiable(_pending);

  /// Every turn ever appended, in order — the durable trail that makes
  /// compaction derivation rather than deletion. Unmodifiable.
  List<HistoryTurn> get durableRecord => List.unmodifiable(_record);

  /// The bounded synthesized summary of everything older than [pending].
  String get compactedSummary => _compactedSummary;

  /// Whether [pending] has reached the compaction threshold and the
  /// engine-side compactor should run (hub § 22.3).
  bool get needsCompaction => _pending.length >= sizing.compactionThreshold;

  /// Appends [turn] to the history.
  ///
  /// The turn joins the durable record and the raw window; if the window now
  /// exceeds [HistorySizing.rawCount], the oldest turns spill into [pending]
  /// (in chronological order) so the window holds exactly the newest
  /// `rawCount` turns.
  void append(HistoryTurn turn) {
    _record.add(turn);
    _rawWindow.add(turn);
    while (_rawWindow.length > sizing.rawCount) {
      _pending.add(_rawWindow.removeAt(0));
    }
  }

  /// Back-fills the brain's [answer] into the most-recently-appended turn.
  ///
  /// A turn is appended the moment a prompt is admitted, before the answer
  /// exists, so its `brainAnswer` is initially empty (access spec § 7.2 — the
  /// "doesn't remember its own reply" defect this guards against: a turn left
  /// answer-less would render into the *next* prompt's history as a question
  /// with a blank reply). Once the run yields its answer the dispatcher calls
  /// this to replace that turn with an immutable copy carrying [answer], in
  /// every working view that still holds it — the durable record, the raw
  /// window, or [pending] if it has since spilled there.
  ///
  /// No-op when the history is empty or the last turn already carries a
  /// (non-empty) answer, so a re-delivered run never double-writes
  /// (idempotent). [HistoryTurn] is immutable, so this swaps the reference
  /// rather than mutating in place.
  void amendLastTurnAnswer(String answer) {
    if (_record.isEmpty) return;
    final last = _record.last;
    if (last.brainAnswer.isNotEmpty) return;
    final amended = HistoryTurn(
      userPrompt: last.userPrompt,
      brainAnswer: answer,
      toolRound: last.toolRound,
    );
    _record[_record.length - 1] = amended;
    _replaceLastIdentical(_rawWindow, last, amended);
    _replaceLastIdentical(_pending, last, amended);
  }

  /// Replaces the last reference-identical occurrence of [target] in [list]
  /// with [replacement]. The appended turn lives in exactly one of the working
  /// views (raw window, or pending once evicted); scanning from the end finds
  /// it without disturbing an earlier equal-valued turn.
  static void _replaceLastIdentical(
    List<HistoryTurn> list,
    HistoryTurn target,
    HistoryTurn replacement,
  ) {
    for (var i = list.length - 1; i >= 0; i--) {
      if (identical(list[i], target)) {
        list[i] = replacement;
        return;
      }
    }
  }

  /// Replaces [compactedSummary] with [summary] and clears [pending] — the
  /// success path of compaction.
  ///
  /// Derivation, not deletion (Hard principle 6): the raw window and the
  /// durable record are untouched; only the working `pending` batch (now
  /// folded into the summary) is cleared. The engine calls this only after a
  /// successful compaction run; on failure it leaves the store untouched so
  /// the batch is retried next turn (hub § 22.10).
  void applyCompaction(String summary) {
    _compactedSummary = summary;
    _pending.clear();
  }

  @override
  String toString() => 'ConversationHistory(raw: ${_rawWindow.length}, '
      'pending: ${_pending.length}, record: ${_record.length}, '
      'summary: ${textPreview(_compactedSummary, limit: 32)})';
}

/// Structural equality over two histories' working + durable state — a test
/// and diagnostics helper (the store itself uses reference identity).
bool conversationHistoriesEqual(ConversationHistory a, ConversationHistory b) =>
    a.sizing == b.sizing &&
    a.compactedSummary == b.compactedSummary &&
    listEquals(a.rawWindow, b.rawWindow) &&
    listEquals(a.pending, b.pending) &&
    listEquals(a.durableRecord, b.durableRecord);
