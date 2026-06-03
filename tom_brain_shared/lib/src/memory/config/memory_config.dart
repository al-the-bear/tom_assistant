// MemoryConfig — root configuration for the memory subsystem
// (memory_specification.md § 14).
//
// One structured value, handed to `TomBrainMemory.open()` by the
// host component (Tom Assistant, the procedure engine, a test
// harness). Memory **does not parse YAML itself** — config is
// loaded and validated upstream by `tom_build_base` and arrives
// here as an already-typed `MemoryConfig`.
//
// The YAML shape this maps to is documented inline in § 14 of the
// spec; the round-trip parser lives in whichever component owns
// the config file.
//
// `MemoryConfig` itself is a pure value type (no `dart:io`) so it can
// live in `tom_brain_shared` and be consumed by lighter components.
// The filesystem path getters (`memory.db`, `vectors.db`, `trails/`,
// …) — which need `Platform.pathSeparator` — live on the
// `MemoryConfigPaths` extension in `tom_brain_memory`
// (`config/memory_config_paths.dart`), where `dart:io` is allowed.

/// sqlite-vec FFI extension configuration.
///
/// Two ways to point at the `vec0` binary, checked in this order by the
/// loader (`vec_extension_loader.dart`):
///
///   1. [extensionPath] — an explicit absolute path. When non-empty it
///      wins; this is the override for ad-hoc / non-standard builds.
///   2. [binariesRoot] — the in-quest `tom_binaries/sqlite_vec/`
///      directory. When [extensionPath] is empty and this is set, the
///      loader resolves `<binariesRoot>/<platform>/vec0.<ext>` for the
///      running platform via `SqliteVecBinaryResolver` (todo #2, P1.1).
///
/// When both are empty the loader treats the vector runtime as
/// unconfigured and refuses to boot (Q-A.6.1: vector search is
/// mandatory; there is no BM25-only fallback).
final class SqliteVecConfig {
  /// Explicit absolute path to the `vec0.so` / `vec0.dylib` /
  /// `vec0.dll` binary. Empty when resolution should fall to
  /// [binariesRoot]. The store boot-time check verifies the binary
  /// version matches the schema version (§ 2.2 Option A).
  final String extensionPath;

  /// Path to the `tom_binaries/sqlite_vec/` directory holding the
  /// per-platform `vec0` binaries shipped in-quest. Empty when an
  /// explicit [extensionPath] is used instead. The platform tuple and
  /// the library filename are resolved from the running platform, so
  /// one config value works across Linux / macOS / Windows.
  final String binariesRoot;

  const SqliteVecConfig({
    this.extensionPath = '',
    this.binariesRoot = '',
  });
}

/// Retrieval tunables (§ 6.2, § 14).
final class RetrievalConfig {
  /// RRF smoothing constant. Default 60.
  final int rrfK;

  /// MMR lambda. Default 0.7.
  final double mmrLambda;

  const RetrievalConfig({
    this.rrfK = 60,
    this.mmrLambda = 0.7,
  });
}

/// Trail-storage tunables (§ 8.4, § 14).
final class TrailsConfig {
  /// Whether each `appendTrail` fsyncs before returning.
  /// Production: `true`. Test harnesses sometimes set `false`
  /// for speed.
  final bool fsyncEveryAppend;

  /// Age threshold for transparent gzip compression.
  final Duration compressAfter;

  /// Age threshold for cold-storage offloading.
  final Duration coldStorageAfter;

  const TrailsConfig({
    this.fsyncEveryAppend = true,
    this.compressAfter = const Duration(days: 7),
    this.coldStorageAfter = const Duration(days: 90),
  });
}

/// Classification tunables (§ 7.2, § 14).
final class ClassificationConfig {
  /// Best-similarity threshold for the `confident` band.
  final double minConfidence;

  /// Best-vs-second margin threshold for the `confident` band.
  final double minMargin;

  /// Minimum number of accepted examples a type needs before its
  /// centroid is computed at all (§ 7.1 "cold-started type").
  final int coldStartMinExamples;

  const ClassificationConfig({
    this.minConfidence = 0.55,
    this.minMargin = 0.05,
    this.coldStartMinExamples = 8,
  });
}

