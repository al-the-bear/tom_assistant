// The summary fan-out — one per-call / per-turn hub that derives the four
// versioned narrative projections from the same call records the raw
// `LlmTrailWriter` dumps (`tom_brain_logging.md` §5.4 / §5.5 / §5.8 / §9; §10
// build-order step #5).
//
// §5.8 framing: "These are derived projections of the same call records that
// feed §5.4/§5.5 … so there is a single source and three groupings (session,
// role, llm)." This file is that single source's downstream. The host composes
// it behind the same `LlmTrailSink` the raw writer is on, plus the route's
// `TurnSummarySink`:
//
//   * every completed LLM call → [onCall]: appended to the two §5.8 projections
//     (`by-role`, `by-llm`, newest-first);
//   * every completed user turn  → [onTurnComplete]: flushes one §5.4 session
//     block and one §5.5 global block — each a readable transcript of the
//     complete user prompt and the complete final answer the `TurnSummary`
//     carries (no per-call metadata; that drill-down lives in the raw `llm/…`
//     dumps and the by-role / by-llm projections).
//
// Turn-less (dream) calls never produce a `TurnSummary`; they feed only the
// projections.
//
// Scope boundary (§10): this owns the four **summary** projections. The raw
// `llm/<role>/…raw.json` dump + the `↳` headline are the `LlmTrailWriter`'s
// (step #4); the per-session `live-trail.md` (§5.9) is a later step. Everything
// here is best-effort and non-blocking (§9): a projection-write failure never
// fails a turn.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show LlmTrailRecord, SubstrateBridge, TurnSummary;

import 'llm_raw_path.dart' show llmRawPathFromRoot, llmRawStem;

/// The §5.4 session-narrative writer — one file per session,
/// `sessions/<sessionId>.summary.md`, keyed by `sessionId` only (Q3: the
/// profile annotates the per-turn header, not the path). Each completed turn
/// appends one block; the file is capped at the compact-log limit (§8), oldest
/// blocks dropped from the head.
final class SessionSummaryWriter {
  /// Builds a writer rooted at the trail [root], capped at [cap] turn blocks.
  SessionSummaryWriter({required this.root, required this.cap});

  /// The trail tree root; session files land under `<root>/sessions/`.
  final Directory root;

  /// Max turn blocks kept before the oldest drop (`trail.compactLogCap`, §8).
  final int cap;

  /// Appends [summary]'s transcript block (complete prompt + complete answer)
  /// to the session file.
  void writeTurn(TurnSummary summary) {
    final header = '$_sessionFileMarker\n${_sessionHeaderBody(summary)}';
    final file = File(
      '${root.path}/sessions/${_sanitizeFileToken(summary.sessionId)}.summary.md',
    );
    _TurnBlockFile(file: file, header: header, cap: cap)
        .append(_renderTurnBlock(summary, includeSession: false));
  }
}

/// The §5.5 global-narrative writer — `summary/all-sessions.summary.md`, every
/// session interleaved in arrival order with the `sess-…` id on each turn
/// header. Same per-turn format as §5.4; capped at the compact-log limit (§8).
final class GlobalSummaryWriter {
  /// Builds a writer rooted at the trail [root], capped at [cap] turn blocks.
  GlobalSummaryWriter({required this.root, required this.cap});

  /// The trail tree root; the global file is `<root>/summary/all-sessions…`.
  final Directory root;

  /// Max turn blocks kept before the oldest drop (`trail.compactLogCap`, §8).
  final int cap;

  /// Appends [summary]'s transcript block — with the session id on the header —
  /// to the global file.
  void writeTurn(TurnSummary summary) {
    const header = '$_globalFileMarker\n# all sessions';
    final file = File('${root.path}/summary/all-sessions.summary.md');
    _TurnBlockFile(file: file, header: header, cap: cap)
        .append(_renderTurnBlock(summary, includeSession: true));
  }
}

/// A §5.8 per-call projection writer — re-buckets every call one more way
/// (`by-role/<role>` or `by-llm/<provider>-<model>`), newest first, each entry
/// = turn ref · compact prompt · compact answer · link to raw. Capped at the
/// compact-log limit (§8).
final class CallProjectionWriter {
  /// Builds a projection rooted at the trail [root] under `summary/<subdir>/`,
  /// labelled [kind], capped at [cap] entries, bucketing each record by
  /// [bucketOf].
  CallProjectionWriter({
    required this.root,
    required this.subdir,
    required this.kind,
    required this.cap,
    required this.bucketOf,
  });

  /// The trail tree root; projection files land under `<root>/summary/<subdir>/`.
  final Directory root;

  /// The `summary/` subdirectory — `by-role` or `by-llm`.
  final String subdir;

  /// The header label for the bucket — `role` or `llm`.
  final String kind;

  /// Max entries kept before the oldest (the tail, since newest-first) drop.
  final int cap;

