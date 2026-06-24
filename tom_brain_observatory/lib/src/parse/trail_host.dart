// Read-only accessor over one host's trail tree
// (`_ai/tom_brain_trail/<host>/`, `prompt_tracing.md` § 8.1).
//
// Every method opens files for reading only — the observatory never creates,
// truncates, or modifies a file under the trail root (OBS-1, § 6.2). The class
// holds no cache: each call is a fresh read of the immutable trail (§ 8.3), so a
// response can never diverge from what the brain wrote.
//
// "Unconfigured mode" (§ 8.1): when the brain runs without a `trail.root`, only
// `brain.log` + `components/*.log` exist — no `incoming/`, `procedures/`,
// `summary/`. Every accessor here returns empty/`null` in that case; absence is
// never an error (§ 4.1).

import 'dart:io';

import 'package:path/path.dart' as p;

/// A read-only view of one host's trail tree, rooted at the host directory
/// (the directory holding `incoming/`, `procedures/`, `llm/`, `sessions/`,
/// `summary/`, …).
final class TrailHost {
  /// The host directory (`<trailRoot>/<host>`).
  final Directory root;

  TrailHost(this.root);

  /// Builds a host view from a filesystem [path].
  factory TrailHost.at(String path) => TrailHost(Directory(path));

  /// The raw incoming record file for [turnId] across any channel, or `null`
  /// when none exists. `incoming/<channel>/<turnId>.raw.json`.
  File? incomingFile(String turnId) {
    final dir = Directory(p.join(root.path, 'incoming'));
    if (!dir.existsSync()) return null;
    for (final channel in dir.listSync().whereType<Directory>()) {
      final file = File(p.join(channel.path, '$turnId.raw.json'));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// All incoming record files across every channel, unsorted.
  List<File> incomingFiles() {
    final dir = Directory(p.join(root.path, 'incoming'));
    if (!dir.existsSync()) return const <File>[];
    return <File>[
      for (final channel in dir.listSync().whereType<Directory>())
        ...channel
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.raw.json')),
    ];
  }

  /// Every combined run-tree log for [turnId] — **all** of the turn's top-level
  /// procedure runs — in **start order** (earliest first).
  /// `procedures/<proc>/<turnId>__<runId>.log`.
  ///
  /// A single inbound turn dispatches more than one top-level procedure run,
  /// each written as its own `.log` file under its procedure directory: the
  /// dispatcher first runs the fast `prompt_analyzer_v1` classifier, then the
  /// chosen answer procedure (`answer_with_memory_v1` / `answer_with_thinking_v1`
  /// / …). Both files carry the same `turnId` stem. Returning only one (e.g. the
  /// latest-started) hides whole procedures and every secondary LLM / memory
  /// call they made, so the operator must see them all (`prompt_tracing.md`
  /// § 3.2). Start time is the microsecond stamp in the `run_<micros>_<seq>`
  /// token; a token without one falls back to the basename, so ordering is
  /// deterministic regardless of directory-listing order. The classifier sorts
  /// first (it starts before the answer it routes to); the substantive answer
  /// run sorts last.
  List<File> procedureLogsFor(String turnId) {
    final dir = Directory(p.join(root.path, 'procedures'));
    if (!dir.existsSync()) return const <File>[];
    final logs = <File>[
      for (final proc in dir.listSync().whereType<Directory>())
        for (final file in proc.listSync().whereType<File>())
          if (p.basename(file.path).startsWith('${turnId}__') &&
              file.path.endsWith('.log'))
            file,
    ];
    logs.sort((a, b) {
      final byStart = _runStartMicros(p.basename(a.path))
          .compareTo(_runStartMicros(p.basename(b.path)));
      return byStart != 0
          ? byStart
          : p.basename(a.path).compareTo(p.basename(b.path));
    });
    return logs;
  }

  /// The single **substantive answer run** for [turnId] — the latest-started of
  /// the turn's top-level runs (the answer always starts after the classifier it
  /// was routed by), or `null` when the turn has none. Used only where a single
  /// representative log is needed (LLM-link resolution); the full surface uses
  /// [procedureLogsFor].
  File? procedureLogFor(String turnId) {
    final logs = procedureLogsFor(turnId);
    return logs.isEmpty ? null : logs.last;
  }

  /// Every **turn-less dream/free-time run** log across all procedure
  /// directories, newest-first by file modification time
  /// (`prompt_tracing.md` § 5A.3).
  ///
  /// `ProcedureTreeWriter` keys a turn-bound run `<turnId>__<runId>.log` and a
  /// turn-less run the bare `<runId>.log`. Turn ids and run ids contain only
  /// single underscores; `__` is the separator. So a dream run is exactly a
  /// `procedures/<proc>/*.log` whose basename contains **no** `__`. A dream has
  /// no `incoming/` record and no `turnId`, so it never appears in the prompt
  /// list (§ 4.1) — this is its only discovery path. Returns an empty list in
  /// unconfigured mode.
  List<File> dreamRunLogs() {
    final dir = Directory(p.join(root.path, 'procedures'));
    if (!dir.existsSync()) return const <File>[];
    final logs = <File>[
      for (final proc in dir.listSync().whereType<Directory>())
        for (final file in proc.listSync().whereType<File>())
          if (file.path.endsWith('.log') &&
              !p.basename(file.path).contains('__'))
            file,
    ];
    logs.sort((a, b) {
      final byTime = b.statSync().modified.compareTo(a.statSync().modified);
      return byTime != 0
          ? byTime
          : p.basename(a.path).compareTo(p.basename(b.path));
    });
    return logs;
  }

  /// The single turn-less dream-run log whose [runId] matches (basename
  /// `<runId>.log`, no `__`), searched across every `procedures/<proc>/`
  /// directory, or `null` when none exists (§ 5A.4 → `404`).
  File? dreamRunLog(String runId) {
    final dir = Directory(p.join(root.path, 'procedures'));
    if (!dir.existsSync()) return null;
    final target = '$runId.log';
    for (final proc in dir.listSync().whereType<Directory>()) {
      final file = File(p.join(proc.path, target));
      if (file.existsSync() && !runId.contains('__')) return file;
    }
    return null;
  }

  /// The run-start microsecond stamp encoded in a procedure-log basename's
  /// `…__run_<micros>_<seq>.log` token, or `-1` when the token carries none
  /// (so such files order purely by basename). Reverses the writer's run-id
  /// shape; the stamp is monotonic in run-start order.
  static int _runStartMicros(String basename) {
    final match = RegExp(r'__run_(\d+)_').firstMatch(basename);
    if (match == null) return -1;
    return int.tryParse(match.group(1)!) ?? -1;
  }

  /// Resolves a run-tree `.log` link (`../../llm/<role>/<stem>.raw.json`,
  /// relative to the `procedures/<proc>/` folder) to its absolute raw-dump file.
  /// [procedureLog] is the `.log` file the link came from.
  File llmRawFromLink(File procedureLog, String relativeLink) =>
      File(p.normalize(p.join(procedureLog.parent.path, relativeLink)));

  /// The session narrative summary file for [sessionId], or `null`.
  /// `sessions/<sessionId>.summary.md`.
  File? sessionSummaryFile(String sessionId) {
    final file = File(
      p.join(root.path, 'sessions', '${_sanitize(sessionId)}.summary.md'),
    );
    return file.existsSync() ? file : null;
  }

  /// The per-session streaming live-trail file for [sessionId]
  /// (`sessions/<sessionId>.live-trail.md`, § 3.5, § 4.8), which the brain
  /// appends one block per cognitive step. Returns the (possibly absent)
  /// `File` so the live-tail can watch a path that does not exist yet.
  File sessionLiveTrailFile(String sessionId) => File(
        p.join(root.path, 'sessions', '${_sanitize(sessionId)}.live-trail.md'),
      );

  /// The live-trail file whose stream currently contains [turnId]'s prompt
  /// block (`## 🚀 PROMPT <turnId> …`), or `null` when no session has written
  /// that turn yet. Scans `sessions/*.live-trail.md` read-only.
  File? liveTrailFileForTurn(String turnId) {
    final dir = Directory(p.join(root.path, 'sessions'));
    if (!dir.existsSync()) return null;
    final marker = '## 🚀 PROMPT $turnId ';
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.live-trail.md')) continue;
      if (file.readAsLinesSync().any((line) => line.startsWith(marker))) {
        return file;
      }
    }
    return null;
  }

  /// True when the host is in unconfigured mode (no structured trail tree) —
  /// neither `incoming/` nor `procedures/` exists (§ 8.1).
  bool get isUnconfigured =>
      !Directory(p.join(root.path, 'incoming')).existsSync() &&
      !Directory(p.join(root.path, 'procedures')).existsSync();

  /// Mirrors the writers' file-stem sanitisation (`summary_fanout.dart`).
  static String _sanitize(String token) =>
      token.replaceAll(RegExp(r'[\\/\s]+'), '_');
}
