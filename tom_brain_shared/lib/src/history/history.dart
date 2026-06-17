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
//                               documented defaults. Sized per cognition
//                               *lane* (hub § 22.6b/c); parsed from the
//                               `history:` config block by [HistoryConfig] —
//                               this module carries the value type, the
//                               defaults, and the lane-resolution parser.
//     * `HistoryConfig`       — the parsed `history:` block: a `defaults`
//                               sizing plus per-lane overrides keyed by
//                               laneId, with the lane → defaults → code-default
//                               resolution and the rawCount >= 10 floor
//                               (hub § 22.6c; decisions HC-1 / HC-2).
//     * `ConversationHistory` — the store: append-with-eviction, the
//                               `needsCompaction` flag, and `applyCompaction`
//                               (the success path of the engine-side
//                               compactor, access spec § 21.10).
//
// What this module does NOT do:
//
//   * No substrate call. Compaction is itself an LLM call expressed as a
//     prompt template (hub § 22.4); that orchestration lives in the engine
//     (`tom_brain_procedure`), which reads this store, runs the
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
    show listEquals, mapEquals, textPreview;

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
/// window per cognition *lane*, so a resolved sizing is produced by
/// [HistoryConfig] from the `history:` config block (hub § 22.6b/c); a missing
/// block or knob falls back to these defaults (hub § 22.6, "not an error").
final class HistorySizing {
  /// The hard floor on [rawCount] (decision HC-2; schema `minimum: 10`).
  ///
  /// A raw window below this cannot hold enough recent turns for the brain to
  /// stay coherent across a compaction, so [HistoryConfig] *rejects* a
  /// configured value below it rather than silently clamping.
  static const int rawCountFloor = 10;

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

/// Raised by [HistoryConfig.fromConfigMap] when a configured sizing knob falls
/// below its minimum (hub § 22.6c; decision HC-2).
///
/// The parser fails fast rather than clamping: a below-floor value is almost
/// always a typo or a misunderstanding, and a silently-clamped window hides it.
/// The message names the offending location (`history.defaults` or
/// `history.lanes.<laneId>`), the knob, the offending value, and the minimum,
/// so the operator can fix the config without reading the parser source.
final class HistoryConfigError implements Exception {
  /// The lane whose override carried the bad value, or `null` when the bad
  /// value was in the `defaults` block.
  final String? laneId;

  /// The name of the offending knob (e.g. `'rawCount'`).
  final String knob;

  /// The configured value that failed validation.
  final int value;

  /// The minimum the [knob] must satisfy.
  final int minimum;

  /// Builds an error for a [knob] at [value] below its [minimum], in the
  /// `defaults` block ([laneId] null) or a named lane override.
  const HistoryConfigError({
    required this.laneId,
    required this.knob,
    required this.value,
    required this.minimum,
  });

  /// The config location the bad value came from — `history.defaults` or
  /// `history.lanes.<laneId>`.
  String get where =>
      laneId == null ? 'history.defaults' : 'history.lanes.$laneId';

  @override
  String toString() => 'HistoryConfigError: $where.$knob = $value is below the '
      'minimum of $minimum';
}

/// The canonical laneId of the foreground answer lane — the cognition pipeline
/// that answers an inbound user prompt (hub § 22.6b; "the foreground answer
/// lane(s)").
///
/// The access layer resolves each session's [ConversationHistory] sizing from
/// this lane's entry in the `history:` config block
/// ([HistoryConfig.sizingFor]). Dreaming lanes carry their own ids
/// (`DreamLaneSpec.id`) in the same lane namespace (decision HC-3), so a
/// `history.lanes.foreground` override sizes answers while
/// `history.lanes.<dreamLaneId>` overrides size dream activity independently.
const String foregroundAnswerLaneId = 'foreground';

/// The parsed `history:` config block — a `defaults` sizing plus per-lane
/// overrides keyed by laneId (hub § 22.6b/c; decision HC-1).
///
/// Sizing belongs to the cognition *lane* (the foreground answer lane(s) and
/// each dreaming lane), not to the model, so the brain reads it once from the
/// `history:` block and resolves each lane's sizing through
/// **lane override → defaults → code default**. A lane with no entry inherits
/// [defaults]; a lane entry may override any subset of the four knobs, with the
/// rest inherited from [defaults] (and any still-unset knob from the code
/// default, [HistorySizing.standard]).
///
/// Immutable value object. Parsing is pure (no I/O); the caller supplies the
/// already-decoded `history:` map (or `null` when the block is absent).
final class HistoryConfig {
  /// The sizing applied to every lane that carries no override.
  final HistorySizing defaults;

  /// The per-lane sizing overrides, keyed by laneId. A lane absent from this
  /// map resolves to [defaults] via [sizingFor].
  final Map<String, HistorySizing> lanes;

