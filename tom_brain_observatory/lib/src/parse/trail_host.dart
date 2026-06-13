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

  /// The combined run-tree log for [turnId] — the **substantive answer run**,
  /// or `null`. `procedures/<proc>/<turnId>__<runId>.log`.
  ///
  /// A single inbound turn dispatches more than one *top-level* procedure run,
  /// each written as its own `.log` file under its procedure directory: the
  /// dispatcher first runs the fast `prompt_analyzer_v1` classifier, then the
  /// chosen answer procedure (`answer_with_memory_v1` / `answer_with_thinking_v1`
  /// / …). Both files carry the same `turnId` stem, so a first-match scan over
  /// the (filesystem-ordered) procedure directories would return whichever the
  /// OS happens to list first — frequently the tiny classifier, mis-reporting a
  /// multi-minute answer as the classifier's sub-second run and hiding the real
  /// flow. We instead return the **latest-started** top-level run for the turn:
  /// the answer always starts after the classifier it was routed by, so the run
  /// with the greatest start time is the substantive one (PT-1.x). Start time is
  /// the microsecond stamp in the `run_<micros>_<seq>` token; a token without
  /// one falls back to the basename, so selection is deterministic regardless of
  /// directory-listing order.
  File? procedureLogFor(String turnId) {
    final dir = Directory(p.join(root.path, 'procedures'));
    if (!dir.existsSync()) return null;
    File? best;
    int bestStart = -1;
    String bestName = '';
    for (final proc in dir.listSync().whereType<Directory>()) {
      for (final file in proc.listSync().whereType<File>()) {
        final name = p.basename(file.path);
        if (!name.startsWith('${turnId}__') || !name.endsWith('.log')) {
          continue;
        }
        final start = _runStartMicros(name);
        if (best == null ||
            start > bestStart ||
            (start == bestStart && name.compareTo(bestName) > 0)) {
          best = file;
          bestStart = start;
          bestName = name;
        }
      }
    }
    return best;
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
