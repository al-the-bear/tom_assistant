// VecExtensionLoader — boot-time loader for the sqlite-vec (vec0)
// shared-library extension (Plan step A.50).
//
// Vector search is mandatory inside this quest (Q-A.6.1, re-ratified
// 2026-06-03): "the system only works if vector search is possible.
// The memory system must be able to run with vector always." The
// earlier fail-open ruling (boot BM25-only when vec0 is absent) is
// revoked. The brain now **refuses to boot** when the extension is
// not loadable.
//
// Role in the open path (will be wired at A.28+ when the concrete
// `SqliteTomBrainMemory.open()` lands; today the loader is wired into
// the storage open path via integration tests and the wiring helper
// `loadVecExtensionOrRefuseToBoot`):
//
//   1. Host calls `MemoryDirectory.openOrCreate(config)`.
//   2. Host opens `memory.db` and runs `BootIntegrityCheck`.
//   3. Host calls `loadVecExtensionOrRefuseToBoot(...)`:
//        a. The loader resolves `config.sqliteVec.extensionPath`.
//        b. If the path is empty, missing, or points at a file that
//           fails to load / register, a `VectorRuntimeUnavailable`
//           exception is thrown and `open()` aborts. There is no
//           BM25-only fallback.
//        c. If the load succeeds, the typed result is returned and
//           `open()` proceeds.
//   4. A.51+ relies on the load having succeeded for every vector-mode
//      write (`persist` with embedding) and every vector-mode recall
//      path — there is no degraded mode to gate against.
//
// Why refuse-to-boot is the engineered behaviour:
//
//   A memory subsystem that silently drops to BM25-only mode answers
//   recalls with a strictly weaker index than the one the rest of the
//   brain assumes. Per principle 6 ("no event is ever truly lost") and
//   the data-integrity ruling, a degraded boot is a defect, not a
//   configuration choice. Failing loudly at boot forces the operator
//   to publish the binary (Plan step A.6) before the brain serves a
//   single recall.
//
// Why the loader is exception-free and the wiring helper raises:
//
//   The loader is reused by the BootIntegrityCheck path (A.29 today
//   under a different probe), by integration tests, and (later) by
//   the open() path. Tests assert on the typed result object directly;
//   the open() path wants a hard refuse-to-boot. Keeping the raise in
//   a thin wrapper preserves the loader as a pure value-returning
//   function whose every branch is inspectable without a try/catch.
//
// Why dependency injection (opener / lookup / registrar):
//
//   The success path of the loader requires a real vec0 binary on
//   disk. Until the binary is published into `tom_binaries/sqlite_vec/`
//   (Plan step A.6), the failure paths would also be untestable because
//   every test would have to provide a real shared library that *fails*
//   on dlopen or symbol lookup in a controlled way. The injected
//   functions make every branch deterministic and platform-neutral;
//   production wiring uses the defaults.

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../config/memory_config.dart';

/// Outcome of one `VecExtensionLoader.load(...)` call.
///
/// Three states, not two:
///
///   * `loaded`      — the extension is registered with
///                     `sqlite3_auto_extension` and every subsequent
///                     `Database` opened through the same `Sqlite3`
///                     instance will receive vec0 functions.
///   * `unavailable` — the extension is not present (configuration
///                     empty, file missing). The binary has not been
///                     published yet; the brain refuses to boot.
///   * `failed`      — the extension is present but could not be
///                     loaded (broken binary, wrong arch, missing
///                     entrypoint, registration error). The brain
///                     refuses to boot; a *fix* is required.
///
/// Both non-`loaded` outcomes abort boot via [VectorRuntimeUnavailable].
/// The distinction still matters for the operator UI: a freshly-cloned
/// workspace on a machine without the binary is `unavailable` (publish
/// the binary); a CI environment with a broken binary is `failed`
/// (fix the binary). The exception's `wasError` flag carries the
/// distinction.
enum VecLoadOutcome { loaded, unavailable, failed }

