// The run-layer concrete implementations of the access package's Telegram
// inspection ports (`TelegramPromptInspector` / `TelegramLogInspector` /
// `TelegramMemoryInspector` / `TelegramStatusInspector`).
//
// ── Why these live here ──────────────────────────────────────────────
//
// The Telegram edge surfaces the brain's operational state — the recorded
// incoming prompts (the §5.3 `incoming/` trail), the important log files, the
// memory overview, and the live processing status — through narrow read-only
// *port* interfaces it defines in `tom_brain_access`. The access package must
// not read the trail tree, the memory, or the dispatcher coordinator directly
// (`dependency_surface_test.dart`), so the concrete reads live in
// `tom_brain_run` — the one assembly that legally wires the trail writers, the
// memory client, and the coordinator snapshot together. `standUpBrainProcess`
// builds a [TelegramInspectors] bundle from these and injects it at the access
// seam.
//
// Each implementation returns already-rendered, channel-neutral data; the edge
// owns the Telegram presentation (message formatting + the 4096-code-unit
// split), so nothing here knows about Telegram.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show
        QueueSnapshot,
        QueueSnapshotSource,
        TelegramLogInspector,
        TelegramLogTail,
        TelegramMemoryInspector,
        TelegramPromptDigest,
        TelegramPromptInspector,
        TelegramStatusInspector,
        TelegramTodosInspector,
        TelegramUsageInspector;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        LiveRunRegistry,
        LiveRunUsage,
        SessionTodoStores,
        TodoEntry,
        TodoStore;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EffortMetrics, LatencyHistogram, MemoryStats, TomBrainMemoryClient;

/// Reads the §5.3 `incoming/` raw-prompt trail back for the `/observatory_*`
/// commands (parts b + c).
///
/// Walks `<trailRoot>/incoming/<channel>/<turnId>.raw.json`, the exact files
/// `IncomingTrailWriter` dumps, and orders them newest-first by their recorded
/// `receivedAt`. Index `0` is the most recent prompt, shared between
/// [recentPrompts] and [promptDetail] so the index a user reads from the list
/// addresses the same prompt when they analyze it.
final class TrailIncomingPromptInspector implements TelegramPromptInspector {
  /// The trail tree root (`trail.root`). Raw prompt dumps live under
  /// `<trailRoot>/incoming/`.
  final Directory trailRoot;

  /// Builds an inspector over the trail [trailRoot].
  TrailIncomingPromptInspector({required this.trailRoot});

  @override
  Future<List<TelegramPromptDigest>> recentPrompts({
    required int limit,
    required int previewLength,
  }) async {
    final records = await _loadNewestFirst();
    final digests = <TelegramPromptDigest>[];
    for (var index = 0; index < records.length && index < limit; index++) {
      final record = records[index];
      digests.add(TelegramPromptDigest(
        index: index,
        receivedAt: record.receivedAt,
        preview: _preview(record.text, previewLength),
      ));
    }
    return digests;
  }

  @override
  Future<String?> promptDetail(int index) async {
    if (index < 0) return null;
    final records = await _loadNewestFirst();
    if (index >= records.length) return null;
    return _renderDetail(index, records[index]);
  }

  /// Loads every recorded prompt, newest-first by `receivedAt`. Best-effort: a
  /// file that cannot be read or parsed is skipped rather than failing the whole
  /// inspection.
  Future<List<_PromptRecord>> _loadNewestFirst() async {
    final incoming = Directory('${trailRoot.path}/incoming');
    if (!await incoming.exists()) return const <_PromptRecord>[];

    final records = <_PromptRecord>[];
    await for (final entity in incoming.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.raw.json')) continue;
      final record = await _parse(entity);
      if (record != null) records.add(record);
    }
    records.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return records;
  }

