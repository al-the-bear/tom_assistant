// SqliteHostLibrary — makes the process's `libsqlite3` extension-capable
// before the first SQLite access, so `vec0` can register.
//
// Why this exists:
//
//   Vector recall is mandatory (Q-A.6.1): `SqliteTomBrainMemory` refuses
//   to open unless sqlite-vec's `vec0` registers. Registration needs two
//   things — a packaged `vec0` binary (owned by `SqliteVecBinaryResolver`
//   + `VecExtensionLoader`) *and* a host `libsqlite3` that supports
//   extension loading at all.
//
//   The second half is not universally true. Apple's system SQLite is
//   built with `SQLITE_OMIT_LOAD_EXTENSION`: it exports neither
//   `sqlite3_load_extension` nor `sqlite3_enable_load_extension`, and
//   `sqlite3_auto_extension` answers `SQLITE_MISUSE`. Under the plain
//   Dart VM on macOS that is what `package:sqlite3` resolves to, so the
//   loader reaches `registrationFailed` and the store cannot boot — for
//   this package's own `bin/memory_mcp_server.dart` as much as for its
//   tests. Linux distributions ship a capable `libsqlite3.so`, and a
//   Flutter host bundles its own through `sqlite3_flutter_libs`; both are
//   already fine.
//
// Why the repair lives in `lib/` and not in test support:
//
//   This package *owns* the store and ships a plain-Dart-VM executable
//   that hits the same wall in production. A fix confined to test support
//   would leave `memory_mcp_server` unrunnable on macOS while making the
//   suite green — precisely the wrong way round.
//
// Why it is safe for hosts that are already correct:
//
//   [SqliteHostLibrary.resolve] probes the platform default *first* and
//   returns [SqliteHostLibraryOutcome.defaultCapable] without touching
//   anything when the default already loads extensions. It only reaches
//   for a replacement where there is no correct behaviour to trade away.
//   A Flutter host keeps its bundled SQLite; a Linux host keeps the
//   distribution's.
//
//   The one case it cannot detect is a host that installed its own
//   `open.overrideFor` earlier — `package:sqlite3` exposes no way to ask,
//   so the platform-default probe answers "incapable" and this repair
//   installs over it. That is only ever visible in a diagnostic message
//   attached to a load that already failed, i.e. on a host whose own
//   override did not work either. Such a host should install its override
//   before the first store opens, which is the same ordering constraint it
//   already lives under.
//
// Two properties that look like details and are not:
//
//   *Answer for the isolate, not for the process.* `dart test` runs test
//   files as isolates inside one process and `DynamicLibrary.open` is
//   process-wide, so the moment one isolate loads Homebrew's `libsqlite3`
//   that image is visible to `DynamicLibrary.process()` everywhere. A
//   capability probe that consulted the process namespace would therefore
//   report "capable" in isolates still bound to Apple's SQLite, skip the
//   repair, and — because the resolution claimed to be capable — suppress
//   its own remedy note too. [SqliteHostLibrary.platformDefaultIsCapable]
//   mirrors `package:sqlite3`'s default-open logic instead.
//
//   *Order is load-bearing, so verify it rather than assume it.*
//   `package:sqlite3` caches its `Sqlite3` instance on first access and
//   `open.overrideFor` says nothing when it arrives late; the repair would
//   simply never run. [ensureExtensionCapableSqlite] forces the resolution
//   and checks that its open function was actually called, reporting
//   [SqliteHostLibraryOutcome.overrideTooLate] when it was not.

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// What [SqliteHostLibrary.resolve] did.
///
/// The set is closed; every branch is a distinct operator situation.
enum SqliteHostLibraryOutcome {
  /// The platform default already supports extension loading. Nothing
  /// was overridden. Expected on Linux and inside a Flutter host.
  defaultCapable,

  /// The default was incapable and a capable library was found and
  /// installed through `open.overrideFor`. Expected under the plain Dart
  /// VM on macOS with Homebrew's `sqlite` present.
  overridden,

  /// The default was incapable and no capable candidate was found. The
  /// store will refuse to boot; the operator must install a capable
  /// SQLite or point [sqliteLibraryEnvVar] at one.
  noCapableLibrary,

