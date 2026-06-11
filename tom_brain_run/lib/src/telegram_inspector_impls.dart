// The run-layer concrete implementations of the access package's Telegram
// inspection ports (`TelegramPromptInspector` / `TelegramLogInspector` /
// `TelegramMemoryInspector`).
//
// ── Why these live here ──────────────────────────────────────────────
//
// The Telegram edge surfaces the brain's operational state — the recorded
// incoming prompts (the §5.3 `incoming/` trail), the important log files, and
// the memory overview — through three narrow read-only *port* interfaces it
// defines in `tom_brain_access`. The access package must not read the trail
// tree or the memory directly (`dependency_surface_test.dart`), so the concrete
// reads live in `tom_brain_run` — the one assembly that legally wires the trail
// writers and the memory client together. `standUpBrainProcess` builds a
// [TelegramInspectors] bundle from these and injects it at the access seam.
//
// Each implementation returns already-rendered, channel-neutral data; the edge
// owns the Telegram presentation (message formatting + the 4096-code-unit
// split), so nothing here knows about Telegram.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show
        TelegramLogInspector,
        TelegramLogTail,
        TelegramMemoryInspector,
        TelegramPromptDigest,
        TelegramPromptInspector;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show LatencyHistogram, MemoryStats, TomBrainMemoryClient;

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
