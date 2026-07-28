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
// It is skipped (not failed) when this process has no vector runtime —
// either because the platform has no packaged binary (e.g. linux-armhf,
// which upstream does not publish) or because the host `libsqlite3`
// cannot load extensions at all. The gate is `VectorRuntimeProbe`, which
// runs the real load rather than checking the binary's presence: a
// presence check passes on macOS, where the file is there and the load
// still fails, so it would put a green gate in front of a red test.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  final runtime = VectorRuntimeProbe.probe();
  final resolvedPath = runtime.binariesRoot == null
      ? null
      : SqliteVecBinaryResolver().resolve(runtime.requireBinariesRoot);

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
          binariesRoot: runtime.requireBinariesRoot,
        );

        // Production wiring: resolve via binariesRoot, dlopen the real
        // binary, register with sqlite3_auto_extension. No injection.
        // `extensionCapableSqlite3` — not `sqlite3` — because that is
        // what the store's own default is, and the whole point of this
        // test is to exercise the production path.
        final result = loadVecExtensionOrRefuseToBoot(
          sqlite: extensionCapableSqlite3,
          config: config,
        );
        expect(result.isLoaded, isTrue);
        expect(result.extensionPath, equals(resolvedPath));

        // Every Database opened after registration gets vec0.
        final db = extensionCapableSqlite3.openInMemory();
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
      skip: runtime.skipReason,
    );
  });
}
