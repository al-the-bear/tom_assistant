// MemoryDirectory — owner of the on-disk layout under <memory-root>.
//
// Plan step A.26:
//   "Implement MemoryDirectory opener: creates / validates the
//    <memory-root> directory layout (memory.db, vectors.db, trails/,
//    tombstones/, checkpoints/)."
//
// Scope at A.26 is the *directory shape* only:
//
//   - `<root>/` is created if absent, validated if present.
//   - `<root>/trails/`, `<root>/tombstones/`, `<root>/checkpoints/`
//     are created if absent.
//   - The SQLite files (`memory.db`, `vectors.db`, and their WAL/SHM
//     siblings) are *not* created here — they are materialised by
//     the SQLite engine when the connection is opened in A.27+.
//     `MemoryDirectory` only resolves their absolute paths so later
//     steps can pass them to `sqlite3.open`.
//
// The class deliberately holds no SQLite handles, no file locks, and
// no in-flight state. It is a tiny value object that has the
// pleasant property of being safe to construct, copy, and compare
// without side effects. Lifecycle responsibilities (locking,
// schema bootstrap, vec0 extension load, two-DB commit log) belong
// to the higher-level store opener landing in A.27+.
//
// Concurrency stance: at A.26 a `MemoryDirectory` does **not**
// acquire a flock on `<root>/`. The contract is single-process
// (one `TomBrainMemory` instance per memory root in the same OS
// process). Cross-process safety becomes relevant once the
// multi-machine replication topology in spec § 10 lands; until
// then, adding a lock here would be speculative and would have
// to be re-thought when the topology decisions arrive. See
// `Q-A.26.1` in `prototype_implementation_questions.md`.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryConfig;

import '../config/memory_config_paths.dart';

/// The canonical filesystem view of a memory root.
///
/// Construct via [MemoryDirectory.openOrCreate]; do not instantiate
/// directly. Equality is by absolute root path — two
/// `MemoryDirectory` values pointing at the same physical directory
/// compare equal regardless of how they were opened.
final class MemoryDirectory {
  /// Absolute path to the memory root directory.
  ///
  /// Always normalised through [File.absolute] / [Directory.absolute]
  /// so downstream code can rely on the path being absolute without
  /// re-resolving.
  final String root;

  /// Absolute path to `memory.db`.
  ///
  /// May or may not exist on disk at the time this getter is read —
  /// SQLite materialises it on first connection. Use [memoryDbExists]
  /// when the call site needs to distinguish "fresh DB" from "DB
  /// already present".
  final String memoryDbPath;

  /// Absolute path to `vectors.db`. Same materialisation rules as
  /// [memoryDbPath].
  final String vectorsDbPath;

  /// Absolute path to the `trails/` subdirectory. Guaranteed to
  /// exist after [openOrCreate] returns.
  final String trailsDir;

  /// Absolute path to the `tombstones/` subdirectory. Guaranteed to
  /// exist after [openOrCreate] returns.
  final String tombstonesDir;

  /// Absolute path to the `checkpoints/` subdirectory. Guaranteed
  /// to exist after [openOrCreate] returns.
  final String checkpointsDir;

  /// Whether the root directory was newly created by this call to
  /// [openOrCreate].
  ///
  /// Useful for callers that want to log a one-time "new memory"
  /// banner or seed bootstrap rows. A re-open of an existing root
  /// always reports `false`, even if individual subdirectories were
  /// re-created.
  final bool wasCreated;

  const MemoryDirectory._({
    required this.root,
    required this.memoryDbPath,
    required this.vectorsDbPath,
    required this.trailsDir,
    required this.tombstonesDir,
    required this.checkpointsDir,
    required this.wasCreated,
  });

