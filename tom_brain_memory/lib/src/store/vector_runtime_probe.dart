// VectorRuntimeProbe — answers "can this process serve vector recall?"
// once, without opening a store.
//
// Why this exists:
//
//   Vector recall is mandatory (Q-A.6.1). Whether it is *possible* in a
//   given process depends on two independent facts — a packaged `vec0`
//   binary for the platform, and a host `libsqlite3` that can load
//   extensions at all — and both are established by machinery that
//   already lives in this package (`SqliteVecBinaryResolver`,
//   `VecExtensionLoader`, `SqliteHostLibrary`). What was missing was a
//   single call that runs the *real* pipeline once and hands back a
//   verdict.
//
//   Testing for the binary's presence alone is not a substitute: on
//   macOS the binary is present and the load still fails. A gate built
//   on presence therefore reports "available" and the store then refuses
//   to boot — which is exactly how a stated precondition turns into an
//   unexplained red suite. The probe runs the load.
//
// Why the two tiers:
//
//   [binariesSkipReason] is the weaker question ("is there a binary at
//   all?") and [skipReason] the stronger one ("can it actually
//   register?"). A test that only needs the resolved path — filename
//   composition, platform tuples — is served by the first and should not
//   be skipped merely because the host SQLite is deficient. Anything
//   that opens a store needs the second.
//
// Why it lives in `lib/` rather than test support:
//
//   Both this package's suite and `tom_spec_engine`'s need it, and a
//   host may legitimately want to check the precondition before booting.
//   Duplicating the probe into each consumer is how the two copies drift
//   apart; the package that owns the precondition owns the probe.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'sqlite_host_library.dart';
import 'sqlite_vec_binary_resolver.dart';
import 'vec_extension_loader.dart';

/// One-shot verdict on the vector runtime available to this process.
///
/// Obtained through [VectorRuntimeProbe.probe], which caches per isolate
/// — the probe registers `vec0` with `sqlite3_auto_extension` as a side
/// effect, and registering twice is pointless.
final class VectorRuntimeProbe {
  /// The discovered `tom_binaries/sqlite_vec` directory, or `null` when
  /// no packaged binary was found for this platform.
  final String? binariesRoot;

  /// Why vector-dependent work cannot run here, or `null` when it can.
  ///
  /// Phrased as a complete, operator-facing sentence so it can be used
  /// verbatim as a test `skip:` reason.
  final String? skipReason;

  /// The `libsqlite3` [SqliteHostLibrary] installed, or `null` when the
  /// platform default was used unchanged.
  final String? hostSqliteLibrary;

  const VectorRuntimeProbe._(
    this.binariesRoot,
    this.skipReason,
    this.hostSqliteLibrary,
  );

  /// `true` iff `vec0` is registered and usable in this process.
  bool get isAvailable => skipReason == null;

  /// Why work that needs only the *packaged binary* — its path, its
  /// filename, its platform tuple — cannot run here; `null` when a
  /// binary was found.
  ///
  /// Weaker than [skipReason] by design: a present-but-unloadable binary
  /// still answers path questions.
  String? get binariesSkipReason => binariesRoot == null ? skipReason : null;

  /// [binariesRoot], or a [StateError] naming [binariesSkipReason] as the
  /// gate that should have been checked first.
  String get requireBinariesRoot {
    final root = binariesRoot;
    if (root == null) {
      throw StateError(
        'No packaged vec0 binaries; gate on binariesSkipReason first. '
        '($skipReason)',
      );
    }
    return root;
  }

  static VectorRuntimeProbe? _cached;

  /// Runs the probe once per isolate and returns the cached verdict.
  ///
  /// Order matters: the host-library repair must precede every
  /// `package:sqlite3` access, because the `Sqlite3` instance is cached
  /// on first touch.
  static VectorRuntimeProbe probe() => _cached ??= _run();

  static VectorRuntimeProbe _run() {
    final host = ensureExtensionCapableSqlite();
    final hostLibrary = host.libraryPath;

    final root = _publishedBinariesRoot();
    if (root == null) {
      return VectorRuntimeProbe._(
        null,
        'No packaged vec0 binary found under tom_binaries/sqlite_vec for '
        '${Abi.current()} — the memory store refuses to boot without it.',
        hostLibrary,
      );
    }

    final result = VecExtensionLoader().load(
      sqlite: extensionCapableSqlite3,
      config: MemoryConfig(
        root: Directory.systemTemp.path,
        sqliteVec: SqliteVecConfig(binariesRoot: root),
      ),
    );
    if (result.isLoaded) return VectorRuntimeProbe._(root, null, hostLibrary);

    return VectorRuntimeProbe._(
      root,
      'No vector runtime in this process: the packaged vec0 binary is '
      'present but did not register (${result.reason?.name}). '
      '${result.summary} — ${host.summary}',
      hostLibrary,
    );
  }

  @override
  String toString() => isAvailable
      ? 'VectorRuntimeProbe(available, binariesRoot: $binariesRoot, '
          'hostSqliteLibrary: ${hostSqliteLibrary ?? '<platform default>'})'
      : 'VectorRuntimeProbe(unavailable): $skipReason';
}

/// The discovered `tom_binaries/sqlite_vec` root, but only when it
/// actually holds a `vec0` for the running platform.
///
/// The extra existence check is what makes [VectorRuntimeProbe]'s two
/// tiers mean something: a root with no binary for this ABI answers no
/// path question, so it is reported as "no binaries" rather than as a
/// load failure.
String? _publishedBinariesRoot() {
  final resolver = SqliteVecBinaryResolver();
  if (!resolver.isSupported) return null;
  final root = discoverSqliteVecBinariesRoot();
  if (root == null) return null;
  return File(resolver.resolve(root)).existsSync() ? root : null;
}

/// Walks up from [from] looking for a `tom_binaries/sqlite_vec`
/// directory.
///
/// The in-quest binaries live at the workspace root and consumers run
/// from arbitrary depths beneath it, so the directory is discovered
/// rather than configured. Returns `null` when nothing is found within
/// [maxDepth] levels. Does not check that a binary for the running
/// platform is published there — that is the loader's verdict, and
/// [VectorRuntimeProbe] reports it.
///
/// Production hosts should set `MemoryConfig.sqliteVec.binariesRoot`
/// explicitly; this is the convenience that keeps in-workspace consumers
/// — tests, CLI tools — from each hard-coding the relative path.
String? discoverSqliteVecBinariesRoot({Directory? from, int maxDepth = 10}) {
  final sep = Platform.pathSeparator;
  var dir = (from ?? Directory.current).absolute;
  for (var i = 0; i < maxDepth; i++) {
    final candidate = Directory('${dir.path}${sep}tom_binaries${sep}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
