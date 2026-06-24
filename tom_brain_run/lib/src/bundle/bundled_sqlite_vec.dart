// BundledSqliteVec — extracts the compiled-in `vec0` native library to disk and
// the sqlite-vec resolution order that prefers an explicit config, then on-disk
// binaries, then the bundle, then `${TOM_BINARIES_ROOT}` (`tom_brain_cli.md`
// § 4.2; CLI plan step 4).
//
// Dart FFI cannot `dlopen` bytes — only a file path — so a bundled `vec0` has to
// land on disk before the memory store can load it. [BundledSqliteVec.extract]
// decodes the current platform's bytes out of a [BundleManifest], writes them
// under `<binariesRoot>/<platform>/vec0.<ext>` (the exact layout
// `SqliteVecBinaryResolver` later resolves against), and hash-skips the write
// when an identical file is already there — so the decode-and-extract happens
// once per binary version. When the preferred root is read-only it falls back
// to an OS cache directory.
//
// [resolveSqliteVecBinariesRoot] is the boot-time decision: it picks the
// `memory.sqliteVec.binariesRoot` the store will use, walking explicit config →
// on-disk `<agent>/bin/sqlite_vec/` → bundle (extracted) → `${TOM_BINARIES_ROOT}
// /sqlite_vec`, and raising when none can supply the current platform.

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show SqliteVecBinaryResolver, UnsupportedSqliteVecPlatform;
import 'package:tom_brain_shared/tom_brain_shared.dart' show SqliteVecConfig;

import 'bundle_manifest.dart';

/// Where the resolved `vec0` binaries root came from — for boot logging and the
/// resolution-order test.
enum SqliteVecOrigin {
  /// An explicit `memory.sqliteVec.binariesRoot` in the config.
  explicitConfig,

  /// An on-disk `<agent>/bin/sqlite_vec/` tree already carrying the library.
  diskAgentBin,

  /// The compiled-in bundle, decoded and extracted to disk.
  bundleExtracted,

  /// The in-quest `${TOM_BINARIES_ROOT}/sqlite_vec` tree.
  tomBinariesEnv,
}

/// The chosen `vec0` binaries root and where it came from.
final class SqliteVecResolution {
  /// The directory to set `memory.sqliteVec.binariesRoot` to. The store's
  /// `SqliteVecBinaryResolver` appends `<platform>/vec0.<ext>`.
  final String binariesRoot;

  /// Provenance of [binariesRoot].
  final SqliteVecOrigin origin;

  const SqliteVecResolution({
    required this.binariesRoot,
    required this.origin,
  });
}

/// Raised when no source can supply a `vec0` library for the current platform —
/// the boot error at the end of the resolution order.
final class SqliteVecUnavailable implements Exception {
  /// Operator-facing explanation listing what was tried.
  final String message;

  const SqliteVecUnavailable(this.message);

  @override
  String toString() => 'SqliteVecUnavailable: $message';
}

/// Extracts the compiled-in `vec0` library for one platform to disk.
final class BundledSqliteVec {
  /// The bundle carrying the base64 native libraries.
  final BundleManifest manifest;

  /// The platform to extract. Defaults to the running platform; injectable so
  /// tests drive any target.
  final Abi abi;

  /// Constructs an extractor for [abi] (default `Abi.current()`).
  BundledSqliteVec(this.manifest, {Abi? abi})
      : abi = abi ?? Abi.current();

  /// `true` when this bundle carries a native library for [abi].
  bool get isAvailable {
    final resolver = SqliteVecBinaryResolver(abi: abi);
    if (!resolver.isSupported) return false;
    return manifest.sqliteVec.containsKey(resolver.platformTuple);
  }