/// Categorical reason a load did not reach [VecLoadOutcome.loaded].
///
/// Each branch maps 1:1 to a specific stage of the loader pipeline so
/// that operator-facing tooling can offer a targeted next step
/// without parsing the freeform summary string. The set is closed —
/// any future reason must be added here and documented in the
/// operator UI legend.
enum VecUnavailableReason {
  /// `MemoryConfig.sqliteVec.extensionPath` is the empty string.
  /// Maps to `VecLoadOutcome.unavailable`. Expected on developer
  /// machines that have not configured a binary path.
  notConfigured,

  /// The configured path does not exist on disk. Maps to
  /// `VecLoadOutcome.unavailable`. Most often: the binary has not
  /// been pulled into `tom_binaries/sqlite_vec/<platform>/` yet
  /// (see Plan step A.6).
  fileMissing,

  /// `DynamicLibrary.open(path)` threw. Maps to
  /// `VecLoadOutcome.failed`. Most often: file exists but is not a
  /// shared library, wrong CPU arch, missing transitive symbol.
  dynamicLibraryError,

  /// `DynamicLibrary.lookup(symbol)` threw — the library opened but
  /// does not export the expected entrypoint. Maps to
  /// `VecLoadOutcome.failed`. Most often: pointed at the wrong
  /// shared library entirely (e.g. libc instead of vec0).
  symbolMissing,

  /// `sqlite3.ensureExtensionLoaded(...)` threw. Maps to
  /// `VecLoadOutcome.failed`. Most often: sqlite_auto_extension
  /// signalled an error from the extension's init function.
  registrationFailed,
}

/// Result of one [VecExtensionLoader.load] call.
///
/// Immutable. Tests assert on the typed fields; production wiring
/// uses [isLoaded] / [isUnavailable] / [isFailed] as gates.
final class VecExtensionLoadResult {
  /// Coarse outcome category.
  final VecLoadOutcome outcome;

  /// The configured path the loader inspected. May be the empty
  /// string when [reason] is [VecUnavailableReason.notConfigured].
  final String extensionPath;

  /// The categorical reason the load did not reach `loaded`. `null`
  /// when [outcome] is [VecLoadOutcome.loaded].
  final VecUnavailableReason? reason;

  /// One-line human-readable summary. For non-`loaded` outcomes this
  /// is the operator-facing message; for `loaded` it confirms which
  /// path + entrypoint succeeded.
  final String summary;

  /// Originating exception when [outcome] is [VecLoadOutcome.failed];
  /// `null` for `loaded` and `unavailable`.
  final Object? cause;

  const VecExtensionLoadResult({
    required this.outcome,
    required this.extensionPath,
    required this.summary,
    this.reason,
    this.cause,
  });

  /// `true` iff the extension is now registered with
  /// `sqlite3_auto_extension`.
  bool get isLoaded => outcome == VecLoadOutcome.loaded;

  /// `true` iff the extension was not present (configuration choice
  /// or operator omission).
  bool get isUnavailable => outcome == VecLoadOutcome.unavailable;

  /// `true` iff the extension was present but could not be loaded (a
  /// fix is required).
  bool get isFailed => outcome == VecLoadOutcome.failed;

  @override
  String toString() =>
      'VecExtensionLoadResult(outcome: $outcome, '
      'extensionPath: $extensionPath, reason: $reason, summary: $summary)';
}

/// Default-replaceable signature for `DynamicLibrary.open`. Tests
/// inject overrides to drive the `dynamicLibraryError` branch
/// deterministically.
typedef DynamicLibraryOpener = DynamicLibrary Function(String path);

/// Default-replaceable signature for `DynamicLibrary.lookup<Void>`.
/// Tests inject overrides to drive the `symbolMissing` branch.
typedef DynamicLibrarySymbolLookup = Pointer<Void> Function(
  DynamicLibrary library,
  String symbol,
);

/// Default-replaceable signature for
/// `Sqlite3.ensureExtensionLoaded`. Tests inject overrides to drive
/// the `registrationFailed` branch and to verify the loader did NOT
/// call into sqlite3 on the unavailable branches.
typedef ExtensionRegistrar = void Function(
  Sqlite3 sqlite,
  SqliteExtension extension,
);

