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
/// `tombstones/`, and `checkpoints/` underneath the configured root.
extension MemoryConfigPaths on MemoryConfig {
  /// Resolves the `memory.db` path under [root].
  String get memoryDbPath => '$root${Platform.pathSeparator}memory.db';

  /// Resolves the `vectors.db` path under [root].
  String get vectorsDbPath => '$root${Platform.pathSeparator}vectors.db';

  /// Resolves the `trails/` directory under [root].
  String get trailsDir => '$root${Platform.pathSeparator}trails';

  /// Resolves the `tombstones/` directory under [root].
  String get tombstonesDir => '$root${Platform.pathSeparator}tombstones';

  /// Resolves the `checkpoints/` directory under [root].
  String get checkpointsDir => '$root${Platform.pathSeparator}checkpoints';
}
