// Human-readable markdown mirror of conversation histories (access spec
// § 21.10; request: "make the history readable").
//
// The durable backing for histories is the opaque `histories.json` snapshot
// ([JsonFileHistoryStore]) — round-trippable, but not something an operator
// reads. This module renders the *same* histories into readable markdown,
// organised in per-principal / per-session subfolders, with the raw turns and
// the compacted memory in separate files (the two halves a reader cares about):
//
//   <root>/<principal>/<channel>/global.raw.md      — every "all prompts" turn
//   <root>/<principal>/<channel>/global.memory.md   — its compacted summary
//   <root>/<principal>/<channel>/sessions/<id>.raw.md
//   <root>/<principal>/<channel>/sessions/<id>.memory.md
//
// It is a *mirror*, never the source of truth: the JSON snapshot remains the
// restart seam (it round-trips; markdown does not). So a write failure here is
// harmless — the conversation is already durable in JSON. The renderers are
// pure (no I/O) so they are trivially testable; only the directory sink touches
// the filesystem.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ConversationHistory, HistoryTurn;

/// Renders the raw turns of [history] — its full durable record — as readable
/// markdown under [title].
///
/// Every turn ever appended is shown (nothing is lost, Hard principle 6),
/// numbered, with the user prompt, the brain answer, and the tool round when one
/// ran. A turn whose answer has not been back-filled yet is marked rather than
/// shown blank, so a reader can tell "no answer yet" from "answered with
/// nothing".
String renderConversationRaw(
  ConversationHistory history, {
  required String title,
}) {
  final turns = history.durableRecord;
  final buffer = StringBuffer()
    ..writeln('# $title')
    ..writeln();
  if (turns.isEmpty) {
    buffer.writeln('_No turns recorded yet._');
    return buffer.toString();
  }
  buffer
    ..writeln('_${turns.length} turn(s) in the durable record._')
    ..writeln();
  for (var i = 0; i < turns.length; i++) {
    final HistoryTurn turn = turns[i];
    buffer
      ..writeln('## Turn ${i + 1}')
      ..writeln()
      ..writeln('**User:**')
      ..writeln()
      ..writeln(turn.userPrompt.isEmpty ? '_(empty prompt)_' : turn.userPrompt)
      ..writeln();
    if (turn.toolRound != null) {
      buffer
        ..writeln('**Tools:**')
        ..writeln()
        ..writeln('```')
        ..writeln(turn.toolRound)
        ..writeln('```')
        ..writeln();
    }
    buffer
      ..writeln('**Brain:**')
      ..writeln()
      ..writeln(turn.brainAnswer.isEmpty
          ? '_(no answer recorded yet)_'
          : turn.brainAnswer)
      ..writeln();
  }
  return buffer.toString();
}

/// Renders the compacted memory of [history] — its summary plus how many turns
/// are still pending compaction — as readable markdown under [title].
String renderConversationMemory(
  ConversationHistory history, {
  required String title,
}) {
  final summary = history.compactedSummary;
  final buffer = StringBuffer()
    ..writeln('# $title — compacted memory')
    ..writeln()
    ..writeln('_${history.pending.length} turn(s) pending compaction._')
    ..writeln();
  buffer.writeln(summary.isEmpty ? '_No compacted memory yet._' : summary);
  return buffer.toString();
}

/// One conversation to mirror to disk: where it lives ([pathSegments] — the
/// folder chain then the file stem) plus the [history] to render under [title].
///
/// Immutable carrier produced by the session manager from its two history
/// stores and consumed by a [HistoryMarkdownSink].
final class HistoryMarkdownRecord {
  /// The folder chain ending in the file stem, e.g.
  /// `['owner', 'telegram', 'global']` or
  /// `['owner', 'telegram', 'sessions', '<id>']`. Each segment is sanitised by
  /// the sink before it touches the filesystem.
  final List<String> pathSegments;

  /// The human-readable heading rendered at the top of each file.
  final String title;

  /// The conversation to render.
  final ConversationHistory history;

  /// Builds an immutable record.
  const HistoryMarkdownRecord({
    required this.pathSegments,
    required this.title,
    required this.history,
  });
}

/// Writes readable markdown mirrors of conversation histories.
abstract interface class HistoryMarkdownSink {
  /// Writes the raw-turns and compacted-memory file for each of [records].
  void write(Iterable<HistoryMarkdownRecord> records);
}

/// A [HistoryMarkdownSink] that writes nothing — the default when no readable
/// directory is configured (the markdown mirror is opt-in; the JSON snapshot is
/// the source of truth regardless).
final class NullHistoryMarkdownSink implements HistoryMarkdownSink {
  /// Builds the no-op sink.
  const NullHistoryMarkdownSink();

  @override
  void write(Iterable<HistoryMarkdownRecord> records) {}
}

/// A [HistoryMarkdownSink] that writes one `.raw.md` and one `.memory.md` per
/// record under [root], following the record's (sanitised) path segments.
///
/// Best-effort and idempotent: it rewrites the full file for each record on
/// every call (histories are small and prompts are slow, so a full rewrite per
/// turn is not a performance concern). A write failure is the caller's to
/// swallow — the JSON snapshot, not this mirror, is the durable record.
final class DirectoryHistoryMarkdownSink implements HistoryMarkdownSink {
  /// The directory the readable tree is rooted at.
  final String root;

  /// Builds a sink rooted at [root]. The directory need not exist yet — it is
  /// created on first write.
  const DirectoryHistoryMarkdownSink(this.root);

  @override
  void write(Iterable<HistoryMarkdownRecord> records) {
    for (final record in records) {
      if (record.pathSegments.isEmpty) continue;
      final safe = record.pathSegments.map(_safeSegment).toList();
      final stem = safe.removeLast();
      final dir = Directory([root, ...safe].join(Platform.pathSeparator));
      dir.createSync(recursive: true);
      final base = '${dir.path}${Platform.pathSeparator}$stem';
      File('$base.raw.md').writeAsStringSync(
        renderConversationRaw(record.history, title: record.title),
      );
      File('$base.memory.md').writeAsStringSync(
        renderConversationMemory(record.history, title: record.title),
      );
    }
  }

  /// Replaces every character that is not a safe filename character with `_`, so
  /// a principal id or session id can never escape its folder or create extra
  /// directory levels.
  static String _safeSegment(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? '_' : cleaned;
  }
}
