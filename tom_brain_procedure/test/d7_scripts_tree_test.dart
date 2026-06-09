// Scripts-tree contract test (Plan step D.7 — `scripts/system/` +
// `scripts/user/` at the project root).
//
// D.7 establishes the on-disk procedure tree split into the two disk
// origins (`ProcedureOrigin.system` / `ProcedureOrigin.user`). This test
// is the proof that the tree exists *and* that it lines up with the
// engine's default config paths and the `DiskProcedureStore` behaviour:
//
//   1. `scripts/system/` and `scripts/user/` both exist as directories
//      at the project root.
//   2. The `EngineConfig` default path constants point exactly at those
//      two directories (`scripts/system` / `scripts/user`).
//   3. A `DiskProcedureStore` configured against the real default paths
//      enumerates the shipped system stub (`think_v1.dart`) under
//      `ProcedureOrigin.system` and contributes nothing from the empty
//      `scripts/user/` directory — the split works end-to-end.
//   4. Non-`.dart` files (the documentation READMEs) are never surfaced
//      as procedures.
//
// The test runs with the project root as the working directory (Dart's
// standard `dart test` behaviour), so `scripts/system` / `scripts/user`
// resolve directly — the same convention `folder_layout_test.dart` uses.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  group('scripts tree (D.7)', () {
    test('scripts/system/ exists', () {
      expect(Directory('scripts/system').existsSync(), isTrue,
          reason: 'expected scripts/system/ at the project root');
    });

    test('scripts/user/ exists', () {
      expect(Directory('scripts/user').existsSync(), isTrue,
          reason: 'D.7 must add scripts/user/ alongside scripts/system/');
    });

    test('default config paths point at the two script directories', () {
      expect(defaultSystemScriptsPath, equals('scripts/system'));
      expect(defaultUserScriptsPath, equals('scripts/user'));
      expect(Directory(defaultSystemScriptsPath).existsSync(), isTrue);
      expect(Directory(defaultUserScriptsPath).existsSync(), isTrue);
    });

    test('the shipped system stub lives under scripts/system/', () {
      expect(File('scripts/system/think_v1.dart').existsSync(), isTrue,
          reason: 'think_v1.dart is the Phase-C system stub the split keeps');
    });

    test(
        'DiskProcedureStore lists the system stub and nothing from empty '
        'scripts/user/', () async {
      final store = DiskProcedureStore(
        systemDir: Directory(defaultSystemScriptsPath),
        userDir: Directory(defaultUserScriptsPath),
      );

      final refs = await store.list();

      // Every disk ref is one of the two disk origins, never `brain`.
      expect(refs.every((r) => r.origin.isDisk), isTrue);

      final systemRefs =
          refs.where((r) => r.origin == ProcedureOrigin.system).toList();
      final userRefs =
          refs.where((r) => r.origin == ProcedureOrigin.user).toList();

      // The system stub is present.
      expect(systemRefs, isNotEmpty,
          reason: 'scripts/system/ ships at least think_v1.dart');
      expect(
        systemRefs.any((r) => r.locator.endsWith('think_v1.dart')),
        isTrue,
        reason: 'think_v1.dart must be enumerated under the system origin',
      );

      // scripts/user/ is empty (only the README, which is not a .dart file),
      // so it contributes no procedures — the "missing/empty user dir is
      // normal" contract.
      expect(userRefs, isEmpty,
          reason: 'scripts/user/ holds no .dart files in the prototype');
    });

    test('non-.dart documentation files are not surfaced as procedures',
        () async {
      final store = DiskProcedureStore(
        systemDir: Directory(defaultSystemScriptsPath),
        userDir: Directory(defaultUserScriptsPath),
      );

      final refs = await store.list();

      expect(
        refs.any((r) => r.locator.endsWith('.md')),
        isFalse,
        reason: 'DiskProcedureStore lists only *.dart files',
      );
    });
  });
}
