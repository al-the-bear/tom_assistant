// HistoryCompactor — the engine-side half of conversation-history compaction
// (Plan step G.21; hub spec § 22.4, § 22.10; access spec § 21.10).
//
// Compaction is "derivation, not deletion": when a session's `pending` batch
// reaches the threshold (`ConversationHistory.needsCompaction`), the engine
// folds that batch into the bounded `compactedSummary` via a substrate call
// expressed as the `compact_history_v1` prompt template, then clears
// `pending` — the verbatim turns survive in the durable record (hub § 22.3).
//
// Access spec § 21.10 places this in the engine, not the access layer: "the
// compaction call and prompt assembly live in the engine." This file owns the
// orchestration; the substrate completion itself is a single injectable seam
// ([HistoryCompactionSubstrate]) so step G.21 can stub it and step G.23 can
// route it through `sub.llm` under the run's anchor (PE-7) + budget (PE-8) —
// the invariants are honoured at that seam, unchanged here.
//
// The template scaffolds inject exactly two placeholders (hub § 22.4):
//   ${history.compacted} — the current summary (empty on first compaction),
//   ${history.batch}     — the pending batch being folded in.
// The anchor is **not** a template placeholder: it is applied by the substrate
// when the call is made (hub § 22.4, "runs under the same anchor"), so the
// stubbed seam here needs no role resolution.

import '../config/history_policy.dart' show defaultHistoryCompactionTemplate;
import '../config/prompt_template_config.dart';
import '../primitives_native/trail_note.dart';

import 'package:tom_core_agentic/tom_core_agentic.dart' show PlaceholderResolver;

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ConversationHistory, HistorySizing, HistoryTurn;

/// The note category recorded when a compaction run fails (hub § 22.10): the
/// prior summary is kept and `pending` is not cleared — never silent data
/// loss.
const String historyCompactionFailedCategory = 'history.compaction.failed';

/// The note category recorded when an over-long summary is hard-truncated to
/// the char bound after the single re-run (hub § 22.4 / § 22.10).
const String historyCompactionTruncatedCategory =
    'history.compaction.truncated';

/// The default compaction prompt template type (hub § 22.4), re-exported from
/// the canonical config-layer constant ([defaultHistoryCompactionTemplate]) so
/// the compactor and the prompt template's `history.compactionTemplate` flag
/// (Plan step G.25, `HistoryPolicy.compactionTemplate`) share one source of
/// truth. A template's `history.compactionTemplate` overrides this per type.
const String defaultCompactionTemplate = defaultHistoryCompactionTemplate;

/// The assembled scaffolds handed to the [HistoryCompactionSubstrate] — the
/// `compact_history_v1` template with its `${history.compacted}` /
/// `${history.batch}` placeholders already resolved.
final class HistoryCompactionPrompt {
  /// The resolved system scaffold.
  final String system;

  /// The resolved user scaffold (on the re-run, carrying the tightening
  /// directive appended after the template body).
  final String user;

  /// Whether this is the single tightened re-run issued after an over-long
  /// first result (hub § 22.4). A real substrate may use it to lower the
  /// length budget; the stub seam asserts on it.
  final bool tightened;

  /// Builds an assembled compaction prompt.
  const HistoryCompactionPrompt({
    required this.system,
    required this.user,
    required this.tightened,
  });
}

/// The substrate completion the compactor issues once the prompt is assembled.
///
/// Production wiring (Plan step G.23, `call_llm_v1`) routes this through
/// `sub.llm` under the run's anchor + budget; step G.21 tests stub it. It
/// receives the resolved scaffolds and returns the model's rewritten summary
/// text. **Throwing** signals a failed run (→ [historyCompactionFailedCategory]).
typedef HistoryCompactionSubstrate = Future<String> Function(
  HistoryCompactionPrompt prompt,
);

/// The terminal state of one [HistoryCompactor.compact] call.
enum HistoryCompactionOutcome {
  /// The summary was rewritten within the length bound and `pending` cleared.
  compacted,

  /// The summary was still over-long after the single re-run and was
  /// hard-truncated to the char bound; `pending` cleared, a note recorded.
  truncated,

  /// The substrate call failed; the prior summary and `pending` are kept for
  /// retry next turn, a note recorded.
  failed,
}

/// The result of a compaction run — its [outcome], the resulting [summary]
/// (the new `compactedSummary`, or the unchanged prior one on failure), and
/// the [note] recorded for the non-clean outcomes.
final class HistoryCompactionResult {
  /// How the run ended.
  final HistoryCompactionOutcome outcome;

  /// The post-state compacted summary. On [HistoryCompactionOutcome.failed]
  /// this is the unchanged prior summary.
  final String summary;

  /// The trail note recorded for a `truncated` / `failed` outcome, or `null`
  /// for a clean `compacted` run.
  final TrailNote? note;

  const HistoryCompactionResult._(this.outcome, this.summary, this.note);

  /// Whether the run cleared `pending` (true for every outcome except
  /// [HistoryCompactionOutcome.failed]).
  bool get pendingCleared => outcome != HistoryCompactionOutcome.failed;
}

/// Folds a [ConversationHistory]'s `pending` batch into its `compactedSummary`
/// via the `compact_history_v1` substrate call (hub § 22.4).
final class HistoryCompactor {
  /// Loads the compaction prompt template by type.
  final PromptTemplateStore templates;

  /// The substrate completion seam (stubbed in tests, `sub.llm` in production).
  final HistoryCompactionSubstrate substrate;