  /// Maps a record to its bucket key (the file stem) — the call's role, or its
  /// `<provider>-<model>`.
  final String Function(LlmTrailRecord record) bucketOf;

  /// Prepends [record]'s projection entry to its bucket file (newest first).
  /// Projection files sit two hops under the root, so links use `../../`.
  void writeCall(LlmTrailRecord record) {
    final bucket = bucketOf(record);
    final header = '<!-- tom-brain $kind summary: $bucket -->\n# $kind $bucket';
    final file = File(
      '${root.path}/summary/$subdir/${_sanitizeFileToken(bucket)}.summary.md',
    );
    _ProjectionFile(file: file, header: header, cap: cap)
        .prepend(_renderProjectionEntry(record, '../../'));
  }
}

/// The hub the host binds behind the raw `LlmTrailSink` (via [onCall]) and the
/// route's `TurnSummarySink` (via [onTurnComplete]) — the single source that
/// derives the four versioned summary projections (§5.4 / §5.5 / §5.8).
final class SummaryFanout {
  /// Assembles a fan-out over its four projection writers. Prefer
  /// [SummaryFanout.rootedAt] for the standard root-relative layout.
  SummaryFanout({
    required SessionSummaryWriter session,
    required GlobalSummaryWriter global,
    required CallProjectionWriter byRole,
    required CallProjectionWriter byLlm,
    bool captureInternalRoles = true,
  })  : _session = session,
        _global = global,
        _byRole = byRole,
        _byLlm = byLlm,
        _captureInternalRoles = captureInternalRoles;

  /// Builds the standard fan-out for trail [root]: session files under
  /// `sessions/`, the global file + the two projections under `summary/`. The
  /// summary surfaces cap at [cap] (`trail.compactLogCap`, §8).
  /// [captureInternalRoles] mirrors the raw writer's §11.1 gate: when `false`,
  /// only the user-facing `assistant_to_user` call feeds any surface.
  ///
  /// The §5.9 per-session `live-trail.md` is **not** built here — it is the
  /// standalone streaming `StreamingLiveTrailWriter`, composed alongside this
  /// fan-out on the same per-step sinks (`provision_brain.dart`).
  factory SummaryFanout.rootedAt(
    Directory root, {
    int cap = 1000,
    bool captureInternalRoles = true,
  }) =>
      SummaryFanout(
        session: SessionSummaryWriter(root: root, cap: cap),
        global: GlobalSummaryWriter(root: root, cap: cap),
        byRole: CallProjectionWriter(
          root: root,
          subdir: 'by-role',
          kind: 'role',
          cap: cap,
          bucketOf: (record) => record.observation.callType,
        ),
        byLlm: CallProjectionWriter(
          root: root,
          subdir: 'by-llm',
          kind: 'llm',
          cap: cap,
          bucketOf: (record) {
            final report = record.observation.report;
            return '${report.providerId}-${report.modelId}';
          },
        ),
        captureInternalRoles: captureInternalRoles,
      );

  final SessionSummaryWriter _session;
  final GlobalSummaryWriter _global;
  final CallProjectionWriter _byRole;
  final CallProjectionWriter _byLlm;
  final bool _captureInternalRoles;

  /// Fans one completed LLM call out to the two §5.8 per-call projections
  /// (`by-role`, `by-llm`). The session / global transcripts no longer draw on
  /// per-call records — they render the turn's prompt + answer directly (§5.4) —
  /// so nothing is buffered here. Best-effort (§9): a projection write that
  /// throws never escapes.
  void onCall(LlmTrailRecord record) {
    final obs = record.observation;
    // §11.1 internal-role gate: when off, only the user-facing role is trailed.
    if (!_captureInternalRoles && obs.callType != SubstrateBridge.defaultRole) {
      return;
    }
    _safe(() => _byRole.writeCall(record));
    _safe(() => _byLlm.writeCall(record));
  }

  /// Flushes the §5.4 session block and the §5.5 global block for one completed
  /// turn — each a readable transcript built from [summary]'s complete prompt
  /// and answer. Best-effort (§9): each surface is written independently, so one
  /// failing does not starve the other. (The §5.9 live-trail is written
  /// step-by-step by the standalone `StreamingLiveTrailWriter`, not here.)
  void onTurnComplete(TurnSummary summary) {
    _safe(() => _session.writeTurn(summary));
    _safe(() => _global.writeTurn(summary));
  }

  static void _safe(void Function() effect) {
    try {
      effect();
    } catch (_) {
      // Summary projections are non-essential; never let one break a turn (§9).
    }
  }
}

// ─── Markdown rendering ──────────────────────────────────────────────

const String _sessionFileMarker = '<!-- tom-brain session summary -->';
const String _globalFileMarker = '<!-- tom-brain global summary -->';

/// The `# session <sid>  ·  principal: <pid>[  ·  channel: <ch>]` header body
/// for the §5.4 session file. The writer prepends its marker comment, so the
/// file stays self-identifying.
String _sessionHeaderBody(TurnSummary summary) =>
    '# session ${summary.sessionId}  ·  principal: ${summary.principalId}'
    '${summary.channel == null ? '' : '  ·  channel: ${summary.channel}'}';