  /// Parses one `*.raw.json` dump into a [_PromptRecord], or `null` when the
  /// file is unreadable or malformed.
  Future<_PromptRecord?> _parse(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return null;
      final receivedAtRaw = decoded['receivedAt'];
      final receivedAt = receivedAtRaw is String
          ? DateTime.tryParse(receivedAtRaw)
          : null;
      if (receivedAt == null) return null;
      return _PromptRecord(receivedAt: receivedAt, fields: decoded);
    } catch (_) {
      return null;
    }
  }

  /// The first [length] characters of [text], with internal whitespace runs
  /// collapsed to single spaces so a list line stays on one row.
  String _preview(String text, int length) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= length) return collapsed;
    return '${collapsed.substring(0, length)}…';
  }

  /// Renders the full, already-formatted detail of the prompt at [index].
  String _renderDetail(int index, _PromptRecord record) {
    final fields = record.fields;
    final buffer = StringBuffer()
      ..writeln('Prompt [$index]')
      ..writeln('turnId: ${fields['turnId']}')
      ..writeln('channel: ${fields['channel']}')
      ..writeln('receivedAt: ${record.receivedAt.toIso8601String()}')
      ..writeln('principalId: ${fields['principalId']}')
      ..writeln('sessionId: ${fields['sessionId']}');
    if (fields['conversationId'] != null) {
      buffer.writeln('conversationId: ${fields['conversationId']}');
    }
    if (fields['profile'] != null) {
      buffer.writeln('profile: ${fields['profile']}');
    }
    buffer
      ..writeln('persona: ${fields['persona']}')
      ..writeln('attachments: ${fields['attachments']}')
      ..writeln()
      ..writeln('text:')
      ..write(fields['text'] ?? '');
    return buffer.toString();
  }
}

/// One parsed `incoming/.../<turnId>.raw.json` record.
final class _PromptRecord {
  final DateTime receivedAt;
  final Map<String, Object?> fields;

  _PromptRecord({required this.receivedAt, required this.fields});

  /// The recorded user text (empty when the field is absent or not a string).
  String get text => fields['text'] is String ? fields['text'] as String : '';
}

/// Reads the tails of the important trail log files for the `/show_logs`
/// command (part d).
///
/// Tails `<trailRoot>/brain.log`, then each `components/*.log`, then each
/// `memory/*.log` — the §5.1 / §10 step #3 log surfaces. Rotated `*.log.N`
/// files are skipped (only the live `.log` is interesting); each tail is the
/// file's last N lines, named by its path relative to the trail root.
final class TrailLogInspector implements TelegramLogInspector {
  /// The trail tree root (`trail.root`) the log files live under.
  final Directory trailRoot;

  /// Builds an inspector over the trail [trailRoot].
  TrailLogInspector({required this.trailRoot});

  @override
  Future<List<TelegramLogTail>> tailLogs({required int lines}) async {
    final tails = <TelegramLogTail>[];
    for (final file in await _logFiles()) {
      final tail = await _tail(file, lines);
      if (tail != null) tails.add(tail);
    }
    return tails;
  }

  /// Collects the live log files in display order: `brain.log` first, then the
  /// `components/` logs, then the `memory/` logs, each group sorted by name.
  /// Rotated `*.log.N` files are excluded.
  Future<List<File>> _logFiles() async {
    final files = <File>[];
    final brainLog = File('${trailRoot.path}/brain.log');
    if (await brainLog.exists()) files.add(brainLog);
    files.addAll(await _liveLogsIn('${trailRoot.path}/components'));
    files.addAll(await _liveLogsIn('${trailRoot.path}/memory'));
    return files;
  }

