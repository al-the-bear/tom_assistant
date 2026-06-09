// The streaming session live-trail writer (`tom_brain_logging.md` §5.9; §10
// build-order step #6).
//
// This is the per-session analogue of the quest `live-trail.md` — it mirrors the
// tom-ai `LiveTrailWriter` surface *exactly* (`## 🚀 PROMPT`, `> User:`,
// `### 🧠 thinking`, `### 🔧 <tool>` + ```json``` input + a
// `<details>📤 result</details>` block, `### 💬 assistant`, `### ✅ DONE`) and,
// like it, writes **one append per step** so a file-watcher sees the turn unfold
// as it runs rather than only at completion.
//
// Unlike the §5.4 `SessionSummaryWriter` (which renders one turn block from the
// turn-complete `TurnSummary`), this writer is driven by the **four per-step
// sinks** the host composes in `provision_brain.dart`'s `_trailSinksFor`:
//
//   * [beginPrompt]   ← `IncomingTrailSink`  (turn admitted; PROMPT header + user)
//   * [onLlmCall]     ← `LlmTrailSink`        (one completed LLM call → thinking /
//                                              assistant)
//   * [onMemoryCall]  ← `MemoryAccessSink`    (one bridged memory primitive → 🔧)
//   * [onToolCall]    ← `ToolAccessSink`      (one bridged tool call → 🔧)
//   * [endPrompt]     ← `TurnSummarySink`     (turn complete → ✅ DONE banner)
//
// Routing is keyed by **`turnId`**, which is the one correlation id present on
// every per-step record. `LlmTrailRecord.sessionId` is `null` in the live wiring
// and `MemoryAccessRecord` carries no session id at all, so the `turnId →
// sessionId` map is built at [beginPrompt] (the `IncomingTrailRecord` is the only
// record that carries both) and consulted by the per-step appenders to pick the
// session file. A turn-less (dream) call has a `null` turnId and writes nothing
// here — exactly as it produces no session summary.
//
// Streaming granularity: the substrate exposes no separate reasoning channel and
// these sinks are post-hoc per-*call* observations, so the trail streams at
// **step granularity** (one append per completed cognitive step), not sub-token.
//
// Every write is best-effort (logging-spec §9) and read-modify-write so the §8
// last-N-turns window holds across process restarts.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart'
    show IncomingTrailRecord;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        LlmTrailRecord,
        MemoryAccessRecord,
        SubstrateBridge,
        ToolAccessRecord,
        ToolDenied,
        ToolEvent,
        ToolFailed,
        ToolInvoked,
        ToolListed,
        TurnSummary;

/// Marker comment identifying the per-session live-trail file, self-identifying
/// next to its `.summary.md` sibling.
const String _liveTrailMarker = '<!-- tom-brain session live-trail -->';

/// `## 🚀 PROMPT …` line marker used for prompt-block boundaries (mirrors the
/// tom-ai `LiveTrailWriter`).
const String _promptHeaderPrefix = '## 🚀 PROMPT ';

/// Preview caps mirrored from the tom-ai `LiveTrailWriter`.
const int _userTextPreviewChars = 1000;
const int _toolInputPreviewChars = 2000;
const int _toolResultPreviewChars = 800;
const int _thinkingPreviewChars = 4000;

/// The streaming session live-trail writer (§5.9). One instance serves every
/// session; each session lands in its own `sessions/<sessionId>.live-trail.md`.
final class StreamingLiveTrailWriter {
  /// Builds a writer rooted at the trail [root]. Each session file keeps the
  /// last [turnsKept] prompt blocks (`trail.liveTrailTurns`, §8); when
  /// [captureInternalRoles] is `false` only the user-facing `assistant_to_user`
  /// call renders (mirroring the raw writer's §11.1 gate).
  StreamingLiveTrailWriter({
    required this.root,
    required this.turnsKept,
    this.captureInternalRoles = true,
  });

  /// The trail tree root; live-trail files land under `<root>/sessions/`.
  final Directory root;

  /// The rolling window — prompt blocks kept before the oldest is dropped.
  final int turnsKept;

  /// Whether internal-role calls (recaller, evaluator, …) render as `🧠
  /// thinking`. When `false`, only the user-facing role renders.
  final bool captureInternalRoles;

  /// Live per-turn state, keyed by `turnId`. Populated at [beginPrompt],
  /// consulted by the per-step appenders, dropped at [endPrompt].
  final Map<String, _LiveTurn> _turns = <String, _LiveTurn>{};

