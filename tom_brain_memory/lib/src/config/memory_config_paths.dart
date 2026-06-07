// MemoryConfigPaths — filesystem path resolution for a MemoryConfig.
//
// `MemoryConfig` itself is a pure value type living in
// `tom_brain_shared` (so lighter components can consume it without
// pulling `dart:io`/sqlite3/dart_mcp). The path getters below need
// `Platform.pathSeparator`, so they live here in `tom_brain_memory`
// where `dart:io` is allowed, as an extension on the shared type.
//
// The store and the migration/cursor stores consume these getters;
// the extension is re-exported from the `config/` barrel so any file
// that imports the config surface sees them on `MemoryConfig`.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryConfig;

/// Filesystem layout under [MemoryConfig.root].
///
/// The store creates `memory.db`, `vectors.db`, `trails/`,
/// `tombstones/`, and `checkpoints/` underneath the *effective data
/// directory* ([dataDir]) — which is [MemoryConfig.root] for a
/// profile-unbound config and `<root>/profiles/<profile>` when a
/// profile is bound (memory § 2.5). Resolving every operational path
/// off [dataDir] is what scopes the whole handle to one profile.
extension MemoryConfigPaths on MemoryConfig {
  /// The effective data directory for this config.
  ///
  /// `<root>` when [MemoryConfig.profile] is `null` (legacy
  /// single-tenant layout); `<root>/profiles/<profile>` when a profile
  /// is bound. All other path getters derive from this, so a
  /// profile-bound config keeps its `memory.db`, `vectors.db`, and the
  /// three subdirectories entirely inside the profile directory.
  String get dataDir {
    final p = profile;
    if (p == null) return root;
    final sep = Platform.pathSeparator;
    return '$root${sep}profiles$sep$p';
  }

  /// The `<root>/profiles/` directory that holds every profile's data
  /// directory. Independent of the bound profile — the registry lists
  /// and creates siblings here.
  String get profilesDir => '$root${Platform.pathSeparator}profiles';

  /// Resolves the `memory.db` path under [dataDir].
  String get memoryDbPath => '$dataDir${Platform.pathSeparator}memory.db';

  /// Resolves the `vectors.db` path under [dataDir].
  String get vectorsDbPath => '$dataDir${Platform.pathSeparator}vectors.db';

  /// Resolves the `trails/` directory under [dataDir].
  String get trailsDir => '$dataDir${Platform.pathSeparator}trails';

  /// Resolves the `tombstones/` directory under [dataDir].
  String get tombstonesDir => '$dataDir${Platform.pathSeparator}tombstones';

  /// Resolves the `checkpoints/` directory under [dataDir].
  String get checkpointsDir => '$dataDir${Platform.pathSeparator}checkpoints';
}
