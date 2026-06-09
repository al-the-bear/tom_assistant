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

  /// The combined run-tree log for [turnId] (the top-level run), or `null`.
  /// `procedures/<proc>/<turnId>__<runId>.log`.
  File? procedureLogFor(String turnId) {
    final dir = Directory(p.join(root.path, 'procedures'));
    if (!dir.existsSync()) return null;
    for (final proc in dir.listSync().whereType<Directory>()) {
      for (final file in proc.listSync().whereType<File>()) {
        final name = p.basename(file.path);
        if (name.startsWith('${turnId}__') && name.endsWith('.log')) {
          return file;
        }
      }
    }
    return null;
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

  /// True when the host is in unconfigured mode (no structured trail tree) —
  /// neither `incoming/` nor `procedures/` exists (§ 8.1).
  bool get isUnconfigured =>
      !Directory(p.join(root.path, 'incoming')).existsSync() &&
      !Directory(p.join(root.path, 'procedures')).existsSync();

  /// Mirrors the writers' file-stem sanitisation (`summary_fanout.dart`).
  static String _sanitize(String token) =>
      token.replaceAll(RegExp(r'[\\/\s]+'), '_');
}