  /// Writes the `## 🚀 PROMPT` header + `> User:` body for a freshly admitted
  /// turn, trimming the oldest block past the window, and records the `turnId →
  /// sessionId` mapping the per-step appenders need.
  void beginPrompt(IncomingTrailRecord record) {
    final turnId = record.turnId.value;
    _turns[turnId] = _LiveTurn(
      sessionId: record.sessionId,
      startedAt: record.receivedAt,
    );
    _safe(() {
      final file = _sessionFile(record.sessionId);
      final userPreview = _clip(record.text, _userTextPreviewChars)
          .replaceAll(RegExp(r'\r?\n'), '\n> ');
      final block = '$_promptHeaderPrefix$turnId '
          '[${record.channel.wireName} / ${record.profile ?? 'default'}]\n\n'
          '> User: $userPreview\n';
      _beginBlock(file, block);
    });
  }

  /// Renders one completed LLM call: `### 🧠 thinking (<role>)` for an
  /// internal-role call, or `### 💬 assistant` for the user-facing default role.
  void onLlmCall(LlmTrailRecord record) {
    final obs = record.observation;
    final turnId = obs.turnId;
    if (turnId == null) return; // turn-less (dream) call — not a live-trail turn.
    final turn = _turns[turnId];
    if (turn == null) return; // no open block (header trimmed / never began).

    final isUserFacing = obs.callType == SubstrateBridge.defaultRole;
    if (!isUserFacing && !captureInternalRoles) return;

    turn.llmCalls++;
    turn.step++;
    final body = isUserFacing
        ? '\n### 💬 assistant\n\n${obs.answer.trim()}\n'
        : '\n### 🧠 thinking (${obs.callType})\n\n'
            '${_clip(obs.answer.trim(), _thinkingPreviewChars)}\n';
    _safe(() => _append(_sessionFile(turn.sessionId), body));
  }

  /// Renders one bridged memory primitive as a `### 🔧 <primitive>`
  /// `[<turnId>__<seq>]` tool block with a JSON input fence and a
  /// `details/result` block (mirroring the tom-ai tool rendering).
  void onMemoryCall(MemoryAccessRecord record) {
    final turnId = record.turnId;
    if (turnId == null) return; // turn-less (dream) call.
    final turn = _turns[turnId];
    if (turn == null) return;

    turn.memCalls++;
    turn.step++;
    final seq = turn.step.toString().padLeft(2, '0');
    final inputJson = _clip(_prettyJson(record.input), _toolInputPreviewChars);
    final resultJson = _prettyJson(record.result);
    final fullLength = resultJson.length;
    final resultPreview = _clip(resultJson, _toolResultPreviewChars);
    final truncatedNote = fullLength > _toolResultPreviewChars ? ' — preview' : '';
    final body = '\n### 🔧 ${record.primitive} [${turnId}__$seq]\n\n'
        '```json\n$inputJson\n```\n'
        '\n<details><summary>📤 result ($fullLength chars)$truncatedNote'
        '</summary>\n\n'
        '```text\n$resultPreview\n```\n\n</details>\n';
    _safe(() => _append(_sessionFile(turn.sessionId), body));
  }

  /// Renders one bridged tool call as a `### 🔧 tool <name> [<turnId>__<seq>]`
  /// block with the event's payload as a JSON fence — the trail half of "tool
  /// calls must be in the trails files, especially the live-trail". A failed
  /// or denied invocation is labelled `(failed)` / `(denied)`; an enumeration
  /// (`tool.list`) renders as `tool.list`.
  void onToolCall(ToolAccessRecord record) {
    final turnId = record.turnId;
    if (turnId == null) return; // turn-less (dream) call.
    final turn = _turns[turnId];
    if (turn == null) return;

    turn.toolCalls++;
    turn.step++;
    final seq = turn.step.toString().padLeft(2, '0');
    final payloadJson = _clip(
        _prettyJson(record.event.payloadJson()), _toolInputPreviewChars);
    final body = '\n### 🔧 ${_toolLabel(record.event)} [${turnId}__$seq]\n\n'
        '```json\n$payloadJson\n```\n';
    _safe(() => _append(_sessionFile(turn.sessionId), body));
  }

