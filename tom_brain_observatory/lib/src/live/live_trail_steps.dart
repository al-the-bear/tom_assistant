// PT-4.1 — the pure parser for one turn's block of a per-session streaming
// live-trail (`streaming_live_trail.dart`, § 3.5). The brain appends one
// `### `-headed section per cognitive step under a `## 🚀 PROMPT <turnId>`
// header, terminated by a `### ✅ DONE` banner. [parseTurnSteps] re-reads the
// whole file content and projects one turn's steps in order — the deterministic
// core the SSE live-tail diffs by count to emit only newly-appended steps
// (§ 4.8). It opens no files and holds no state: read-only by construction
// (OBS-1, OBS-5).

import 'dart:convert';

/// The prompt-block header the brain writes per turn (`streaming_live_trail.dart`).
const _promptPrefix = '## 🚀 PROMPT ';

/// A heading line of a cognitive step within a turn's block.
const _stepPrefix = '### ';

/// One cognitive step within a turn's live-trail block — a `### `-headed
/// section the brain appended as it ran (§ 3.5).
class LiveTrailStep {
  /// The heading text after `### ` — e.g. `🧠 thinking (recall_planner)`,
  /// `💬 assistant`, `🔧 recallMulti [<turnId>__02]`, or the `✅ DONE` banner.
  final String heading;

  /// The verbatim markdown between this heading and the next step/turn
  /// boundary, trimmed of surrounding blank lines.
  final String body;

  /// True for the `✅ DONE` banner that terminates a turn — the signal the
  /// live-tail uses to close the stream.
  final bool isDone;

  const LiveTrailStep({
    required this.heading,
    required this.body,
    required this.isDone,
  });

  /// The wire shape an SSE live-tail event carries (§ 4.8).
  Map<String, Object?> toJson() => <String, Object?>{
        'heading': heading,
        'body': body,
        'done': isDone,
      };
}

/// Parses the ordered cognitive steps of [turnId] from live-trail [content].
/// Returns empty when the turn's `## 🚀 PROMPT` block is absent (it may not
/// have been appended yet — absence is never an error, § 4.1).
List<LiveTrailStep> parseTurnSteps(String content, String turnId) {
  final lines = const LineSplitter().convert(content);
  final start = _turnHeaderIndex(lines, turnId);
  if (start == null) return const <LiveTrailStep>[];

  // The block runs to the next prompt header (or end of file).
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith(_promptPrefix)) {
      end = i;
      break;
    }
  }

  final steps = <LiveTrailStep>[];
  var i = start + 1;
  while (i < end) {
    if (!lines[i].startsWith(_stepPrefix)) {
      i++;
      continue;
    }
    final heading = lines[i].substring(_stepPrefix.length).trim();
    final body = <String>[];
    var j = i + 1;
    while (j < end && !lines[j].startsWith(_stepPrefix)) {
      body.add(lines[j]);
      j++;
    }
    steps.add(LiveTrailStep(
      heading: heading,
      body: _trimBlankEdges(body).join('\n'),
      isDone: heading.startsWith('✅ DONE'),
    ));
    i = j;
  }
  return steps;
}

/// The index of [turnId]'s prompt header, matching the turnId as a whole token
/// (the first space-delimited word after the prefix), never as a prefix.
int? _turnHeaderIndex(List<String> lines, String turnId) {
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith(_promptPrefix)) continue;
    final rest = line.substring(_promptPrefix.length).trimLeft();
    final space = rest.indexOf(' ');
    final token = space < 0 ? rest : rest.substring(0, space);
    if (token == turnId) return i;
  }
  return null;
}

/// Drops leading and trailing blank lines from [lines].
List<String> _trimBlankEdges(List<String> lines) {
  var start = 0;
  var end = lines.length;
  while (start < end && lines[start].trim().isEmpty) {
    start++;
  }
  while (end > start && lines[end - 1].trim().isEmpty) {
    end--;
  }
  return lines.sublist(start, end);
}
