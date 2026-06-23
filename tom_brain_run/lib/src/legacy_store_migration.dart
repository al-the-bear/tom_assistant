// Legacy-store migration — one-shot move of a pre-profiles bare-root memory
// store into `<root>/profiles/defaultmemory_default/`
// (`memory_session_profiles.md` § 11, plan step 8, decisions MSPP-26/MSPP-27).
//
// Before the memory-profile work, the single-tenant brain opened its store
// directly at `<root>` (`memory.db`, `vectors.db`, `trails/`, `tombstones/`,
// `checkpoints/`). § 8.1 retires that bare-root layout: every profile — the
// default included — now lives under `<root>/profiles/<name>/`, and the default
// profile is `defaultmemory_default` (MSP-4). This boot-time step relocates an
// existing legacy store into that default-profile directory exactly once, so the
// boot-provisioned default client (opened at `withProfile(defaultMemoryProfile)`)
// reads the migrated data back.
//
// Scope (MSPP-26): this moves the **memory store** only. The `.root`-keyed
// non-memory stores (`session_todos.json`, `agent_sdk_sessions.json`,
// `dream_lane_sessions.json`, the Telegram edge-state dir) stay at the bare root
// — they are not memory-profile data. The § 11.2 Telegram session re-key and the
// § 11.3 stray-API-file delete ride with the prefix model in plan steps 9–11.

import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfigPaths;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show defaultMemoryProfile;
import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryConfig;

/// Outcome of a [migrateLegacyMemoryRoot] attempt.
enum LegacyMigrationOutcome {
  /// `<root>/profiles/` already existed — a prior boot migrated, or the install
  /// was born profiled. Idempotent no-op (this is what makes the second boot a
  /// no-op).
  alreadyProfiled,

  /// No legacy `<root>/memory.db` present — a fresh install with nothing to
  /// move. No-op.
  noLegacyStore,

  /// A legacy bare-root store was relocated into
  /// `<root>/profiles/defaultmemory_default/`.
  migrated,
}

/// The bare-root memory-store DB basenames. The migration moves each of these
/// **and** its SQLite sidecars (`-wal`, `-shm`, `-journal`) — the store runs in
/// WAL mode (`PRAGMA journal_mode = WAL`), so the sidecars may be present.
const List<String> _storeDbBasenames = <String>['memory.db', 'vectors.db'];

/// The bare-root memory-store subdirectories the store creates under its data
/// dir (`MemoryConfigPaths`: `trailsDir` / `tombstonesDir` / `checkpointsDir`).
const List<String> _storeSubdirs = <String>[
  'trails',
  'tombstones',
  'checkpoints',
];

/// Idempotent boot-time migration of a legacy bare-root store into the default
/// profile directory.
///
/// [baseConfig] is the **profile-unbound** run config (its `root` is the bare
/// memory root). The function is gated so repeated boots converge:
///
/// 1. If `<root>/profiles/` exists → [LegacyMigrationOutcome.alreadyProfiled]
///    (already migrated, or born profiled). Nothing is touched.
/// 2. Else if `<root>/memory.db` is absent → [LegacyMigrationOutcome.noLegacyStore]
///    (fresh install). Nothing is moved.
/// 3. Else the store artifacts (`memory.db*`, `vectors.db*` and the `trails/`,
///    `tombstones/`, `checkpoints/` directories) are renamed into
///    `<root>/profiles/defaultmemory_default/`, leaving every other bare-root
///    entry (the non-memory JSON stores) in place. Returns
///    [LegacyMigrationOutcome.migrated].
///
/// The moves are per-file/per-dir `rename`s within the same filesystem (the
/// destination is a subdirectory of `root`), so each is atomic and cheap. The
/// move *set* is not transactional — a crash between renames is not rolled back;
/// the profiles-absent gate (§ 11, step 8) plus the operator's tiered backups
/// cover that rare local-boot window. Crash-atomic migration is deliberately out
/// of scope (the plan specifies the profiles-absent gate).
LegacyMigrationOutcome migrateLegacyMemoryRoot(MemoryConfig baseConfig) {
  // Normalise to the bare-root view so the path getters resolve to `<root>`
  // regardless of any profile the caller happened to bind.
  final base = baseConfig.withProfile(null);
  final root = base.root;

  // Gate 1 — already profiled (idempotent no-op on every boot after the first).
  if (Directory(base.profilesDir).existsSync()) {
    return LegacyMigrationOutcome.alreadyProfiled;
  }

  // Gate 2 — no legacy store to move (fresh install).
  if (!File(base.memoryDbPath).existsSync()) {
    return LegacyMigrationOutcome.noLegacyStore;
  }

  // Relocate into the default profile's data directory.
  final dest = base.withProfile(defaultMemoryProfile);
  final destDir = dest.dataDir;
  final sep = Platform.pathSeparator;
  Directory(destDir).createSync(recursive: true);

  for (final entity in Directory(root).listSync()) {
    final name = _basename(entity.path);
    if (entity is File) {
      final isStoreArtifact = _storeDbBasenames
          .any((db) => name == db || name.startsWith('$db-'));
      if (isStoreArtifact) {
        entity.renameSync('$destDir$sep$name');
      }
    } else if (entity is Directory && _storeSubdirs.contains(name)) {
      entity.renameSync('$destDir$sep$name');
    }
  }

  return LegacyMigrationOutcome.migrated;
}

/// Last path segment of [path], tolerating both `/` and `\` separators (a
/// directory entry's trailing separator is already stripped by `listSync`).
String _basename(String path) {
  var end = path.length;
  // Defensive: drop a trailing separator if one slipped through.
  if (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) end -= 1;
  var start = end;
  while (start > 0 && path[start - 1] != '/' && path[start - 1] != r'\') {
    start -= 1;
  }
  return path.substring(start, end);
}