  /// The human label for a tool event: the tool name for an invocation
  /// (suffixed `(failed)` / `(denied)` on a non-success), or `tool.list` for an
  /// enumeration.
  static String _toolLabel(ToolEvent event) => switch (event) {
        ToolInvoked(:final name) => 'tool $name',
        ToolFailed(:final name) => 'tool $name (failed)',
        ToolDenied(:final name) => 'tool $name (denied)',
        ToolListed() => 'tool.list',
      };

  /// Writes the `### ✅ DONE` banner and closes the turn's live state.
  void endPrompt(TurnSummary summary) {
    final turn = _turns.remove(summary.turnId);
    if (turn == null) return; // turn-less / never began — nothing to close.
    _safe(() {
      final ms = DateTime.now().toUtc().difference(turn.startedAt).inMilliseconds;
      final body = '\n\n### ✅ DONE '
          '(llmCalls=${turn.llmCalls}, memCalls=${turn.memCalls}, '
          'toolCalls=${turn.toolCalls}, ${ms}ms)\n';
      _append(_sessionFile(turn.sessionId), body);
    });
  }

  // ─── File I/O ──────────────────────────────────────────────────────

  File _sessionFile(String sessionId) => File(
        '${root.path}/sessions/${_sanitizeFileToken(sessionId)}.live-trail.md',
      );

  /// Trims the file to the last `turnsKept - 1` prompt blocks, then appends the
  /// new prompt [block] — so after the append exactly [turnsKept] blocks remain.
  void _beginBlock(File file, String block) {
    final trimmed = _trimOldBlocks(file);
    final body = '$trimmed\n$block';
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body.endsWith('\n') ? body : '$body\n');
  }

  /// Appends [content] to the current (last) block of [file], creating the file
  /// with its header when it does not yet exist.
  void _append(File file, String content) {
    final current = file.existsSync() ? file.readAsStringSync() : '';
    final base = current.isEmpty ? '$_liveTrailMarker\n\n' : current;
    final next = base + content;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(next.endsWith('\n') ? next : '$next\n');
  }

  /// Reads [file], drops enough leading prompt blocks that after the caller
  /// appends one new header exactly [turnsKept] remain, and returns the trimmed
  /// body (header comment included). Never writes.
  String _trimOldBlocks(File file) {
    if (!file.existsSync()) return _liveTrailMarker;
    final current = file.readAsStringSync();
    if (current.isEmpty) return _liveTrailMarker;
    final lines = current.split(RegExp(r'\r?\n'));
    final headerIdx = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(_promptHeaderPrefix)) headerIdx.add(i);
    }
    // We want exactly [turnsKept] blocks after the caller adds one, i.e. keep the
    // last (turnsKept - 1) current blocks.
    if (headerIdx.length < turnsKept) {
      return current.endsWith('\n')
          ? current.substring(0, current.length - 1)
          : current;
    }
    final keepFrom = headerIdx[headerIdx.length - (turnsKept - 1)];
    final kept = lines.sublist(keepFrom).join('\n');
    return '$_liveTrailMarker\n\n$kept';
  }

  // ─── Rendering helpers ─────────────────────────────────────────────

  static String _prettyJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  /// Truncation mirroring the tom-ai `clip`: returns the head plus a trimmed
  /// marker when over [max].
  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}\n…(trimmed)';

  /// Makes a session id safe as a file stem by collapsing path separators /
  /// whitespace to `_` (matching `summary_fanout.dart`).
  static String _sanitizeFileToken(String token) =>
      token.replaceAll(RegExp(r'[\\/\s]+'), '_');

  static void _safe(void Function() effect) {
    try {
      effect();
    } catch (_) {
      // Live-trail writes are observability; never let one break a turn (§9).
    }
  }
}

/// Live per-turn state held between the four per-step sinks for one turn.
class _LiveTurn {
  _LiveTurn({required this.sessionId, required this.startedAt});

  /// The session file the turn's blocks land in.
  final String sessionId;

  /// The admission instant (UTC) — the `DONE` banner's elapsed-ms anchor.
  final DateTime startedAt;

  /// Completed LLM calls appended to this turn's block.
  int llmCalls = 0;

  /// Bridged memory calls appended to this turn's block.
  int memCalls = 0;

  /// Bridged tool calls appended to this turn's block.
  int toolCalls = 0;

  /// Monotonic step counter across all call kinds — the `<turnId>__<seq>` tag.
  int step = 0;
}