  /// Decodes the current platform's bytes and writes them under [binariesRoot]
  /// as `<binariesRoot>/<platform>/vec0.<ext>`, returning the **binaries root**
  /// the store should use (the parent that `SqliteVecBinaryResolver` resolves
  /// against).
  ///
  /// Behaviour:
  ///
  ///   * Skips the write when the target file already holds identical bytes —
  ///     the decode-and-extract is once per binary version.
  ///   * When [binariesRoot] cannot be written (read-only deployment) and
  ///     [fallbackRoot] is given, retries under [fallbackRoot] and returns that
  ///     instead.
  ///
  /// Throws [SqliteVecUnavailable] when the bundle has no library for [abi], and
  /// rethrows the write failure when no [fallbackRoot] can absorb it.
  Future<String> extract({
    required String binariesRoot,
    String? fallbackRoot,
  }) async {
    final resolver = SqliteVecBinaryResolver(abi: abi);
    final String tuple;
    try {
      tuple = resolver.platformTuple;
    } on UnsupportedSqliteVecPlatform catch (e) {
      throw SqliteVecUnavailable('cannot extract bundled vec0: $e');
    }
    final bytes = manifest.nativeBytes(tuple);
    if (bytes == null) {
      throw SqliteVecUnavailable(
        'bundle carries no vec0 library for $tuple; '
        'baked: ${manifest.nativePlatforms.join(', ')}',
      );
    }
    final fileName = resolver.libraryFileName;
    try {
      _writeIfChanged('$binariesRoot/$tuple/$fileName', bytes);
      return binariesRoot;
    } on FileSystemException {
      if (fallbackRoot == null) rethrow;
      _writeIfChanged('$fallbackRoot/$tuple/$fileName', bytes);
      return fallbackRoot;
    }
  }

  static void _writeIfChanged(String path, Uint8List bytes) {
    final file = File(path);
    if (file.existsSync() && _bytesEqual(file.readAsBytesSync(), bytes)) {
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Decides the `vec0` binaries root for boot, in this order (`§ 4.2`):
///
///   1. **Explicit config** — a non-empty `config.binariesRoot`.
///   2. **On-disk agent bin** — `<agentBinRoot>/sqlite_vec/` already carrying
///      the current platform's library.
///   3. **Bundle** — decode + extract from [bundle] into
///      `<agentBinRoot>/sqlite_vec/` (falling back to [cacheRoot] when
///      read-only).
///   4. **`${TOM_BINARIES_ROOT}/sqlite_vec`** — the in-quest tree, when the env
///      var is set and the library is present.
///
/// An explicit `config.extensionPath` is the loader's own override (a direct
/// file path) and short-circuits *upstream* of this function, so it is not
/// considered here.
///
/// Throws [SqliteVecUnavailable] when every source is exhausted.
Future<SqliteVecResolution> resolveSqliteVecBinariesRoot({
  required SqliteVecConfig config,
  required String agentBinRoot,
  required BundleManifest bundle,
  String? cacheRoot,
  Abi? abi,
  String? Function(String name)? env,
}) async {
  final target = abi ?? Abi.current();
  final resolver = SqliteVecBinaryResolver(abi: target);
  final getEnv = env ?? (String n) => Platform.environment[n];

  // 1. explicit config.
  if (config.binariesRoot.isNotEmpty) {
    return SqliteVecResolution(
      binariesRoot: config.binariesRoot,
      origin: SqliteVecOrigin.explicitConfig,
    );
  }

  // 2. on-disk agent bin.
  final agentRoot = '${_trimTrailing(agentBinRoot)}/sqlite_vec';
  if (resolver.isSupported && File(resolver.resolve(agentRoot)).existsSync()) {
    return SqliteVecResolution(
      binariesRoot: agentRoot,
      origin: SqliteVecOrigin.diskAgentBin,
    );
  }

  // 3. bundle.
  final bundled = BundledSqliteVec(bundle, abi: target);
  if (bundled.isAvailable) {
    final used = await bundled.extract(
      binariesRoot: agentRoot,
      fallbackRoot: cacheRoot,
    );
    return SqliteVecResolution(
      binariesRoot: used,
      origin: SqliteVecOrigin.bundleExtracted,
    );
  }

  // 4. ${TOM_BINARIES_ROOT}/sqlite_vec.
  final tomBinaries = getEnv('TOM_BINARIES_ROOT');
  if (tomBinaries != null && tomBinaries.isNotEmpty) {
    final envRoot = '${_trimTrailing(tomBinaries)}/sqlite_vec';
    if (resolver.isSupported && File(resolver.resolve(envRoot)).existsSync()) {
      return SqliteVecResolution(
        binariesRoot: envRoot,
        origin: SqliteVecOrigin.tomBinariesEnv,
      );
    }
  }

  throw SqliteVecUnavailable(
    'no vec0 library for ${resolver.isSupported ? resolver.platformTuple : target} '
    'from config, $agentRoot, the bundle, or \${TOM_BINARIES_ROOT}',
  );
}

String _trimTrailing(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}