/// The §5.4 / §5.5 transcript block: a header line (with the session id when
/// [includeSession]), then the **complete** user prompt under `### Prompt` and
/// the **complete** final answer under `### Answer`, both verbatim. No per-call
/// metadata — that drill-down lives in the raw `llm/…` dumps (§5.2) and the
/// by-role / by-llm projections (§5.8).
String _renderTurnBlock(
  TurnSummary summary, {
  required bool includeSession,
}) {
  final sessionSegment =
      includeSession ? 'session: ${summary.sessionId}  ·  ' : '';
  final answer = summary.finalAnswer;
  final buffer = StringBuffer()
    ..writeln('## turn ${summary.turnId}  ·  ${_timestamp(summary.startedAt)}'
        '  ·  ${sessionSegment}profile: ${summary.profile ?? 'default'}')
    ..writeln()
    ..writeln('### Prompt')
    ..writeln()
    ..writeln(summary.userPrompt.trim())
    ..writeln()
    ..writeln('### Answer')
    ..writeln()
    ..writeln(answer == null
        ? '_(no answer — the turn did not complete)_'
        : answer.trim());
  return buffer.toString().trimRight();
}

/// One §5.8 projection entry: turn ref · compact prompt · compact answer · raw
/// link. The compact prompt comes from the captured wire body when present; it
/// is `—` when the wire was not captured (`trail.capture.wireBody=false`, §8).
String _renderProjectionEntry(LlmTrailRecord record, String linkPrefix) {
  final obs = record.observation;
  final wire = obs.wire;
  final prompt = wire == null ? '—' : _truncate(_oneLine(wire.body), 80);
  final answer = _truncate(_oneLine(obs.answer), 80);
  final link = '$linkPrefix${llmRawPathFromRoot(record)}';
  return '- ${llmRawStem(record)} · $prompt · $answer — [raw]($link)';
}

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String _truncate(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// `YYYY-MM-DD HH:MM:SS` in UTC — the §5.4 turn-header timestamp form.
String _timestamp(DateTime instant) {
  final utc = instant.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
}

/// Makes a bucket key (session id, role, `provider-model`) safe as a file stem
/// by collapsing path separators / whitespace to `_`.
String _sanitizeFileToken(String token) =>
    token.replaceAll(RegExp(r'[\\/\s]+'), '_');

// ─── File primitives ─────────────────────────────────────────────────

/// A versioned turn-block file (§5.4 / §5.5): a fixed header followed by turn
/// transcript blocks. Append is read-modify-rewrite so the cap holds across
/// process restarts; blocks beyond [cap] drop from the head (oldest first).
///
/// Blocks are joined by an **invisible HTML-comment sentinel**, not a visible
/// `---` rule, precisely because the blocks now carry verbatim prompt/answer
/// text — an answer legitimately containing a `---` markdown rule (common) would
/// corrupt a `---`-delimited parse. The sentinel renders to nothing and is not
/// realistically producible by an LLM answer, so block parsing stays sound while
/// the file still reads as plain markdown.
class _TurnBlockFile {
  _TurnBlockFile({required this.file, required this.header, required this.cap});

  final File file;
  final String header;
  final int cap;

  /// Invisible block boundary. Begins with a blank-line gap for readability;
  /// the comment itself is the machine-robust split key.
  static const String _separator = '\n\n<!-- @turn-block -->\n\n';

  void append(String block) {
    final blocks = _readBlocks()..add(block);
    final kept =
        blocks.length > cap ? blocks.sublist(blocks.length - cap) : blocks;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${<String>[header, ...kept].join(_separator)}\n');
  }

  List<String> _readBlocks() {
    if (!file.existsSync()) return <String>[];
    var raw = file.readAsStringSync();
    if (raw.endsWith('\n')) raw = raw.substring(0, raw.length - 1);
    final parts = raw.split(_separator);
    // parts[0] is the (regenerated-on-write) header; the rest are turn blocks.
    return parts.length <= 1 ? <String>[] : parts.sublist(1);
  }
}

/// A versioned newest-first projection file (§5.8): a fixed header followed by
/// one-line `- …` entries, newest at the top. Prepend is read-modify-rewrite;
/// entries beyond [cap] drop from the tail (oldest first).
class _ProjectionFile {
  _ProjectionFile({required this.file, required this.header, required this.cap});

  final File file;
  final String header;
  final int cap;

  void prepend(String entry) {
    final entries = _readEntries()..insert(0, entry);
    final kept = entries.length > cap ? entries.sublist(0, cap) : entries;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('$header\n\n${kept.join('\n')}\n');
  }

  List<String> _readEntries() {
    if (!file.existsSync()) return <String>[];
    return file
        .readAsStringSync()
        .split('\n')
        .where((line) => line.startsWith('- '))
        .toList();
  }
}
