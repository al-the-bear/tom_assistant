// Real-binary roundtrip against the packaged `vec0` (todo #2, P1.1).
//
// A.53 originally noted: "no vec0 shared library ships in tom_binaries/
// yet … a real-binary roundtrip is the obvious next step once the binary
// is published." Todo #2 published it: the per-platform `vec0` binaries
// now live in `tom_binaries/sqlite_vec/<platform>/`. This test closes
// the open question Q-A.53.1 for the running platform by loading the
// *real* binary through the production resolver + loader and proving a
// vec0 virtual-table insert / match roundtrip works end-to-end.
//
// Unlike `a53_vec_extension_roundtrip_test.dart` (which uses injected
// hooks + PlainBlobTableBackend so it runs everywhere), this test
// exercises the genuine FFI path. It resolves the binary from the
// in-quest tree exactly as `open()` will in production: no explicit
// extensionPath, only `binariesRoot` pointing at
// `tom_binaries/sqlite_vec`, platform resolved by
// `SqliteVecBinaryResolver`.
//
// It is skipped (not failed) when the running platform has no packaged
// binary (e.g. linux-armhf, which upstream does not publish), so the
// suite stays green on hosts the tree does not cover while still proving
// the real load on every host it does.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec`.
///
/// Tests run with the package root (`tom_brain_memory`) as the working
/// directory; the workspace root is two levels up
/// (`tom_assistant/tom_brain_memory` → workspace). Falls back to walking
/// parents so the test is robust to the runner's CWD.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  // Compute the resolved path for the running platform, if supported.
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  group('Real packaged vec0 binary roundtrip', () {
    test(
      'resolves + loads the packaged vec0 and runs a vec0 query roundtrip',
      () {
        final root = Directory.systemTemp.createTempSync('tbm_real_vec0_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final config = MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        );

        // Production wiring: resolve via binariesRoot, dlopen the real
        // binary, register with sqlite3_auto_extension. No injection.
        final result = loadVecExtensionOrRefuseToBoot(
          sqlite: sqlite3,
          config: config,
        );
        expect(result.isLoaded, isTrue);
        expect(result.extensionPath, equals(resolvedPath));

        // Every Database opened after registration gets vec0.
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        final version =
            db.select('SELECT vec_version() AS v').first['v'] as String;
        expect(version, isNotEmpty);

        db.execute(
          'CREATE VIRTUAL TABLE vt USING vec0(embedding float[4])',
        );
        db.execute(
          "INSERT INTO vt(rowid, embedding) VALUES (1, '[1,2,3,4]')",
        );
        final match = db.select(
          "SELECT rowid, distance FROM vt "
          "WHERE embedding MATCH '[1,2,3,4]' ORDER BY distance LIMIT 1",
        );
        expect(match, hasLength(1));
        expect(match.first['rowid'], equals(1));
        expect(match.first['distance'] as double, closeTo(0.0, 1e-6));
      },
      skip: resolvedPath == null
          ? 'No packaged vec0 binary for this platform under '
              'tom_binaries/sqlite_vec (resolver.isSupported='
              '${resolver.isSupported}, vecRoot=$vecRoot).'
          : null,
    );
  });
}
