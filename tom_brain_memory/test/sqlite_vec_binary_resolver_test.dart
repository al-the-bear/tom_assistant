// SqliteVecBinaryResolver contract test (todo #2, P1.1).
//
// Locks the platform → `tom_binaries/sqlite_vec/` path mapping:
//
//   1. Every supported ABI maps to the expected platform-tuple folder
//      and the expected `vec0.<ext>` filename (the tuples mirror the
//      existing `tom_binaries/tom/<platform>/` layout).
//   2. `resolve(root)` composes `<root>/<tuple>/<file>` with `/`
//      separators and trims trailing separators on the root.
//   3. Unsupported ABIs (Android / iOS / RISC-V / 32-bit x86) throw
//      `UnsupportedSqliteVecPlatform` from `platformTuple`,
//      `libraryFileName`, and `resolve`, and report `isSupported`
//      false.
//   4. The default constructor binds the running platform
//      (`Abi.current()`), so it is supported on every Tom Brain test
//      host.

import 'dart:ffi';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('SqliteVecBinaryResolver — supported platforms', () {
    // (abi, expected tuple, expected filename).
    final cases = <(Abi, String, String)>[
      (Abi.linuxX64, 'linux-x64', 'vec0.so'),
      (Abi.linuxArm64, 'linux-arm64', 'vec0.so'),
      (Abi.linuxArm, 'linux-armhf', 'vec0.so'),
      (Abi.macosArm64, 'darwin-arm64', 'vec0.dylib'),
      (Abi.macosX64, 'darwin-x64', 'vec0.dylib'),
      (Abi.windowsX64, 'win32-x64', 'vec0.dll'),
    ];

    for (final (abi, tuple, file) in cases) {
      test('$abi maps to $tuple/$file', () {
        final resolver = SqliteVecBinaryResolver(abi: abi);
        expect(resolver.isSupported, isTrue);
        expect(resolver.platformTuple, equals(tuple));
        expect(resolver.libraryFileName, equals(file));
        expect(
          resolver.resolve('/opt/tom_binaries/sqlite_vec'),
          equals('/opt/tom_binaries/sqlite_vec/$tuple/$file'),
        );
      });
    }

    test('resolve trims a trailing slash on the root', () {
      final resolver = SqliteVecBinaryResolver(abi: Abi.linuxX64);
      expect(
        resolver.resolve('/opt/tom_binaries/sqlite_vec/'),
        equals('/opt/tom_binaries/sqlite_vec/linux-x64/vec0.so'),
      );
    });

    test('resolve trims a trailing backslash on the root', () {
      final resolver = SqliteVecBinaryResolver(abi: Abi.windowsX64);
      expect(
        resolver.resolve(r'C:\tom_binaries\sqlite_vec\'),
        equals(r'C:\tom_binaries\sqlite_vec/win32-x64/vec0.dll'),
      );
    });

    test('default constructor binds the running platform', () {
      final resolver = SqliteVecBinaryResolver();
      // The test host is always a Tom Brain deployment target.
      expect(resolver.isSupported, isTrue);
      expect(resolver.abi, equals(Abi.current()));
    });
  });

  group('SqliteVecBinaryResolver — unsupported platforms', () {
    final unsupported = <Abi>[
      Abi.androidArm64,
      Abi.iosArm64,
      Abi.linuxIA32,
      Abi.linuxRiscv64,
    ];

    for (final abi in unsupported) {
      test('$abi is reported unsupported and throws on resolution', () {
        final resolver = SqliteVecBinaryResolver(abi: abi);
        expect(resolver.isSupported, isFalse);
        expect(
          () => resolver.platformTuple,
          throwsA(isA<UnsupportedSqliteVecPlatform>()
              .having((e) => e.abi, 'abi', abi)),
        );
        expect(
          () => resolver.libraryFileName,
          throwsA(isA<UnsupportedSqliteVecPlatform>()),
        );
        expect(
          () => resolver.resolve('/opt/tom_binaries/sqlite_vec'),
          throwsA(isA<UnsupportedSqliteVecPlatform>()),
        );
      });
    }

    test('toString names the abi and the message', () {
      const ex = UnsupportedSqliteVecPlatform(
        abi: Abi.androidArm64,
        message: 'no mapping',
      );
      final text = ex.toString();
      expect(text, contains(Abi.androidArm64.toString()));
      expect(text, contains('no mapping'));
    });
  });
}
