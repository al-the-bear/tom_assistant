// MemoryRecallNotice — a human-readable, per-mode rendering of one bridged
// memory-recall call, for surfacing the recall steps to the originating channel
// as out-of-band notices (the Telegram `/trace_memory` toggle, access spec
// § 6.5; `tom_brain_procedure_specification.md` § 13).
//
// Structurally the memory analogue of `ToolEvent.noticeLine()`: where a tool
// call renders a single `🔧 tool X` status line, a recall renders *one line per
// retrieval mode* ("what was found during which memory search") plus a closing
// fusion summary. The dispatch route delivers each line as its own
// `OutboundChunk.notice`, so a buffered channel (Telegram) shows the recall as a
// short sequence of immediate messages.
//
// Built from the bridged call's primitive name + result map (the same `{nodes,
// report}` shape `MemoryBridge.recall` / `recallMulti` return), so the engine's
// per-run memory seam (`recordMemoryCall`) can fire it without reaching into
// memory internals. `fromCall` returns `null` for any non-recall primitive
// (`persist` / `edge` / `stackPush` / …) — those produce no recall notice.

/// The engine-level sink one [MemoryRecallNotice] is handed to per completed
/// recall call. Bound *per run* by `engine.invoke` (the dispatch route knows the
/// request's `Access`), and — unlike the tool / token sinks — threaded
/// unconditionally to nested runs, because memory recall happens inside nested
/// runs (`retrieve_for_prompt_v1`, the `recall_*` strategies), never the
/// top-level body. Best-effort and fire-and-forget: the engine never awaits it
/// and swallows its errors, since a dropped trace message must not affect the
/// answer. `null` (the default) leaves recall untraced.
typedef MemoryNoticeSink = void Function(MemoryRecallNotice notice);

/// One completed bridged-memory recall, rendered for out-of-band tracing.
final class MemoryRecallNotice {
  /// The bridge method that produced it — `recall` or `recallMulti`.
  final String primitive;

  /// Candidate counts per retrieval mode (`bm25` / `vector` / `graphWalk` /
  /// `symbolic`), read off the recall report's `candidatesPerMode`. The "what
  /// was found during which memory search" the trace exists to surface.
  final Map<String, int> candidatesPerMode;

  /// The number of fused/diversified nodes the recall returned (the size of the
  /// result's `nodes` list).
  final int nodesReturned;

  /// Whether the retrieval ran in degraded mode (a backing index unavailable),
  /// read off the report's `degraded` flag.
  final bool degraded;

  const MemoryRecallNotice({
    required this.primitive,
    required this.candidatesPerMode,
    required this.nodesReturned,
    required this.degraded,
  });

  /// Builds a notice from a bridged memory call's [primitive] name and [result]
  /// map, or `null` when [primitive] is not a recall (no notice for writes /
  /// edges / stack ops). The [result] is the bridge's `{nodes, report}` shape;
  /// a malformed / absent report degrades to an empty per-mode map rather than
  /// throwing — tracing is best-effort and must never break the run.
  static MemoryRecallNotice? fromCall(
    String primitive,
    Map<String, Object?> result,
  ) {
    if (primitive != 'recall' && primitive != 'recallMulti') return null;

    final report = result['report'];
    final perMode = <String, int>{};
    var degraded = false;
    if (report is Map) {
      final raw = report['candidatesPerMode'];
      if (raw is Map) {
        raw.forEach((Object? key, Object? value) {
          if (value is int) perMode['$key'] = value;
        });
      }
      degraded = report['degraded'] == true;
    }

    final nodes = result['nodes'];
    final nodesReturned = nodes is List ? nodes.length : 0;

    return MemoryRecallNotice(
      primitive: primitive,
      candidatesPerMode: perMode,
      nodesReturned: nodesReturned,
      degraded: degraded,
    );
  }

  /// The trace lines to deliver, one per [OutboundChunk.notice]: a line per
  /// retrieval mode naming what that search found, then a closing fusion
  /// summary. A recall with no per-mode breakdown (an empty report) still emits
  /// the summary line, so the trace never goes silent on a real recall.
  List<String> noticeLines() {
    final lines = <String>[
      for (final entry in candidatesPerMode.entries)
        '🧠 ${entry.key} search → ${entry.value} candidate'
            '${entry.value == 1 ? '' : 's'}',
    ];
    final summary = StringBuffer('🧠 $primitive → $nodesReturned result'
        '${nodesReturned == 1 ? '' : 's'}');
    if (degraded) summary.write(' (degraded)');
    lines.add(summary.toString());
    return lines;
  }
}