  /// The prompt template type to load (defaults to [defaultCompactionTemplate]).
  final String templateType;

  final TrailSink? _onNote;
  final DateTime Function() _now;

  /// Builds a compactor over a [templates] store and a [substrate] seam.
  ///
  /// [onNote], when supplied, receives the `history.compaction.failed` /
  /// `…truncated` notes (hub § 22.10). [now] defaults to [DateTime.now]; tests
  /// pass a fixed clock to assert a deterministic [TrailNote.recordedAt].
  HistoryCompactor({
    required this.templates,
    required this.substrate,
    TrailSink? onNote,
    this.templateType = defaultCompactionTemplate,
    DateTime Function()? now,
  })  : _onNote = onNote,
        _now = now ?? DateTime.now;

  /// Compacts [history]: folds its `pending` batch into `compactedSummary`.
  ///
  /// On success the rewritten summary replaces the old one and `pending`
  /// clears ([ConversationHistory.applyCompaction]). An over-long result is
  /// re-run once with a tightened instruction, then hard-truncated to
  /// [HistorySizing.maxCompactedChars] with a note. A failed substrate call
  /// keeps the prior summary and `pending` for retry, with a note — never
  /// silent data loss (hub § 22.10).
  Future<HistoryCompactionResult> compact(ConversationHistory history) async {
    final batch = history.pending;
    final template = await templates.load(templateType);

    final first = await _run(template, history, batch, tightened: false);
    if (first == null) {
      return _failed(history);
    }
    if (!_overLong(first, history.sizing)) {
      history.applyCompaction(first);
      return HistoryCompactionResult._(
        HistoryCompactionOutcome.compacted,
        first,
        null,
      );
    }

    // Over-long: one tightened re-run, then hard-truncate to the char bound.
    final second = await _run(template, history, batch, tightened: true);
    if (second == null) {
      return _failed(history);
    }
    if (!_overLong(second, history.sizing)) {
      history.applyCompaction(second);
      return HistoryCompactionResult._(
        HistoryCompactionOutcome.compacted,
        second,
        null,
      );
    }

    final truncated = second.substring(0, history.sizing.maxCompactedChars);
    final note = _note(historyCompactionTruncatedCategory, <String, Object?>{
      'bound': history.sizing.maxCompactedChars,
      'producedChars': second.length,
    });
    history.applyCompaction(truncated);
    return HistoryCompactionResult._(
      HistoryCompactionOutcome.truncated,
      truncated,
      note,
    );
  }

  /// Assembles the prompt and issues one substrate call, returning the model
  /// text, or `null` when the call threw (a failed run).
  Future<String?> _run(
    PromptTemplateConfig template,
    ConversationHistory history,
    List<HistoryTurn> batch, {
    required bool tightened,
  }) async {
    final prompt = await _assemble(template, history, batch, tightened: tightened);
    try {
      return await substrate(prompt);
    } on Object {
      return null;
    }
  }

  /// Binds the two history placeholders and resolves the template scaffolds.
  Future<HistoryCompactionPrompt> _assemble(
    PromptTemplateConfig template,
    ConversationHistory history,
    List<HistoryTurn> batch, {
    required bool tightened,
  }) async {
    final resolver = PlaceholderResolver()
      ..stack.bindAll(<String, Object?>{
        'history.compacted': history.compactedSummary,
        'history.batch': _renderTurns(batch),
      });
    final system = await resolver.resolve(template.system);
    var user = await resolver.resolve(template.user);
    if (tightened) {
      user = '$user\n\n$_tightenDirective';
    }
    return HistoryCompactionPrompt(
      system: system,
      user: user,
      tightened: tightened,
    );
  }

  HistoryCompactionResult _failed(ConversationHistory history) {
    final note = _note(historyCompactionFailedCategory, <String, Object?>{
      'pendingKept': history.pending.length,
    });
    // Derivation, not deletion: leave the store untouched so the batch and the
    // prior summary are retried next turn.
    return HistoryCompactionResult._(
      HistoryCompactionOutcome.failed,
      history.compactedSummary,
      note,
    );
  }

  TrailNote _note(String category, Map<String, Object?> payload) {
    final note = TrailNote(
      category: category,
      payload: payload,
      recordedAt: _now(),
    );
    _onNote?.call(note);
    return note;
  }

  /// Whether [text] overruns its length bound — the hard char bound or the
  /// advisory token estimate (≈ 4 chars/token), hub § 22.4. Truncation, when
  /// it comes, is always by the char bound (deterministic).
  static bool _overLong(String text, HistorySizing sizing) =>
      text.length > sizing.maxCompactedChars ||
      _estimateTokens(text) > sizing.maxCompactedTokens;

  /// A coarse token estimate (~4 characters per token) used only to decide
  /// whether to issue the tightened re-run; the enforceable bound is chars.
  static int _estimateTokens(String text) => (text.length / 4).ceil();

  /// Renders a batch of turns into the `${history.batch}` text the model folds
  /// in — faithful on both sides (user / assistant / optional tool round).
  static String _renderTurns(List<HistoryTurn> turns) {
    final out = StringBuffer();
    for (final turn in turns) {
      out.writeln('User: ${turn.userPrompt}');
      if (turn.toolRound != null) {
        out.writeln('Tools: ${turn.toolRound}');
      }
      out.writeln('Assistant: ${turn.brainAnswer}');
    }
    return out.toString().trimRight();
  }

  static const String _tightenDirective =
      'Your previous summary was too long. Rewrite it more concisely so it '
      'fits well within the length budget while preserving the key facts.';
}