  /// Opens the memory directory at [config]'s effective data directory
  /// (`MemoryConfigPaths.dataDir` — `<root>` unbound, or
  /// `<root>/profiles/<profile>` when a profile is bound), creating any
  /// missing pieces of the canonical layout.
  ///
  /// Contract:
  ///
  ///   * If [MemoryConfig.root] is empty, an [ArgumentError] is
  ///     thrown. (This duplicates the check in
  ///     [MemoryConfig.forTesting] for the rare case where a host
  ///     constructed a `MemoryConfig` directly.)
  ///   * If the path exists and is not a directory (e.g., a file
  ///     was put there by mistake), a [FileSystemException] is
  ///     thrown — overwriting unrelated data is never the right
  ///     behaviour.
  ///   * Otherwise, the root and the three required subdirectories
  ///     are created if absent and left untouched if present.
  ///   * Any other I/O failure (permission denied, disk full)
  ///     surfaces as the original [FileSystemException] — callers
  ///     are expected to translate it into a domain event at the
  ///     boundary, not here.
  ///
  /// This call is **synchronous** on purpose: it runs exactly once
  /// per memory open and the host benefits from being able to
  /// resolve paths before scheduling any other async work.
  static MemoryDirectory openOrCreate(MemoryConfig config) {
    if (config.root.isEmpty) {
      throw ArgumentError.value(
        config.root,
        'config.root',
        'memory root path must be non-empty',
      );
    }

    // Scope the whole layout to the effective data directory: `<root>`
    // for a profile-unbound config, `<root>/profiles/<profile>` when a
    // profile is bound (memory § 2.5). `createSync(recursive: true)`
    // below materialises the intermediate `profiles/` segment.
    final rawRoot = config.dataDir;
    final rootDir = Directory(rawRoot);
    final rootEntityType = FileSystemEntity.typeSync(
      rawRoot,
      followLinks: true,
    );

    final bool wasCreated;
    switch (rootEntityType) {
      case FileSystemEntityType.notFound:
        // Fresh open — materialise the root.
        rootDir.createSync(recursive: true);
        wasCreated = true;
      case FileSystemEntityType.directory:
        // Existing memory; nothing to do at root level.
        wasCreated = false;
      default:
        // file / link-to-file / pipe — refuse rather than silently
        // start writing alongside whatever is there.
        throw FileSystemException(
          'memory root exists but is not a directory '
          '(entity type: $rootEntityType)',
          rawRoot,
        );
    }

    final absoluteRoot = rootDir.absolute.path;

    // The three operational subdirectories are required to be
    // present before any later step writes into them. Creating
    // them eagerly here keeps the contract simple: after
    // openOrCreate returns, every directory path is guaranteed
    // to exist on disk.
    final trails = _ensureSubdir(absoluteRoot, 'trails');
    final tombstones = _ensureSubdir(absoluteRoot, 'tombstones');
    final checkpoints = _ensureSubdir(absoluteRoot, 'checkpoints');

    return MemoryDirectory._(
      root: absoluteRoot,
      memoryDbPath: _join(absoluteRoot, 'memory.db'),
      vectorsDbPath: _join(absoluteRoot, 'vectors.db'),
      trailsDir: trails,
      tombstonesDir: tombstones,
      checkpointsDir: checkpoints,
      wasCreated: wasCreated,
    );
  }

  /// `true` iff `memory.db` is present on disk.
  bool get memoryDbExists => File(memoryDbPath).existsSync();

  /// `true` iff `vectors.db` is present on disk.
  bool get vectorsDbExists => File(vectorsDbPath).existsSync();

  /// `true` iff neither SQLite file has been materialised yet.
  ///
  /// Distinct from [wasCreated]: a host may re-open a freshly-made
  /// root that was created but never had `open()` complete on it.
  /// In that case [wasCreated] is `false` (root already existed) but
  /// [isFresh] is `true` (no DB files yet).
  bool get isFresh => !memoryDbExists && !vectorsDbExists;

  static String _ensureSubdir(String root, String name) {
    final dir = Directory(_join(root, name));
    if (!dir.existsSync()) {
      dir.createSync();
    }
    return dir.absolute.path;
  }

  static String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MemoryDirectory && other.root == root);

  @override
  int get hashCode => root.hashCode;

  @override
  String toString() => 'MemoryDirectory(root: $root, wasCreated: $wasCreated)';
}