  /// A capable library was found and registered, but the isolate's
  /// `Sqlite3` instance had **already been resolved** — something touched
  /// the bare `sqlite3` getter first — so the override never ran and the
  /// process is still on the incapable default.
  ///
  /// `package:sqlite3` caches its `Sqlite3` instance on first access and
  /// `open.overrideFor` is silent about arriving late, which would make
  /// this failure indistinguishable from a working repair. Naming it is
  /// the whole point: the remedy is to reach for [extensionCapableSqlite3]
  /// rather than the bare `sqlite3` getter.
  overrideTooLate,

  /// `package:sqlite3` reports no [OperatingSystem] for this platform, so
  /// there is no override seam to use. Nothing was attempted.
  notApplicable,
}

/// Environment variable naming an explicit `libsqlite3` to use.
///
/// Highest-priority candidate, so an operator can override the built-in
/// guesses on any platform without a code change.
const String sqliteLibraryEnvVar = 'TOM_SQLITE3_LIB';

/// Outcome of one [SqliteHostLibrary.resolve] call.
///
/// Immutable. [isExtensionCapable] is the single gate callers need; the
/// remaining fields exist so a boot log or a test skip message can state
/// *why*.
final class SqliteHostLibraryResolution {
  /// Categorical outcome.
  final SqliteHostLibraryOutcome outcome;

  /// The library now installed through `open.overrideFor`. Non-null only
  /// when [outcome] is [SqliteHostLibraryOutcome.overridden].
  final String? libraryPath;

  /// Every candidate inspected, in priority order. Empty when the
  /// default was already capable (no candidate was needed).
  final List<String> candidatesTried;

  SqliteHostLibraryResolution({
    required this.outcome,
    required List<String> candidatesTried,
    this.libraryPath,
  }) : candidatesTried = List.unmodifiable(candidatesTried);

  /// `true` iff SQLite in this process can load extensions — either
  /// because the default already could, or because a capable library was
  /// installed.
  bool get isExtensionCapable =>
      outcome == SqliteHostLibraryOutcome.defaultCapable ||
      outcome == SqliteHostLibraryOutcome.overridden;

  /// One-line, operator-facing explanation.
  String get summary => switch (outcome) {
        SqliteHostLibraryOutcome.defaultCapable =>
          'the platform default libsqlite3 supports extension loading; '
              'nothing overridden',
        SqliteHostLibraryOutcome.overridden =>
          'the platform default libsqlite3 cannot load extensions; '
              'overrode it with $libraryPath',
        SqliteHostLibraryOutcome.noCapableLibrary =>
          'the platform default libsqlite3 cannot load extensions '
              '(built with SQLITE_OMIT_LOAD_EXTENSION) and no capable '
              'replacement was found. Tried: '
              '${candidatesTried.isEmpty ? '<none>' : candidatesTried.join(', ')}. '
              'Install one (macOS: `brew install sqlite`) or set '
              '$sqliteLibraryEnvVar to its path.',
        SqliteHostLibraryOutcome.overrideTooLate =>
          'a capable libsqlite3 ($libraryPath) was registered but the '
              'Sqlite3 instance for this isolate had already been resolved, '
              'so the override never ran. Something reached the bare '
              '`sqlite3` getter before the store was constructed; use '
              '`extensionCapableSqlite3` instead.',
        SqliteHostLibraryOutcome.notApplicable =>
          'package:sqlite3 exposes no OperatingSystem for this platform; '
              'no override seam available',
      };

  @override
  String toString() =>
      'SqliteHostLibraryResolution(${outcome.name}): $summary';
}

/// Finds and installs an extension-capable `libsqlite3` for this process.
///
/// One instance per resolution. Every external dependency is injectable
/// so the branches can be driven without a real dynamic library — the
/// same shape [VecExtensionLoader] uses.
final class SqliteHostLibrary {
  /// Symbol that is absent from a build compiled with
  /// `SQLITE_OMIT_LOAD_EXTENSION`, and present otherwise.
  ///
  /// Probing for the symbol rather than opening a database keeps the
  /// check free of side effects: it must run *before* the first
  /// `package:sqlite3` access.
  static const String extensionLoadingSymbol = 'sqlite3_enable_load_extension';