/// Boot-time loader for the sqlite-vec (vec0) shared library.
///
/// One instance per process. Holds no per-call state; the same
/// instance is reused across opens.
final class VecExtensionLoader {
  /// Default entrypoint symbol exported by the vec0 build.
  ///
  /// Matches the symbol the upstream `sqlite-vec` repo declares
  /// (`SQLITE_EXTENSION_INIT1`). Overridable for ad-hoc operator
  /// scripts that ship a non-standard build; the default is the
  /// production wiring.
  static const String defaultEntrypointSymbol = 'sqlite3_vec_init';

  final String entrypointSymbol;
  final DynamicLibraryOpener _open;
  final DynamicLibrarySymbolLookup _lookup;
  final ExtensionRegistrar _register;

  /// Constructs the loader.
  ///
  /// Every injection point is optional and has a production default:
  ///
  ///   * [entrypointSymbol]  — defaults to [defaultEntrypointSymbol].
  ///   * [openDynamicLibrary] — defaults to `DynamicLibrary.open`.
  ///   * [lookupSymbol]       — defaults to
  ///                            `(lib, sym) => lib.lookup<Void>(sym)`.
  ///   * [registerExtension]  — defaults to
  ///                            `(sqlite, ext) => sqlite.ensureExtensionLoaded(ext)`.
  ///
  /// Tests pass overrides; production wiring uses the defaults.
  VecExtensionLoader({
    this.entrypointSymbol = defaultEntrypointSymbol,
    DynamicLibraryOpener? openDynamicLibrary,
    DynamicLibrarySymbolLookup? lookupSymbol,
    ExtensionRegistrar? registerExtension,
  })  : _open = openDynamicLibrary ?? DynamicLibrary.open,
        _lookup = lookupSymbol ?? _defaultLookup,
        _register = registerExtension ?? _defaultRegister;

  static Pointer<Void> _defaultLookup(DynamicLibrary lib, String symbol) =>
      lib.lookup<Void>(symbol);

  static void _defaultRegister(Sqlite3 sqlite, SqliteExtension ext) =>
      sqlite.ensureExtensionLoaded(ext);

  /// Runs the load pipeline against [config] and registers the
  /// extension with [sqlite] on success.
  ///
  /// Contract:
  ///
  ///   * Never throws. Every error path is captured as a typed
  ///     [VecExtensionLoadResult] with `outcome != loaded`. The wiring
  ///     helper [loadVecExtensionOrRefuseToBoot] is the dedicated
  ///     refuse-to-boot wrapper for the open() path; it translates a
  ///     non-`loaded` result into [VectorRuntimeUnavailable].
  ///   * Side effect on success: `sqlite_auto_extension` carries the
  ///     loaded extension for every future `Database` opened through
  ///     the same `Sqlite3` instance.
  ///   * Side effect on every other outcome: none. The loader does
  ///     not call into sqlite3 unless the file is present and both
  ///     `DynamicLibrary.open` and `lookup` succeed.
  VecExtensionLoadResult load({
    required Sqlite3 sqlite,
    required MemoryConfig config,
  }) {
    final path = config.sqliteVec.extensionPath;

    if (path.isEmpty) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.unavailable,
        extensionPath: path,
        reason: VecUnavailableReason.notConfigured,
        summary: 'sqlite-vec extensionPath is empty in MemoryConfig; '
            'vector runtime unavailable',
      );
    }

    if (!File(path).existsSync()) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.unavailable,
        extensionPath: path,
        reason: VecUnavailableReason.fileMissing,
        summary: 'sqlite-vec binary not found at $path; '
            'vector runtime unavailable',
      );
    }

    final DynamicLibrary library;
    try {
      library = _open(path);
    } on Object catch (e) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.failed,
        extensionPath: path,
        reason: VecUnavailableReason.dynamicLibraryError,
        summary: 'DynamicLibrary.open failed for $path: $e',
        cause: e,
      );
    }

    final Pointer<Void> entrypoint;
    try {
      entrypoint = _lookup(library, entrypointSymbol);
    } on Object catch (e) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.failed,
        extensionPath: path,
        reason: VecUnavailableReason.symbolMissing,
        summary: 'sqlite-vec entrypoint "$entrypointSymbol" '
            'not found in $path: $e',
        cause: e,
      );
    }

    try {
      _register(sqlite, SqliteExtension(entrypoint));
    } on Object catch (e) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.failed,
        extensionPath: path,
        reason: VecUnavailableReason.registrationFailed,
        summary: 'sqlite3.ensureExtensionLoaded threw for $path '
            '(entrypoint "$entrypointSymbol"): $e',
        cause: e,
      );
    }

    return VecExtensionLoadResult(
      outcome: VecLoadOutcome.loaded,
      extensionPath: path,
      summary: 'sqlite-vec loaded from $path '
          '(entrypoint "$entrypointSymbol")',
    );
  }
}