/// Default write-budget bundle (§ 9.3, § 14).
///
/// Per-agent overrides live in the agent registry; this is the
/// fallback when no override is registered.
final class DefaultWriteBudgetConfig {
  final int maxNodes;
  final int maxEdges;
  final int maxStackEntries;

  const DefaultWriteBudgetConfig({
    this.maxNodes = 5000,
    this.maxEdges = 20000,
    this.maxStackEntries = 1000,
  });
}

/// Budget tunables (§ 9.3, § 14).
final class BudgetsConfig {
  final DefaultWriteBudgetConfig defaultWriteBudget;

  const BudgetsConfig({
    this.defaultWriteBudget = const DefaultWriteBudgetConfig(),
  });
}

/// MCP server tunables (§ 3.2, § 14).
final class McpServerConfig {
  /// Whether the MCP server starts at `open()` time.
  final bool enabled;

  /// Bind address for the MCP server. `null` when [enabled] is
  /// `false`.
  final String? bindAddress;

  /// Bind port for the MCP server. `null` when [enabled] is
  /// `false`.
  final int? bindPort;

  /// Bearer-token realm passed to `TomBearerAuthentication`.
  final String? bearerAuthRealm;

  const McpServerConfig({
    this.enabled = false,
    this.bindAddress,
    this.bindPort,
    this.bearerAuthRealm,
  });
}

/// Replication role for the multi-machine deployment (§ 10).
enum ReplicationRole {
  /// The canonical authority — holds the authoritative DBs.
  authority,

  /// A cognitive worker — read from authority via MCP, submit
  /// writes back.
  worker,

  /// A laptop mirror — subscribe to the write log; read-only
  /// locally.
  mirror,
}

/// Replication tunables (§ 10, § 14).
final class ReplicationConfig {
  /// Which role this node plays.
  final ReplicationRole role;

  /// Write-log directory (authority only). `null` for
  /// `worker` and `mirror`.
  final String? writeLogDir;

  /// Authority MCP endpoint (worker / mirror only). `null` for
  /// `authority`.
  final String? authorityEndpoint;

  const ReplicationConfig({
    this.role = ReplicationRole.authority,
    this.writeLogDir,
    this.authorityEndpoint,
  });
}

/// Root configuration handed to `TomBrainMemory.open`.
///
/// Constructed by the host component from its parsed YAML.
/// The shape mirrors § 14 of `memory_specification.md`.
final class MemoryConfig {
  /// Absolute path to the memory root directory. The store
  /// creates `memory.db`, `vectors.db`, `trails/`, `tombstones/`,
  /// and `checkpoints/` underneath.
  final String root;

  /// sqlite-vec extension configuration.
  final SqliteVecConfig sqliteVec;

  /// Retrieval tunables.
  final RetrievalConfig retrieval;

  /// Trail-storage tunables.
  final TrailsConfig trails;

  /// Classification tunables.
  final ClassificationConfig classification;

  /// Budget tunables.
  final BudgetsConfig budgets;

  /// MCP-server tunables.
  final McpServerConfig mcpServer;

  /// Replication tunables.
  final ReplicationConfig replication;

  const MemoryConfig({
    required this.root,
    required this.sqliteVec,
    this.retrieval = const RetrievalConfig(),
    this.trails = const TrailsConfig(),
    this.classification = const ClassificationConfig(),
    this.budgets = const BudgetsConfig(),
    this.mcpServer = const McpServerConfig(),
    this.replication = const ReplicationConfig(),
  });

  /// Convenience constructor for tests: a single-rooted config
  /// pointing at a temp directory with sensible defaults and
  /// MCP server disabled.
  ///
  /// The host (production) constructor lives on the YAML loader;
  /// this one is for unit / integration tests that don't need a
  /// realistic config file.
  factory MemoryConfig.forTesting({
    required String root,
    String extensionPath = '',
    String binariesRoot = '',
  }) {
    if (root.isEmpty) {
      throw ArgumentError.value(root, 'root', 'must be non-empty');
    }
    return MemoryConfig(
      root: root,
      sqliteVec: SqliteVecConfig(
        extensionPath: extensionPath,
        binariesRoot: binariesRoot,
      ),
    );
  }
}
