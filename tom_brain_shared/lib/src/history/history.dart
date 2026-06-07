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
//   * No persistence. Turns are persisted as memory nodes by the access
//     layer's `SessionManager` (hub § 22.3, "persisted as memory nodes");
//     the in-value `record` is the faithful representation of that durable
//     trail the pure store can hold.

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
