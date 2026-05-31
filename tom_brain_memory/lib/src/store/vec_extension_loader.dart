// VecExtensionLoader — boot-time loader for the sqlite-vec (vec0)
// shared-library extension (Plan step A.50).
//
// Plan step A.50:
//   "Add the `vec0` shared-library loader. Boot-time check fails open
//    (BM25-only) and emits `VectorIndexUnavailable` if the extension
//    is absent."
//
// Role in the open path (will be wired at A.28+ when the concrete
// `SqliteTomBrainMemory.open()` lands; today the loader is wired into
// the storage open path via integration tests and the wiring helper
// `loadVecExtensionWithFailOpen`):
//
//   1. Host calls `MemoryDirectory.openOrCreate(config)`.
//   2. Host opens `memory.db` and runs `BootIntegrityCheck`.
//   3. Host calls `loadVecExtensionWithFailOpen(...)`:
//        a. The loader resolves `config.sqliteVec.extensionPath`.
//        b. If the path is empty, missing, or points at a file that
//           fails to load / register, a `VectorIndexUnavailable`
//           event is pushed onto the memory event sink and the result
//           is returned without raising.
//        c. If the load succeeds, the result is returned silently
//           (success-only emission — see `vec_extension_events.dart`).
//   4. Host stores the result. A.51+ uses
//      `result.outcome == VecLoadOutcome.loaded` as the gate for
//      every vector-mode write (`persist` with embedding) and every
//      vector-mode recall path.
//
// Why "fail open" is the engineered default at A.50:
//
//   The prototype timeline (`tom_brain_definition.md`) accepts a
//   degraded-mode boot when the vec0 binary is unavailable so that
//   developer machines without the binary still produce a working
//   memory subsystem on BM25 alone. The alternative (refuse to boot)
//   would block every Phase-A step that doesn't touch vectors,
//   including the substrate gateway (Phase B) and the dispatcher
//   smoke tests (Phase D). The decision is **not** "fail open in
//   production" — production wiring is expected to *assert* that the
//   loader returned `loaded` after open() returns. See Q-A.50.1.
//
// Why the loader is event-free and the wiring helper emits:
//
//   The loader is reused by the BootIntegrityCheck path (A.29 today
//   under a different probe), by integration tests, and (later) by
//   the open() path. Each of those call sites has a different "what
//   to do on degraded outcome" policy: tests assert on the result
//   object directly; production wiring emits an event AND records
//   the outcome on `MemoryStats`; an MCP-only readout path would
//   neither emit nor assert. Coupling the loader to event emission
//   would force every consumer through the event sink even when it
//   has no use for it. Keeping emission in a thin wrapper preserves
//   the loader as a pure value-returning function.
//
// Why dependency injection (opener / lookup / registrar):
//
//   The success path of the loader requires a real vec0 binary on
//   disk. The current developer machines do not ship that binary
//   (see Q-A.50.2). Without injection points, the failure paths
//   would also be untestable because every test would have to
//   provide a real shared library that *fails* on dlopen or symbol
//   lookup in a controlled way. The injected functions make every
//   branch deterministic and platform-neutral; production wiring
//   uses the defaults.

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../api/memory_event.dart';
import '../config/memory_config.dart';
import 'vec_extension_events.dart';

/// Outcome of one `VecExtensionLoader.load(...)` call.
///
/// Three states, not two:
///
///   * `loaded`      — the extension is registered with
///                     `sqlite3_auto_extension` and every subsequent
///                     `Database` opened through the same `Sqlite3`
///                     instance will receive vec0 functions.
///   * `unavailable` — the extension is not present (configuration
///                     empty, file missing). The brain falls back to
///                     BM25-only mode; this is a configuration choice,
///                     not a defect.
///   * `failed`      — the extension is present but could not be
///                     loaded (broken binary, wrong arch, missing
///                     entrypoint, registration error). The brain
///                     still falls back to BM25-only mode, but the
///                     outcome indicates a *fix* is required, not a
///                     configuration choice.
///
/// The distinction between `unavailable` and `failed` matters for the
/// operator UI: a freshly-cloned workspace on a machine without the
/// binary is `unavailable` and should not raise an alarm; a CI
/// environment with a broken binary is `failed` and should.
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
  ///     [VecExtensionLoadResult] with `outcome != loaded`.
  ///   * Does not emit any event. The wiring helper
  ///     [loadVecExtensionWithFailOpen] is the dedicated event-
  ///     emitting wrapper for the open() path.
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
            'BM25-only mode',
      );
    }

    if (!File(path).existsSync()) {
      return VecExtensionLoadResult(
        outcome: VecLoadOutcome.unavailable,
        extensionPath: path,
        reason: VecUnavailableReason.fileMissing,
        summary: 'sqlite-vec binary not found at $path; BM25-only mode',
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

/// Production wiring helper for the open() path.
///
/// Drives [VecExtensionLoader.load] and, on every non-`loaded`
/// outcome, emits a [VectorIndexUnavailable] event onto [emit]
/// before returning the result. The `loaded` branch does not emit
/// (success-only emission — see `vec_extension_events.dart`).
///
/// Designed to be the single call site in the open() pipeline:
/// callers do not need to discriminate on the outcome before deciding
/// to emit. The returned result is still the authoritative gate for
/// downstream vector-mode wiring (A.51+).
///
/// `now` defaults to `DateTime.now().toUtc()` and is overridable for
/// tests that assert on `occurredAt`.
VecExtensionLoadResult loadVecExtensionWithFailOpen({
  required Sqlite3 sqlite,
  required MemoryConfig config,
  required void Function(MemoryEvent event) emit,
  VecExtensionLoader? loader,
  DateTime Function()? now,
}) {
  final activeLoader = loader ?? VecExtensionLoader();
  final clock = now ?? () => DateTime.now().toUtc();
  final result = activeLoader.load(sqlite: sqlite, config: config);

  if (!result.isLoaded) {
    emit(VectorIndexUnavailable(
      extensionPath: result.extensionPath,
      reason: result.reason!,
      summary: result.summary,
      wasError: result.isFailed,
      occurredAt: clock(),
      cause: result.cause,
    ));
  }

  return result;
}
