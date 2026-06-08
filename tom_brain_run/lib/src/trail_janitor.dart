// TrailJanitor — the §8 overgrowth-cap enforcer + the §7 `.gitignore`
// (`tom_brain_logging.md` §10 step #10).
//
// The trail tree grows without bound on its own: every turn dumps a raw
// `llm/<role>/…raw.json`, every admitted request an `incoming/<channel>/…`,
// every top-level run a `procedures/<proc>/…log`. §8 caps that growth. The
// janitor is the enforcer the §8 "Enforcement" paragraph names: it runs at
// process boot, is idempotent, and applies the count / aggregate-size caps that
// are NOT already enforced inline by a writer.
//
// Division of labour (§8 / §10) — the janitor owns exactly the caps no other
// component does:
//
//   * SIZE ROTATION of the log files (`brain.log`, `components/*.log`,
//     `memory/*.log`, 10 MB × 5) is owned by `FanoutLogOutput` (step #3) and
//     `MemoryProfileLogWriter` (step #8), which rotate on append.
//   * The PROMPT-COUNT CAP on the versioned summaries (`sessions/*.summary.md`,
//     `summary/…`, 1000 turns) and the live-trail rolling window (20 turns) are
//     owned by the summary writers (steps #5 / #6), which read-modify-rewrite on
//     every turn so the cap holds across restarts.
//   * The janitor owns the RAW-TIER caps: the per-folder count caps
//     (`llm/<role>/`, `incoming/<channel>/`, `procedures/<proc>/`; keep newest
//     N, delete oldest) and the aggregate raw-size ceiling across those three
//     trees (oldest-first eviction). It also writes the §7 `.gitignore`.
//
// "Newest" / "oldest" is ordered by file mtime, tie-broken by filename — the
// raw filenames embed a `turn_<ULID>` prefix (time-sortable), so mtime and name
// agree for turn-bound files and the mtime is the authoritative recency signal
// for the run-id-keyed fallbacks. Eviction never touches the versioned summary
// tier (`sessions/`, `summary/`) — only the three git-ignored raw trees.
//
// Boot only (§8 reconciliation): §8 asks the janitor to run "(a) at process
// boot and (b) folded into the memory sleep cadence". The prototype has no
// wired periodic sleep cadence yet (the dream agents are procedures, not a
// timer), so the janitor runs at boot only; the sleep-cadence fold lands when a
// cadence exists. Idempotency makes the boot-only run safe to repeat.
//
// Best-effort and non-blocking (§9): a janitor failure must never fail a boot,
// so each phase is guarded and a failure is swallowed.

import 'dart:io';

import 'trail_config.dart' show TrailConfig;

/// Enforces the §8 raw-tier overgrowth caps and writes the §7 `.gitignore`.
///
/// Construct from a [TrailConfig] via [TrailJanitor.fromConfig], or directly
/// with explicit caps. Call [sweep] once at process boot.
final class TrailJanitor {
  /// The trail tree root (`trail.root`). The raw tiers live under
  /// `<root>/{llm,incoming,procedures}/`; the `.gitignore` lands at `<root>/`.
  final Directory root;

  /// Count cap per `llm/<role>/` folder — keep newest, delete oldest (§8).
  final int llmPerRoleCap;

  /// Count cap per `incoming/<channel>/` folder (§8).
  final int incomingPerChannelCap;

  /// Count cap per `procedures/<proc>/` folder (§8).
  final int proceduresPerKindCap;

  /// Aggregate raw-size ceiling (MB) across `llm/` + `incoming/` +
  /// `procedures/`; oldest-first eviction when exceeded (§8).
  final int rawAggregateSizeMb;

  /// Builds a janitor rooted at [root] with explicit caps (defaults match §8).
  TrailJanitor({
    required this.root,
    this.llmPerRoleCap = 300,
    this.incomingPerChannelCap = 300,
    this.proceduresPerKindCap = 300,
    this.rawAggregateSizeMb = 1024,
  });

  /// Builds a janitor from the resolved [config] — the caps come straight off
  /// the `trail:` block (§8), and `root` is `Directory(config.root)`.
  factory TrailJanitor.fromConfig(TrailConfig config) => TrailJanitor(
        root: Directory(config.root),
        llmPerRoleCap: config.llmPerRoleCap,
        incomingPerChannelCap: config.incomingPerChannelCap,
        proceduresPerKindCap: config.proceduresPerKindCap,
        rawAggregateSizeMb: config.rawAggregateSizeMb,
      );

  /// The three git-ignored raw tiers the count + aggregate caps police.
  static const List<String> _rawTiers = <String>['llm', 'incoming', 'procedures'];