  final bool Function() _defaultIsCapable;
  final Iterable<String> Function() _candidates;
  final bool Function(String path) _isCapable;
  final void Function(String path) _install;

  SqliteHostLibrary({
    bool Function()? defaultIsCapable,
    Iterable<String> Function()? candidates,
    bool Function(String path)? isCapable,
    void Function(String path)? install,
  })  : _defaultIsCapable = defaultIsCapable ?? platformDefaultIsCapable,
        _candidates = candidates ?? defaultCandidates,
        _isCapable = isCapable ?? _libraryAtPathIsCapable,
        _install = install ?? _installOverride;

  /// Probes the default and, if it cannot load extensions, installs the
  /// first capable candidate.
  ///
  /// Never throws: every failure path is a typed
  /// [SqliteHostLibraryResolution], mirroring [VecExtensionLoader.load].
  SqliteHostLibraryResolution resolve() {
    if (_defaultIsCapable()) {
      return SqliteHostLibraryResolution(
        outcome: SqliteHostLibraryOutcome.defaultCapable,
        candidatesTried: const [],
      );
    }

    final tried = <String>[];
    for (final candidate in _candidates()) {
      tried.add(candidate);
      if (!_isCapable(candidate)) continue;
      _install(candidate);
      return SqliteHostLibraryResolution(
        outcome: SqliteHostLibraryOutcome.overridden,
        libraryPath: candidate,
        candidatesTried: tried,
      );
    }

    return SqliteHostLibraryResolution(
      outcome: SqliteHostLibraryOutcome.noCapableLibrary,
      candidatesTried: tried,
    );
  }

  /// Candidate `libsqlite3` paths, most specific first.
  ///
  /// [sqliteLibraryEnvVar] always wins. After that only macOS has
  /// built-in guesses, because it is the only supported platform whose
  /// default is incapable: Homebrew's `sqlite` formula enables extension
  /// loading, Apple's system build does not. Apple Silicon prefix first,
  /// then Intel.
  static Iterable<String> defaultCandidates() sync* {
    final configured = Platform.environment[sqliteLibraryEnvVar];
    if (configured != null && configured.isNotEmpty) yield configured;
    if (!Platform.isMacOS) return;
    yield '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib';
    yield '/usr/local/opt/sqlite/lib/libsqlite3.dylib';
  }

  /// The library filename `package:sqlite3` opens by default, per
  /// platform. `null` where there is nothing to probe.
  static String? get platformDefaultLibraryName {
    if (Platform.isMacOS || Platform.isIOS) return 'libsqlite3.dylib';
    if (Platform.isLinux || Platform.isAndroid) return 'libsqlite3.so';
    if (Platform.isWindows) return 'sqlite3.dll';
    return null;
  }

  /// Whether the library `package:sqlite3` would open in *this isolate*,
  /// absent an override, supports extension loading.
  ///
  /// This deliberately mirrors `package:sqlite3`'s own default-open
  /// logic: probe [platformDefaultLibraryName] where there is one, and
  /// only fall back to the process namespace where `package:sqlite3`
  /// itself does — on platforms with no default filename, e.g. a Flutter
  /// host that links its bundled SQLite straight into the executable.
  ///
  /// Why: `dart test` runs test files as isolates *inside one process*,
  /// and `DynamicLibrary.open` is process-wide. Once one isolate repairs
  /// itself by loading Homebrew's `libsqlite3`, that image is visible to
  /// `DynamicLibrary.process()` from every other isolate — so a
  /// process-namespace probe reports "capable" in isolates that are still
  /// on Apple's system SQLite, the repair is skipped, and the store fails
  /// to boot with no diagnosis (the resolution claims to be capable, so
  /// even the remedy note is suppressed). The probe must answer for the
  /// isolate's own `sqlite3` handle, not for the process.
  static bool platformDefaultIsCapable() {
    final name = platformDefaultLibraryName;
    if (name == null) return _providesSymbol(() => DynamicLibrary.process());
    return _providesSymbol(() => DynamicLibrary.open(name));
  }