  /// The `*.log` files directly in [dirPath], sorted by name; `*.log.N` rotated
  /// files and any non-`.log` entry are excluded. Empty when the directory does
  /// not exist.
  Future<List<File>> _liveLogsIn(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.log')) files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Returns the last [lines] lines of [file] as a [TelegramLogTail], or `null`
  /// when the file cannot be read.
  Future<TelegramLogTail?> _tail(File file, int lines) async {
    try {
      final allLines = const LineSplitter().convert(await file.readAsString());
      final tail = allLines.length <= lines
          ? allLines
          : allLines.sublist(allLines.length - lines);
      return TelegramLogTail(name: _relativeName(file), content: tail.join('\n'));
    } catch (_) {
      return null;
    }
  }

  /// The file's path relative to the trail root (e.g. `brain.log`,
  /// `components/tom_brain.substrate.log`), used as the tail's display name.
  String _relativeName(File file) {
    final rootPath = trailRoot.path;
    if (file.path.startsWith('$rootPath/')) {
      return file.path.substring(rootPath.length + 1);
    }
    return file.uri.pathSegments.last;
  }
}

/// Renders the memory overview for the `/memory_status` command (part e) over
/// the live memory client's `stats()`.
final class MemoryStatsInspector implements TelegramMemoryInspector {
  /// The booted memory's read surface.
  final TomBrainMemoryClient client;

  /// Builds an inspector over the booted memory [client].
  MemoryStatsInspector({required this.client});

  @override
  Future<String> status() async => _render(await client.stats());

  /// Renders a [MemoryStats] snapshot to a multi-line overview. Empty sections
  /// are shown as `(none)` so the absence is explicit rather than a missing
  /// heading.
  String _render(MemoryStats stats) {
    final buffer = StringBuffer()
      ..writeln('Memory status')
      ..writeln()
      ..writeln('Nodes (total ${_sum(stats.nodeCountByType)}):');
    _writeCounts(buffer, stats.nodeCountByType);
    buffer
      ..writeln()
      ..writeln('Edges (total ${_sum(stats.edgeCountByType)}):');
    _writeCounts(buffer, stats.edgeCountByType);
    buffer
      ..writeln()
      ..writeln('Stacks:');
    _writeCounts(buffer, stats.stackSizes);
    buffer
      ..writeln()
      ..writeln('Trails: ${stats.trailCount} files, ${stats.trailBytes} bytes');

    if (stats.recallLatencyPerMode.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Recall latency (p50/p95 ms):');
      final modes = stats.recallLatencyPerMode.keys.toList()..sort();
      for (final mode in modes) {
        final LatencyHistogram h = stats.recallLatencyPerMode[mode]!;
        buffer.writeln('  $mode: ${h.p50Ms} / ${h.p95Ms}');
      }
    }

    if (stats.migrationProgress.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Migrations:');
      final ids = stats.migrationProgress.keys.toList()..sort();
      for (final id in ids) {
        final pct = (stats.migrationProgress[id]! * 100).round();
        buffer.writeln('  $id: $pct%');
      }
    }

    return buffer.toString().trimRight();
  }

  /// Writes a `  key: value` line per entry in [counts] (sorted by key), or a
  /// single `  (none)` line when empty.
  void _writeCounts(StringBuffer buffer, Map<String, int> counts) {
    if (counts.isEmpty) {
      buffer.writeln('  (none)');
      return;
    }
    final keys = counts.keys.toList()..sort();
    for (final key in keys) {
      buffer.writeln('  $key: ${counts[key]}');
    }
  }

  int _sum(Map<String, int> counts) =>
      counts.values.fold(0, (acc, value) => acc + value);
}

/// Renders the comprehensive operational status for the `/check_status` command
/// over the live dispatcher-coordinator snapshot + the on-disk trail.
///
/// Three sources are stitched into one report:
///
///   * the live [QueueSnapshot] (read through [queueSnapshot]) → whether a
///     prompt is being processed right now, how many are queued behind it, and
///     whether a background (dream) run is going;
///   * the §5.3 `incoming/` trail (read through a composed
///     [TrailIncomingPromptInspector]) → the latest received prompt, labelled
///     "currently processing" when the foreground slot is busy and "last
///     received" when it is idle;
///   * the §5.7 `procedures/<procedureId>/…log` trees → the most recent runs'
///     `outcome` lines and any `error …` lines (a budget overrun surfaces as
///     `error procedure.budget.exceeded: …`), so a user can see what halted a
///     run without sending another prompt.
///
/// There is no single live record that maps the running foreground slot to its
/// turnId/prompt, so the inspector assembles "what is being processed" from the
/// coordinator's *is-busy* signal and the newest recorded prompt — the best
/// available proxy. Every read is best-effort: a missing trail tree or an
/// unreadable log degrades a section to its empty form, never an error.
final class TrailStatusInspector implements TelegramStatusInspector {
  /// Reads the live dispatcher-coordinator state (run slots + queue depth).
  final QueueSnapshotSource queueSnapshot;