  /// Builds a config from a resolved [defaults] sizing and a [lanes] override
  /// map (both defaulting to "no customization": the standard sizing and an
  /// empty override map).
  const HistoryConfig({
    this.defaults = const HistorySizing.standard(),
    this.lanes = const <String, HistorySizing>{},
  });

  /// The standard config — code defaults for every lane, no overrides.
  const HistoryConfig.standard() : this();

  /// Parses a `history:` config block into a [HistoryConfig].
  ///
  /// [block] is the already-decoded value of the `history:` key, or `null` when
  /// the block is absent. A `null` (or non-map) block yields
  /// [HistoryConfig.standard] — a missing block is "not an error" (hub § 22.6).
  ///
  /// Resolution per knob is **lane → defaults → code default** (hub § 22.6c):
  /// the `defaults` sub-block is resolved over the code defaults
  /// ([HistorySizing.standard]); each `lanes.<laneId>` entry is resolved over
  /// the already-resolved [defaults]. [rawCount] has a hard floor of
  /// [HistorySizing.rawCountFloor]; the other three knobs must be positive. A
  /// value below its minimum is **rejected** with a [HistoryConfigError] naming
  /// the lane and knob (decision HC-2) — never silently clamped.
  ///
  /// Unknown keys are ignored (consistent with [HistorySizing.fromJson]); the
  /// `history.schema.json` validation (decision HC-16) is the layer that
  /// rejects typos, so the runtime parser stays lenient.
  factory HistoryConfig.fromConfigMap(Map<String, Object?>? block) {
    if (block == null) return const HistoryConfig.standard();

    final defaultsRaw = block['defaults'];
    final defaults = defaultsRaw is Map<String, Object?>
        ? _resolveSizing(defaultsRaw, const HistorySizing.standard(), null)
        : const HistorySizing.standard();

    final lanesRaw = block['lanes'];
    final lanes = <String, HistorySizing>{};
    if (lanesRaw is Map<String, Object?>) {
      for (final entry in lanesRaw.entries) {
        final laneRaw = entry.value;
        if (laneRaw is! Map<String, Object?>) continue;
        lanes[entry.key] = _resolveSizing(laneRaw, defaults, entry.key);
      }
    }

    return HistoryConfig(defaults: defaults, lanes: Map.unmodifiable(lanes));
  }

  /// Resolves one sizing block [raw] over a [fallback] sizing, validating each
  /// knob against its minimum. [laneId] names the lane for error reporting
  /// (`null` for the `defaults` block).
  static HistorySizing _resolveSizing(
    Map<String, Object?> raw,
    HistorySizing fallback,
    String? laneId,
  ) {
    final rawCount =
        (raw['rawCount'] as num?)?.toInt() ?? fallback.rawCount;
    final compactionThreshold =
        (raw['compactionThreshold'] as num?)?.toInt() ??
            fallback.compactionThreshold;
    final maxCompactedTokens =
        (raw['maxCompactedTokens'] as num?)?.toInt() ??
            fallback.maxCompactedTokens;
    final maxCompactedChars =
        (raw['maxCompactedChars'] as num?)?.toInt() ??
            fallback.maxCompactedChars;

    _requireMin(laneId, 'rawCount', rawCount, HistorySizing.rawCountFloor);
    _requireMin(laneId, 'compactionThreshold', compactionThreshold, 1);
    _requireMin(laneId, 'maxCompactedTokens', maxCompactedTokens, 1);
    _requireMin(laneId, 'maxCompactedChars', maxCompactedChars, 1);

    return HistorySizing(
      rawCount: rawCount,
      compactionThreshold: compactionThreshold,
      maxCompactedTokens: maxCompactedTokens,
      maxCompactedChars: maxCompactedChars,
    );
  }

  /// Throws a [HistoryConfigError] when [value] is below [minimum].
  static void _requireMin(String? laneId, String knob, int value, int minimum) {
    if (value < minimum) {
      throw HistoryConfigError(
        laneId: laneId,
        knob: knob,
        value: value,
        minimum: minimum,
      );
    }
  }

  /// The lane-aware sizing resolution for [laneId]: its override when present,
  /// else [defaults] (which already carries the code default when the block had
  /// no `defaults`). So the full resolution is
  /// `lane override ?? defaults ?? HistorySizing.standard()` — the
  /// `historySizingFor` resolver the access/session path consumes
  /// (history-compaction quest, todo #6).
  HistorySizing sizingFor(String laneId) => lanes[laneId] ?? defaults;

  @override
  bool operator ==(Object other) =>
      other is HistoryConfig &&
      other.defaults == defaults &&
      mapEquals(other.lanes, lanes);

  @override
  int get hashCode => Object.hash(
        defaults,
        Object.hashAll(
          lanes.entries
              .map((e) => Object.hash(e.key, e.value))
              .toList(growable: false)
            ..sort(),
        ),
      );

  @override
  String toString() =>
      'HistoryConfig(defaults: $defaults, lanes: ${lanes.keys.toList()})';
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
