// Extracts the final answer for a turn from the §5.4 session-narrative summary
// (`sessions/<sessionId>.summary.md`, `prompt_tracing.md` § 3.5). The block
// layout is owned by `tom_brain_run`'s `SummaryFanout._renderTurnBlock` (read
// read-only as the contract): blocks are joined by the invisible
// `<!-- @turn-block -->` sentinel, each block carrying `## turn <turnId> …`, a
// `### Prompt` section, and a `### Answer` section.
//
// The §5.4 writer renders the "no answer" placeholder verbatim when a turn did
// not complete; this parser returns it as-is rather than `null`, because the
// authoritative completion signal is the run-tree outcome status (§ 3.6), not
// the answer text.

/// The sentinel `SummaryFanout` joins turn blocks with.
const String _turnBlockSeparator = '<!-- @turn-block -->';

/// Returns the verbatim `### Answer` body for [turnId] from a session summary
/// [content], or `null` when the turn has no block (or no answer section).
String? finalAnswerFor(String content, String turnId) {
  for (final block in content.split(_turnBlockSeparator)) {
    if (!block.contains('## turn $turnId')) continue;
    return _answerSection(block);
  }
  return null;
}

/// Extracts the text under the `### Answer` heading up to the end of the block.
String? _answerSection(String block) {
  final lines = block.split(RegExp(r'\r?\n'));
  final answerIndex = lines.indexWhere((l) => l.trim() == '### Answer');
  if (answerIndex < 0) return null;
  final body = lines
      .skip(answerIndex + 1)
      .takeWhile((l) => !l.startsWith('### ') && !l.startsWith('## '))
      .join('\n')
      .trim();
  return body.isEmpty ? null : body;
}