  /// The trail tree root (`trail.root`). The latest prompt lives under
  /// `<trailRoot>/incoming/`; the recent runs under `<trailRoot>/procedures/`.
  final Directory trailRoot;

  /// Reuses the prompt inspector's newest-first `incoming/` read for the latest
  /// recorded prompt (composition over a duplicate trail walk).
  final TrailIncomingPromptInspector _prompts;

  /// Builds a status inspector over the live [queueSnapshot] and the trail
  /// [trailRoot].
  TrailStatusInspector({required this.queueSnapshot, required this.trailRoot})
      : _prompts = TrailIncomingPromptInspector(trailRoot: trailRoot);

  /// How many of the most recent procedure runs the report summarises.
  static const int recentRunLimit = 5;

  /// The preview length of the latest prompt's user text in the report.
  static const int promptPreviewLength = 200;

  @override
  Future<String> report() async {
    final QueueSnapshot snapshot = queueSnapshot();
    final List<TelegramPromptDigest> latest =
        await _prompts.recentPrompts(limit: 1, previewLength: promptPreviewLength);
    final List<_RunLogSummary> runs = await _recentRuns();

    final buffer = StringBuffer()
      ..writeln('Brain status')
      ..writeln()
      ..writeln('Processing: ${_processingState(snapshot)}')
      ..writeln('  Foreground: ${snapshot.foregroundRunning ? 'running' : 'idle'}'
          ' (waiting ${snapshot.foregroundWaiting}, '
          'queue depth ${snapshot.foregroundQueueDepth})')
      ..writeln(
          '  Background: ${snapshot.backgroundRunning ? 'running' : 'idle'}')
      ..writeln()
      ..writeln('Latest prompt (${_latestPromptLabel(snapshot, latest)}):');
    if (latest.isEmpty) {
      buffer.writeln('  (no prompts recorded yet)');
    } else {
      final digest = latest.single;
      buffer
        ..writeln('  [${digest.receivedAt.toIso8601String()}]')
        ..writeln('  ${digest.preview}');
    }

    buffer
      ..writeln()
      ..writeln('Recent runs:');
    if (runs.isEmpty) {
      buffer.writeln('  (no runs recorded yet)');
    } else {
      for (final run in runs) {
        buffer.writeln('  ${run.key}: ${run.outcome ?? '(in progress)'}');
      }
    }

    final List<String> errors = <String>[
      for (final run in runs)
        for (final error in run.errors) '${run.key}: $error',
    ];
    buffer
      ..writeln()
      ..writeln('Errors:');
    if (errors.isEmpty) {
      buffer.writeln('  (none)');
    } else {
      for (final error in errors) {
        buffer.writeln('  $error');
      }
    }

    return buffer.toString().trimRight();
  }

  /// The one-line processing state derived from the coordinator snapshot.
  /// Draining wins over everything (the process is winding down); otherwise a
  /// busy foreground slot means a prompt is in flight, a busy background slot
  /// means free-time work, and an empty pair is plain idle.
  String _processingState(QueueSnapshot snapshot) {
    if (snapshot.draining) return 'draining (shutting down)';
    if (snapshot.foregroundRunning) {
      return 'active — a prompt is being processed';
    }
    if (snapshot.backgroundRunning) return 'idle (background work running)';
    return 'idle (nothing being processed)';
  }