  /// Whether the shared library at [path] exports the extension-loading
  /// entry point. `false` — never a throw — for a missing path, a
  /// directory, or a file that is not a loadable image.
  static bool libraryAtPathIsCapable(String path) =>
      _libraryAtPathIsCapable(path);

  static bool _libraryAtPathIsCapable(String path) {
    if (!File(path).existsSync()) return false;
    return _providesSymbol(() => DynamicLibrary.open(path));
  }

  static bool _providesSymbol(DynamicLibrary Function() open) {
    try {
      return open().providesSymbol(extensionLoadingSymbol);
      // `providesSymbol` and `open` signal "not there" with ArgumentError,
      // which is an Error rather than an Exception.
      // ignore: avoid_catching_errors
    } on Error {
      return false;
    } on Exception {
      return false;
    }
  }

  static void _installOverride(String path) {
    final os = open.os;
    if (os == null) return;
    _overridePath = path;
    open.overrideFor(os, _openOverride);
  }
}

/// Path [_openOverride] opens.
///
/// A top-level pair rather than a closure because `package:sqlite3`
/// requires the open function to be top-level or static for its isolate
/// API.
String? _overridePath;

/// Set by [_openOverride] when `package:sqlite3` actually calls it — the
/// evidence that the override was installed in time. See
/// [SqliteHostLibraryOutcome.overrideTooLate].
bool _openOverrideRan = false;

DynamicLibrary _openOverride() {
  _openOverrideRan = true;
  return DynamicLibrary.open(_overridePath!);
}

SqliteHostLibraryResolution? _resolution;

/// Ensures this process has an extension-capable SQLite, once.
///
/// Idempotent per isolate: the first call resolves, later calls return
/// the same [SqliteHostLibraryResolution]. Must run before the first
/// `package:sqlite3` access — the `Sqlite3` instance is cached on first
/// touch, so a later override would silently be a no-op. Going through
/// [extensionCapableSqlite3] guarantees that ordering.
///
/// Never throws. When the outcome is
/// [SqliteHostLibraryOutcome.noCapableLibrary] the caller proceeds and
/// the store's existing boot checks refuse the open with their own
/// message; this function's job is the repair, not the verdict.
SqliteHostLibraryResolution ensureExtensionCapableSqlite() =>
    _resolution ??= _resolveAndVerify();

SqliteHostLibraryResolution _resolveAndVerify() {
  if (open.os == null) {
    return SqliteHostLibraryResolution(
      outcome: SqliteHostLibraryOutcome.notApplicable,
      candidatesTried: const [],
    );
  }

  final resolution = SqliteHostLibrary().resolve();
  if (resolution.outcome != SqliteHostLibraryOutcome.overridden) {
    return resolution;
  }

  // Force `package:sqlite3` to resolve its instance now. If it had
  // already resolved one, our open function is never consulted and the
  // repair is a silent no-op — the one failure mode `open.overrideFor`
  // will not report. Detect it here so it is named rather than inferred
  // from a store that refuses to boot for no visible reason.
  _touchSqlite();
  if (_openOverrideRan) return resolution;

  return SqliteHostLibraryResolution(
    outcome: SqliteHostLibraryOutcome.overrideTooLate,
    libraryPath: resolution.libraryPath,
    candidatesTried: resolution.candidatesTried,
  );
}

void _touchSqlite() {
  try {
    sqlite3.version;
  } on Object {
    // A host with no loadable SQLite at all is not this function's
    // problem: the store's boot checks report it with their own message.
  }
}

/// The resolution [ensureExtensionCapableSqlite] reached, or `null` if it
/// has not run in this isolate.
///
/// Read-only and side-effect free, so a diagnostic (a boot log, a test
/// skip reason, an exception message) can report the host-library state
/// without forcing the probe.
SqliteHostLibraryResolution? get sqliteHostLibraryResolution => _resolution;

/// The process-global `sqlite3`, with the host-library repair applied.
///
/// This is the accessor the package uses wherever it would otherwise
/// reach for `sqlite3` directly, so the repair always lands before the
/// first access. Hosts that inject their own `Sqlite3` bypass it, which
/// is correct — they have taken ownership of the library.
Sqlite3 get extensionCapableSqlite3 {
  ensureExtensionCapableSqlite();
  return sqlite3;
}