  /// The §7 raw-tier ignore body. The summary tier (`sessions/`, `summary/`) is
  /// intentionally absent — it is versioned.
  static const String _gitignoreBody =
      '# Raw / operational tier — machine-local, pruned. Never versioned.\n'
      'brain.log*\n'
      'components/\n'
      'memory/\n'
      'llm/\n'
      'incoming/\n'
      'procedures/\n'
      '# Summary tier (sessions/, summary/) is intentionally NOT ignored — '
      'it is versioned.\n';

  /// Runs the full boot-time pass: write the §7 `.gitignore`, enforce the
  /// per-folder count caps, then enforce the aggregate raw-size ceiling. Each
  /// phase is independently best-effort, and the whole sweep is guarded, so a
  /// janitor failure never propagates into the boot path (§9). Idempotent.
  void sweep() {
    try {
      _ensureGitignore();
      _enforceCountCaps();
      _enforceAggregateSize();
    } catch (_) {
      // Best-effort: a read-only root or a listing race must never break boot.
    }
  }

  /// Writes the §7 `.gitignore` if it is missing or its body has drifted,
  /// creating the trail root if it does not exist yet (so the ignore is in
  /// place before the first raw file is ever written).
  void _ensureGitignore() {
    try {
      if (!root.existsSync()) root.createSync(recursive: true);
      final file = File('${root.path}/.gitignore');
      if (file.existsSync() && file.readAsStringSync() == _gitignoreBody) {
        return;
      }
      file.writeAsStringSync(_gitignoreBody, flush: true);
    } catch (_) {
      // Best-effort (§9).
    }
  }

  /// Enforces the per-folder count cap on each subfolder of the three raw
  /// tiers (one cap per tier — role / channel / procedure).
  void _enforceCountCaps() {
    _capSubfolders('llm', llmPerRoleCap);
    _capSubfolders('incoming', incomingPerChannelCap);
    _capSubfolders('procedures', proceduresPerKindCap);
  }

  /// Trims every immediate subfolder of `<root>/<tier>/` to the newest [cap]
  /// files, deleting the oldest beyond it.
  void _capSubfolders(String tier, int cap) {
    try {
      final tierDir = Directory('${root.path}/$tier');
      if (!tierDir.existsSync()) return;
      for (final entity in tierDir.listSync()) {
        if (entity is Directory) _keepNewest(entity, cap);
      }
    } catch (_) {
      // Best-effort (§9).
    }
  }

  /// Keeps the newest [cap] files in [folder]; deletes the rest oldest-first.
  void _keepNewest(Directory folder, int cap) {
    final files = folder.listSync().whereType<File>().toList();
    if (files.length <= cap) return;
    files.sort(_newestFirst);
    for (final file in files.skip(cap)) {
      _deleteQuietly(file);
    }
  }

  /// Enforces the aggregate raw-size ceiling across the three raw tiers,
  /// evicting oldest-first until the total is back under the ceiling. The
  /// versioned summary tier is never considered.
  void _enforceAggregateSize() {
    try {
      final ceiling = rawAggregateSizeMb * 1024 * 1024;
      final files = <File>[];
      var total = 0;
      for (final tier in _rawTiers) {
        final dir = Directory('${root.path}/$tier');
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is! File) continue;
          files.add(entity);
          total += _sizeOf(entity);
        }
      }
      if (total <= ceiling) return;
      files.sort(_oldestFirst);
      for (final file in files) {
        if (total <= ceiling) break;
        final size = _sizeOf(file);
        if (_deleteQuietly(file)) total -= size;
      }
    } catch (_) {
      // Best-effort (§9).
    }
  }

  /// Newest first: descending mtime, tie-broken by descending filename.
  int _newestFirst(File a, File b) {
    final byTime = _mtimeOf(b).compareTo(_mtimeOf(a));
    return byTime != 0 ? byTime : _nameOf(b).compareTo(_nameOf(a));
  }

  /// Oldest first: ascending mtime, tie-broken by ascending filename.
  int _oldestFirst(File a, File b) => -_newestFirst(a, b);

  /// The file's mtime, or the epoch when it cannot be stat'd (so an unreadable
  /// file sorts as oldest and is evicted first).
  DateTime _mtimeOf(File file) {
    try {
      return file.statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// The file's byte length, or `0` when it cannot be read.
  int _sizeOf(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// The file's basename.
  String _nameOf(File file) => file.uri.pathSegments.last;

  /// Deletes [file], swallowing any failure; returns whether it is now gone.
  bool _deleteQuietly(File file) {
    try {
      file.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }
}