  /// How to label the latest recorded prompt: the one the foreground slot is
  /// busy with (best-effort proxy) when it is running, the last one seen when
  /// idle, and an explicit "none" when nothing has been recorded.
  String _latestPromptLabel(
    QueueSnapshot snapshot,
    List<TelegramPromptDigest> latest,
  ) {
    if (latest.isEmpty) return 'none recorded yet';
    return snapshot.foregroundRunning ? 'currently processing' : 'last received';
  }

  /// Loads the most recent procedure-run logs (newest-first by modified time),
  /// capped at [recentRunLimit], each summarised to its outcome + error lines.
  /// Best-effort: a missing `procedures/` tree yields an empty list.
  Future<List<_RunLogSummary>> _recentRuns() async {
    final proceduresDir = Directory('${trailRoot.path}/procedures');
    if (!await proceduresDir.exists()) return const <_RunLogSummary>[];

    final files = <File>[];
    await for (final entity in proceduresDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.log')) files.add(entity);
    }
    // Newest-first by modified time; a stat failure sorts the file last.
    final stamped = <(File, DateTime)>[
      for (final file in files) (file, await _modifiedOrEpoch(file)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    final summaries = <_RunLogSummary>[];
    for (final entry in stamped.take(recentRunLimit)) {
      final summary = await _summarise(entry.$1, proceduresDir.path);
      if (summary != null) summaries.add(summary);
    }
    return summaries;
  }

  /// The file's last-modified time, or the epoch when it cannot be stat'd (so a
  /// stat failure never throws and the file simply sorts oldest).
  Future<DateTime> _modifiedOrEpoch(File file) async {
    try {
      return (await file.stat()).modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  /// Summarises one `procedures/.../<key>.log` file to its outcome line and any
  /// error lines, keyed by its path relative to [proceduresPath] (extension
  /// dropped). Returns `null` when the file cannot be read.
  Future<_RunLogSummary?> _summarise(File file, String proceduresPath) async {
    final List<String> lines;
    try {
      lines = const LineSplitter().convert(await file.readAsString());
    } catch (_) {
      return null;
    }

    String? outcome;
    final errors = <String>[];
    for (final line in lines) {
      final stripped = _stripTree(line);
      if (stripped.startsWith('outcome ')) {
        outcome = stripped; // keep the last (top-level) outcome line.
      } else if (stripped.startsWith('error ')) {
        errors.add(stripped);
      }
    }
    return _RunLogSummary(
      key: _runKey(file, proceduresPath),
      outcome: outcome,
      errors: errors,
    );
  }

  /// The run's display key: its path relative to `procedures/`, with the `.log`
  /// extension dropped (e.g. `answer_with_memory_v1/turn_01__run_07`).
  String _runKey(File file, String proceduresPath) {
    var path = file.path;
    if (path.startsWith('$proceduresPath/')) {
      path = path.substring(proceduresPath.length + 1);
    } else {
      path = file.uri.pathSegments.last;
    }
    return path.endsWith('.log')
        ? path.substring(0, path.length - '.log'.length)
        : path;
  }

  /// Strips the leading box-drawing connector (`├─`, `└─`, `│`, `─`) and
  /// surrounding whitespace from a procedure-tree line, leaving the bare node
  /// text (`outcome accepted (…)`, `error procedure.budget.exceeded: …`).
  String _stripTree(String line) =>
      line.replaceFirst(RegExp(r'^[\s├└│─]+'), '');
}

/// One procedure-run log file's distilled summary for the status report: its
/// display [key], the terminal [outcome] line (`null` when the run wrote none —
/// still in progress or crashed before the outcome), and any error node lines.
final class _RunLogSummary {
  final String key;
  final String? outcome;
  final List<String> errors;

  _RunLogSummary({required this.key, required this.outcome, required this.errors});
}

/// Reads and clears the engine's per-session working todo lists for the
/// `/todos_list` and `/todos_clear` commands, over the engine's process-lifetime
/// [SessionTodoStores].
///
/// The brain keeps a scratch todo list per conversation session (bound to the
/// run's `ToolContext.todos`, surviving across the prompts of a conversation but
/// never written to memory). The Telegram edge resolves the user's active
/// session id and hands it in; this inspector peeks the matching store without
/// creating one — a session that has not yet written a todo simply reads empty.
final class SessionTodosInspector implements TelegramTodosInspector {
  /// The engine's process-lifetime registry of per-session todo stores.
  final SessionTodoStores stores;

  /// Builds an inspector over the engine's [stores].
  SessionTodosInspector({required this.stores});

  @override
  Future<String> list(String sessionId) async {
    final TodoStore? store = stores.peek(sessionId);
    final List<TodoEntry> entries = store?.list() ?? const <TodoEntry>[];
    if (entries.isEmpty) return 'The working todo list is empty.';

    final buffer = StringBuffer('Working todo list (${entries.length}):');
    for (final entry in entries) {
      final box = entry.done ? '[x]' : '[ ]';
      buffer.write('\n$box ${entry.id}  ${entry.text}');
    }
    return buffer.toString();
  }

  @override
  Future<String> clear(String sessionId) async {
    final TodoStore? store = stores.peek(sessionId);
    final int removed = store?.list().length ?? 0;
    stores.clearSession(sessionId);
    if (removed == 0) return 'The working todo list was already empty.';
    final noun = removed == 1 ? 'entry' : 'entries';
    return 'Cleared $removed $noun from the working todo list.';
  }
}

/// Renders the live budget of the prompt being processed right now for the
/// `/check_usage` command, over the engine's process-lifetime [LiveRunRegistry].
///
/// Answers "how much has the current prompt spent *so far*?" — the elapsed time
/// since the prompt's top-level run started and the accumulating effort summed
/// across its open runs (the foreground prompt plus its in-flight
/// sub-procedures). Reads the registry live on every call, so the figures grow
/// while the prompt runs and the command reports "no prompt is being processed"
/// the moment the run finishes. The clock is injected ([now]) so the elapsed
/// formatting is deterministically testable.
final class LiveUsageInspector implements TelegramUsageInspector {
  /// The engine's process-lifetime registry of in-flight runs.
  final LiveRunRegistry registry;

  /// The wall-clock source; defaults to [DateTime.now]. Injected so a test can
  /// pin the elapsed time the report renders.
  final DateTime Function() now;

  /// Builds an inspector over the engine's [registry].
  LiveUsageInspector({required this.registry, DateTime Function()? now})
      : now = now ?? DateTime.now;

  @override
  Future<String> currentUsage() async {
    final LiveRunUsage? usage = registry.currentPromptUsage();
    if (usage == null) return 'No prompt is being processed right now.';

    final Duration elapsed = now().difference(usage.startedAt);
    final EffortMetrics effort = usage.effort;
    final buffer = StringBuffer('Processing the current prompt:')
      ..write('\n  procedure: ${usage.procedureId}')
      ..write('\n  elapsed: ${_formatElapsed(elapsed)}')
      ..write('\n  open runs: ${usage.openRunCount}')
      ..write('\n  LLM calls: ${effort.llmCalls}')
      ..write('\n  tool calls: ${effort.toolCalls}')
      ..write('\n  estimated tokens: ${effort.estimatedTokens}'
          ' (in ${effort.inputTokens} / out ${effort.outputTokens})')
      ..write('\n  memory reads: ${effort.memoryReads}')
      ..write('\n  memory writes: ${effort.memoryWrites}');
    return buffer.toString();
  }

  /// Renders a [Duration] as `Hh Mm Ss` dropping leading zero units, so a
  /// just-started prompt reads `3s` and a long one reads `1h 4m 12s`. A
  /// negative or zero span (a clock skew between start and read) reads `0s`.
  static String _formatElapsed(Duration elapsed) {
    final int totalSeconds = elapsed.inSeconds;
    if (totalSeconds <= 0) return '0s';
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final parts = <String>[
      if (hours > 0) '${hours}h',
      if (minutes > 0) '${minutes}m',
      if (seconds > 0) '${seconds}s',
    ];
    return parts.join(' ');
  }
}
