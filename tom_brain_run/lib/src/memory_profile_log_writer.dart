// MemoryProfileLogWriter — the §5.6 per-profile memory log
// (`tom_brain_logging.md` §10 build-order step #8).
//
// For every memory access a run issues — recall / persist / edge / stackPush /
// … — the engine hands one [MemoryAccessRecord] (built at the per-run
// `MemoryBridge.onCall` seam, where the bridged primitive call meets the run's
// `runId` / `trailId` / `turnId` and the request's memory `profile`). This
// writer turns each into one line appended to `memory/<profile>.log`, each
// line linking to the authoritative
// `<memory.root>/[profiles/<profile>/]trails/<YYYY>/<MM>/<DD>/run-<runId>.jsonl`
// entry (§5.6).
//
// Profile bucketing (§5.6 / §11.1 "Q3"): the profile is the natural key for
// memory inspection — a profile *is* an isolated store — so each profile gets
// its own file. A `null` profile (a turn-less / process-default run) buckets as
// `memory/default.log`.
//
// Link construction (interpretation): the engine holds the opaque `trailId`,
// not the on-disk jsonl path, so the writer reconstructs the §2.2/§5.6 link
// shape from the record's `runId` and the UTC date of the access — the same
// `<trailsRoot>/<YYYY>/<MM>/<DD>/run-<runId>.jsonl` layout `TrailWriter`
// produces. The `<trailsRoot>` carries the `profiles/<profile>/` prefix for a
// named profile and is bare `trails/` for the unbound (default) store.
//
// Scope boundary (§10): this writer owns *only* the per-profile `.log` files
// and their size rotation (10 MB × 5, §8). The count-cap janitor (§8) is step
// #10's `TrailJanitor`, not here — consistent with `LlmTrailWriter`, which
// likewise does not prune its own tree.
//
// Best-effort and non-blocking (§9): a trail-write failure must never fail a
// turn, so every effect is guarded and a failure is swallowed.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show MemoryAccessRecord;

/// The profile name a `null`-profile (process-default) access logs under.
const String _defaultProfileName = 'default';

/// Writes the §5.6 per-profile memory log, one line per memory access
/// (`tom_brain_logging.md` §10 step #8).
final class MemoryProfileLogWriter {
  /// The trail tree root (`trail.root`). Per-profile logs land under
  /// `<root>/memory/`.
  final Directory root;

  /// The §8 size-rotation cap: a log is rotated before a write would push it
  /// past this many bytes. Defaults to 10 MB.
  final int rotateBytes;

  /// How many rotated segments to keep (`.1` … `.rotateKeep`). Defaults to 5.
  final int rotateKeep;

  /// Builds a writer rooted at [root] with the §8 rotation caps.
  MemoryProfileLogWriter({
    required this.root,
    this.rotateBytes = 10 * 1024 * 1024,
    this.rotateKeep = 5,
  });

  /// Appends the §5.6 line for [record] to its profile's log. Best-effort: any
  /// failure is swallowed so a trail write never breaks the turn (§9).
  void write(MemoryAccessRecord record) {
    final profile = record.profile ?? _defaultProfileName;
    final file = File('${root.path}/memory/$profile.log');
    _appendLine(file, _line(record));
  }

  /// The §5.6 line: `<at>  <primitive> <detail>  ↳ <link>`.
  String _line(MemoryAccessRecord record) {
    final detail = _detail(record);
    final link = _jsonlLink(record);
    return '${record.at.toIso8601String()}  '
        '${record.primitive}${detail.isEmpty ? '' : ' $detail'}'
        '  ↳ $link';
  }

  /// The primitive-specific middle of the line. `recall` carries modes / k /
  /// returned / degraded (§5.6); id-returning writes carry their new id; any
  /// other primitive falls back to its flattened result.
  String _detail(MemoryAccessRecord record) {
    switch (record.primitive) {
      case 'recall':
        return _recallDetail(record);
      case 'persist':
        return '${record.input['typeName'] ?? ''} → ${_id(record)}'.trim();
      case 'edge':
        final from = record.input['from'];
        final type = record.input['type'];
        final to = record.input['to'];
        return '$from -$type-> $to → ${_id(record)}';
      case 'stackPush':
        final name = record.input['name'];
        final nodeId = record.input['nodeId'];
        return '$name $nodeId → ${_id(record)}';
      default:
        final id = record.result['id'];
        return id == null ? '' : '→ $id';
    }
  }

  /// The recall detail: `<modes joined by +> k=<k> → <returned>[ degraded]`
  /// (§5.6 — modes, k, returned, degraded flag).
  String _recallDetail(MemoryAccessRecord record) {
    final modes = (record.input['modes'] as List?)?.cast<Object?>() ??
        const <Object?>[];
    final modeText = modes.map((m) => '$m').join('+');
    final k = record.input['k'];
    final returned = (record.result['nodes'] as List?)?.length ?? 0;
    final degraded =
        (record.result['report'] as Map?)?['degraded'] == true;
    final base = '$modeText k=$k → $returned';
    return degraded ? '$base degraded' : base;
  }

  /// The new node / edge / entry id an id-returning write produced, or the
  /// empty string when absent.
  String _id(MemoryAccessRecord record) => '${record.result['id'] ?? ''}';

  /// The §5.6 link to the authoritative jsonl entry, relative to the trail
  /// root: `[profiles/<profile>/]trails/<YYYY>/<MM>/<DD>/run-<runId>.jsonl`.
  /// A named profile carries the `profiles/<profile>/` prefix; the unbound
  /// (default) store is bare `trails/`.
  String _jsonlLink(MemoryAccessRecord record) {
    final at = record.at.toUtc();
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    final prefix =
        record.profile == null ? '' : 'profiles/${record.profile}/';
    return '${prefix}trails/$y/$m/$d/run-${record.runId}.jsonl';
  }

  /// Appends `line` (with a trailing newline) to [file], rotating it first if
  /// it would cross [rotateBytes]. Best-effort: a failure is swallowed (§9).
  void _appendLine(File file, String line) {
    try {
      final Directory parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      if (file.existsSync() &&
          file.lengthSync() + line.length + 1 > rotateBytes) {
        _rotate(file);
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: a read-only root, a path collision, or a concurrent
      // rotation race must never propagate into the logging call site.
    }
  }

  /// Shifts `<base>.<k>` → `<base>.<k+1>` (dropping the oldest) and moves
  /// `<base>` → `<base>.1`, capping the kept segments at [rotateKeep].
  void _rotate(File base) {
    try {
      final String path = base.path;
      final File oldest = File('$path.$rotateKeep');
      if (oldest.existsSync()) oldest.deleteSync();
      for (int i = rotateKeep - 1; i >= 1; i--) {
        final File segment = File('$path.$i');
        if (segment.existsSync()) segment.renameSync('$path.${i + 1}');
      }
      if (base.existsSync()) base.renameSync('$path.1');
    } catch (_) {
      // A rotation race is harmless — at worst a slightly oversize segment.
    }
  }
}