/// Raised by [loadVecExtensionOrRefuseToBoot] when the sqlite-vec
/// (vec0) extension cannot be loaded at boot time.
///
/// Vector search is mandatory inside this quest (Q-A.6.1): a memory
/// subsystem that cannot serve vector recall is not allowed to run.
/// There is no BM25-only fallback. The host's `open()` propagates this
/// exception and the brain refuses to boot until the binary is
/// published (Plan step A.6) or the configuration is corrected.
///
/// Carries the same context the loader's [VecExtensionLoadResult]
/// produced, so the operator UI (and crash logs) can name the
/// configured path, the categorical [reason], the human-readable
/// [summary], whether the cause was a hard error ([wasError]), and the
/// originating exception ([cause]).
final class VectorRuntimeUnavailable implements Exception {
  /// The configured `MemoryConfig.sqliteVec.extensionPath` at the
  /// moment of the load attempt. May be the empty string when [reason]
  /// is [VecUnavailableReason.notConfigured].
  final String extensionPath;

  /// Categorical reason the load did not reach [VecLoadOutcome.loaded].
  final VecUnavailableReason reason;

  /// One-line human-readable summary produced by the loader.
  final String summary;

  /// `true` when the load reached [VecLoadOutcome.failed] (a hard error
  /// during open / lookup / register), `false` when it reached
  /// [VecLoadOutcome.unavailable] (the binary was simply absent or not
  /// configured). The distinction tells the operator whether to fix a
  /// broken binary or publish a missing one.
  final bool wasError;

  /// Originating exception when [wasError] is `true`; `null` for the
  /// `unavailable` branch.
  final Object? cause;

  const VectorRuntimeUnavailable({
    required this.extensionPath,
    required this.reason,
    required this.summary,
    required this.wasError,
    this.cause,
  });

  /// Builds the exception from a non-`loaded` [VecExtensionLoadResult].
  ///
  /// Precondition: `result.isLoaded` is `false` (the result carries a
  /// non-null [VecExtensionLoadResult.reason]).
  factory VectorRuntimeUnavailable.fromResult(VecExtensionLoadResult result) =>
      VectorRuntimeUnavailable(
        extensionPath: result.extensionPath,
        reason: result.reason!,
        summary: result.summary,
        wasError: result.isFailed,
        cause: result.cause,
      );

  @override
  String toString() =>
      'VectorRuntimeUnavailable(reason: ${reason.name}, '
      'extensionPath: $extensionPath): $summary';
}

/// Production wiring helper for the open() path.
///
/// Drives [VecExtensionLoader.load] and, on every non-`loaded`
/// outcome, throws [VectorRuntimeUnavailable] so the host's `open()`
/// aborts. Vector search is mandatory inside this quest (Q-A.6.1):
/// there is no BM25-only fallback. On the `loaded` branch the typed
/// result is returned and `open()` proceeds.
///
/// Designed to be the single call site in the open() pipeline: callers
/// do not need to discriminate on the outcome — a normal return means
/// vector mode is available.
VecExtensionLoadResult loadVecExtensionOrRefuseToBoot({
  required Sqlite3 sqlite,
  required MemoryConfig config,
  VecExtensionLoader? loader,
}) {
  final activeLoader = loader ?? VecExtensionLoader();
  final result = activeLoader.load(sqlite: sqlite, config: config);

  if (!result.isLoaded) {
    throw VectorRuntimeUnavailable.fromResult(result);
  }

  return result;
}
