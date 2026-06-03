// SqliteVecBinaryResolver — maps the running platform onto the
// per-platform `vec0` binary inside the in-quest `tom_binaries/sqlite_vec/`
// tree (todo #2, P1.1).
//
// Why this exists:
//
//   Vector search is mandatory inside this quest (Q-A.6.1): the memory
//   subsystem refuses to boot without `vec0`. To make that boot *always
//   succeed* on a supported deployment target, the binaries are shipped
//   in-quest under `tom_binaries/sqlite_vec/<platform>/vec0.<ext>`
//   (memory_specification.md § 2.2 Option A). The operator should not
//   have to hand-write the platform tuple or the platform-specific
//   filename — `${TOM_BINARIES}/sqlite_vec/${PLATFORM}/vec0.so` from the
//   spec's § 14 example is Linux-only and breaks on macOS / Windows.
//
//   This resolver is the single place that knows two facts:
//
//     1. The platform-tuple folder name (`linux-x64`, `darwin-arm64`,
//        `win32-x64`, …) — mirroring the existing `tom_binaries/tom/`
//        layout so the `sqlite_vec/` tree is laid out identically.
//     2. The shared-library filename for the platform (`vec0.so` /
//        `vec0.dylib` / `vec0.dll`).
//
//   Given the `sqlite_vec/` root directory, it composes the concrete
//   absolute path the loader then opens. The loader (`vec_extension_loader.dart`)
//   stays focused on the FFI open / lookup / register pipeline; the
//   resolver owns platform → path. Single responsibility on both sides.
//
// Why `Abi` (and not `Platform.operatingSystem` + a hand-rolled arch
// probe):
//
//   `Abi.current()` already encodes OS *and* CPU architecture as one
//   value (`Abi.linuxX64`, `Abi.macosArm64`, …). It is the canonical
//   Dart way to discriminate a native target, it is exhaustive, and it
//   makes the resolver deterministic under test: a test injects any
//   `Abi` and asserts the tuple / filename / path without depending on
//   the host the test runs on.

import 'dart:ffi' show Abi;

/// Raised when the running (or injected) [Abi] is not a Tom Brain
/// deployment target — i.e. there is no `tom_binaries/sqlite_vec/`
/// folder mapping for it.
///
/// Tom Brain deploys on Linux / macOS / Windows on x64 / arm64 (plus
/// 32-bit ARM Linux). Android, iOS, RISC-V, and 32-bit x86 are not
/// targets; resolving on one of them is a configuration / porting
/// problem the operator must resolve, not a missing-binary case.
final class UnsupportedSqliteVecPlatform implements Exception {
  /// The ABI that has no platform-tuple mapping.
  final Abi abi;

  /// One-line, operator-facing explanation naming [abi].
  final String message;

  const UnsupportedSqliteVecPlatform({
    required this.abi,
    required this.message,
  });

  @override
  String toString() => 'UnsupportedSqliteVecPlatform($abi): $message';
}

/// Resolves the `vec0` binary path for one platform out of the in-quest
/// `tom_binaries/sqlite_vec/` tree.
///
/// Stateless apart from the bound [abi]. One instance per process in
/// production (constructed with the default `Abi.current()`); tests
/// construct one per platform under test.
final class SqliteVecBinaryResolver {
  /// The platform this resolver maps. Defaults to the running platform
  /// (`Abi.current()`); injectable so tests can drive every branch.
  final Abi abi;

  /// Constructs a resolver for [abi], defaulting to the running
  /// platform. `Abi.current()` is not `const`, so this constructor is
  /// not `const` either.
  SqliteVecBinaryResolver({Abi? abi}) : abi = abi ?? Abi.current();

  /// Folder-name mapping from ABI to the `tom_binaries/` platform tuple.
  ///
  /// The tuples mirror the existing `tom_binaries/tom/<platform>/` set
  /// (`darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-armhf`,
  /// `linux-x64`, `win32-x64`) so the `sqlite_vec/` tree is laid out
  /// identically. The set is closed: a new deployment target must be
  /// added here *and* have its binary published into the tree.
  static const Map<Abi, String> _platformTuples = <Abi, String>{
    Abi.linuxX64: 'linux-x64',
    Abi.linuxArm64: 'linux-arm64',
    Abi.linuxArm: 'linux-armhf',
    Abi.macosArm64: 'darwin-arm64',
    Abi.macosX64: 'darwin-x64',
    Abi.windowsX64: 'win32-x64',
  };

  /// Shared-library filename extensions per OS family. Keyed on the
  /// supported tuples above; Linux uses `.so`, macOS `.dylib`, Windows
  /// `.dll`.
  static const Map<Abi, String> _libraryExtensions = <Abi, String>{
    Abi.linuxX64: '.so',
    Abi.linuxArm64: '.so',
    Abi.linuxArm: '.so',
    Abi.macosArm64: '.dylib',
    Abi.macosX64: '.dylib',
    Abi.windowsX64: '.dll',
  };

  /// `true` iff [abi] has a `tom_binaries/sqlite_vec/` mapping.
  ///
  /// Lets a caller branch before calling [platformTuple] / [resolve],
  /// which throw on an unsupported platform.
  bool get isSupported => _platformTuples.containsKey(abi);

  /// The `tom_binaries/` platform-tuple folder name for [abi].
  ///
  /// Throws [UnsupportedSqliteVecPlatform] when [abi] is not a Tom
  /// Brain deployment target.
  String get platformTuple {
    final tuple = _platformTuples[abi];
    if (tuple == null) {
      throw UnsupportedSqliteVecPlatform(
        abi: abi,
        message: 'no tom_binaries/sqlite_vec/ platform tuple for $abi; '
            'supported: ${_platformTuples.values.join(', ')}',
      );
    }
    return tuple;
  }

  /// The platform-specific `vec0` library filename for [abi]
  /// (`vec0.so` / `vec0.dylib` / `vec0.dll`).
  ///
  /// Throws [UnsupportedSqliteVecPlatform] when [abi] is not a Tom
  /// Brain deployment target.
  String get libraryFileName {
    final ext = _libraryExtensions[abi];
    if (ext == null) {
      throw UnsupportedSqliteVecPlatform(
        abi: abi,
        message: 'no vec0 library extension for $abi; '
            'supported: ${_platformTuples.values.join(', ')}',
      );
    }
    return 'vec0$ext';
  }

  /// Composes the concrete `vec0` path from [binariesRoot] — the
  /// `tom_binaries/sqlite_vec/` directory — for the current [abi].
  ///
  /// Returns `<binariesRoot>/<platformTuple>/<libraryFileName>`.
  /// Segments are joined with `/`, which Dart's `File` / FFI APIs
  /// accept on every platform (including Windows); any trailing
  /// separators on [binariesRoot] are trimmed first so the result has
  /// no doubled separators.
  ///
  /// Throws [UnsupportedSqliteVecPlatform] when [abi] is not a Tom
  /// Brain deployment target. Does not check the filesystem — existence
  /// is the loader's concern (it maps a missing file to `fileMissing`).
  String resolve(String binariesRoot) {
    final root = _trimTrailingSeparators(binariesRoot);
    return '$root/$platformTuple/$libraryFileName';
  }

  static String _trimTrailingSeparators(String path) {
    var end = path.length;
    while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    return path.substring(0, end);
  }
}
