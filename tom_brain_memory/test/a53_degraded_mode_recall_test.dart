// A.53 — Refuse-to-boot when the sqlite-vec extension is missing
// (integration).
//
// Plan step A.53 originally read:
//   "Tests: extension load + vec query roundtrip; degraded-mode recall
//    when extension missing; embedding-model mismatch rejection."
//
// The "degraded-mode recall" clause is revoked. Vector search is
// mandatory inside this quest (Q-A.6.1, re-ratified 2026-06-03): "the
// system only works if vector search is possible. The memory system
// must be able to run with vector always." There is no BM25-only
// fallback; when the vec0 extension cannot be loaded the brain
// **refuses to boot** by raising `VectorRuntimeUnavailable` from the
// open-path wiring helper `loadVecExtensionOrRefuseToBoot`.
//
// What this file locks:
//   * Each non-loaded boot outcome — notConfigured, fileMissing,
//     dynamicLibraryError — aborts boot with `VectorRuntimeUnavailable`
//     rather than continuing in a degraded mode.
//   * The exception carries the categorical reason and the `wasError`
//     flag so the operator UI can tell a missing binary (publish it)
//     from a broken one (fix it).
//   * The pure `VecExtensionLoader.load(...)` still does *not* throw —
//     it returns a typed result; only the wiring helper raises. This
//     keeps the loader inspectable by the BootIntegrityCheck path and
//     by tests.
//
// Why we exercise three reason codes (notConfigured, fileMissing,
// dynamicLibraryError):
//   The first two are the developer-machine path (no binary on disk;
//   no extensionPath in config); the third is the fault path (binary
//   is present but rejected by dlopen). All three must refuse to boot,
//   and the `wasError` flag distinguishes the configuration omissions
//   (false) from the hard fault (true).

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

/// Tempdir helper — created on call, removed on test teardown.
Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Builds a `MemoryConfig` whose `extensionPath` is the empty string
/// (the notConfigured branch — every developer machine until the vec0
/// binary is published).
MemoryConfig _notConfiguredConfig() {
  final root = _tempDir('tbm_a53_refuse_notcfg_').path;
  return MemoryConfig.forTesting(root: root, extensionPath: '');
}

/// Builds a `MemoryConfig` whose `extensionPath` points at a file
/// that does not exist on disk (the fileMissing branch).
MemoryConfig _fileMissingConfig() {
  final dir = _tempDir('tbm_a53_refuse_missing_');
  final ghost = '${dir.path}${Platform.pathSeparator}vec0_not_here.so';
  return MemoryConfig.forTesting(root: dir.path, extensionPath: ghost);
}

/// Builds a `MemoryConfig` whose `extensionPath` points at a real
/// file that fails to dlopen (the dynamicLibraryError branch — the
/// failure is engineered by overriding `openDynamicLibrary` in the
/// loader passed to the wiring helper).
MemoryConfig _brokenBinaryConfig() {
  final dir = _tempDir('tbm_a53_refuse_broken_');
  final stub = File('${dir.path}${Platform.pathSeparator}not_a_lib.bin');
  stub.writeAsStringSync('text-not-binary');
  return MemoryConfig.forTesting(
    root: dir.path,
    extensionPath: stub.path,
  );
}

void main() {
  group('A.53 refuse-to-boot when extension missing', () {
    test('notConfigured boot → VectorRuntimeUnavailable (wasError=false)',
        () {
      expect(
        () => loadVecExtensionOrRefuseToBoot(
          sqlite: sqlite3,
          config: _notConfiguredConfig(),
        ),
        throwsA(
          isA<VectorRuntimeUnavailable>()
              .having((e) => e.reason, 'reason',
                  VecUnavailableReason.notConfigured)
              .having((e) => e.wasError, 'wasError', isFalse),
        ),
      );
    });

    test('fileMissing boot → VectorRuntimeUnavailable (wasError=false)', () {
      expect(
        () => loadVecExtensionOrRefuseToBoot(
          sqlite: sqlite3,
          config: _fileMissingConfig(),
        ),
        throwsA(
          isA<VectorRuntimeUnavailable>()
              .having((e) => e.reason, 'reason',
                  VecUnavailableReason.fileMissing)
              .having((e) => e.wasError, 'wasError', isFalse),
        ),
      );
    });

    test('dynamicLibraryError boot → VectorRuntimeUnavailable '
        '(wasError=true, cause captured)', () {
      final brokenLoader = VecExtensionLoader(
        openDynamicLibrary: (path) =>
            throw ArgumentError('A.53 synthetic dlopen failure for $path'),
      );

      expect(
        () => loadVecExtensionOrRefuseToBoot(
          sqlite: sqlite3,
          config: _brokenBinaryConfig(),
          loader: brokenLoader,
        ),
        throwsA(
          isA<VectorRuntimeUnavailable>()
              .having((e) => e.reason, 'reason',
                  VecUnavailableReason.dynamicLibraryError)
              .having((e) => e.wasError, 'wasError', isTrue)
              .having((e) => e.cause, 'cause', isA<ArgumentError>()),
        ),
      );
    });

    test('the pure loader does not throw — only the wiring helper does',
        () {
      // The BootIntegrityCheck path and tests inspect the typed result
      // directly; the refuse-to-boot decision lives solely in the
      // wiring helper. Locked so the loader stays exception-free.
      final result = VecExtensionLoader().load(
        sqlite: sqlite3,
        config: _notConfiguredConfig(),
      );

      expect(result.isUnavailable, isTrue);
      expect(result.reason, equals(VecUnavailableReason.notConfigured));
    });
  });
}
