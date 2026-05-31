// A.26 MemoryDirectory behaviour test.
//
// Locks the contract documented at the top of
// `lib/src/store/memory_directory.dart`:
//
//   1. A fresh root is materialised with the three required
//      subdirectories.
//   2. Re-opening an existing root is idempotent and reports
//      `wasCreated == false`.
//   3. Opening a path that points at a *file* throws
//      `FileSystemException`.
//   4. An empty root path throws `ArgumentError`.
//   5. All exposed paths are absolute.
//   6. `isFresh` flips to `false` once `memory.db` exists.
//
// The test uses `Directory.systemTemp.createTempSync` so cleanup is
// guaranteed even on test failure (`addTearDown` deletes the temp
// directory tree).

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

void main() {
  group('A.26 MemoryDirectory.openOrCreate', () {
    test('creates a fresh root with the three required subdirectories', () {
      final parent = _tempDir('tbm_a26_fresh_');
      final root = '${parent.path}${Platform.pathSeparator}brain';

      // Sanity — the root does not exist before the call.
      expect(Directory(root).existsSync(), isFalse);

      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );

      expect(dir.wasCreated, isTrue,
          reason: 'openOrCreate on a non-existent root must report wasCreated');
      expect(Directory(dir.root).existsSync(), isTrue);
      expect(Directory(dir.trailsDir).existsSync(), isTrue);
      expect(Directory(dir.tombstonesDir).existsSync(), isTrue);
      expect(Directory(dir.checkpointsDir).existsSync(), isTrue);
    });

    test('is idempotent on an existing root', () {
      final parent = _tempDir('tbm_a26_existing_');
      final root = '${parent.path}${Platform.pathSeparator}brain';

      final first = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(first.wasCreated, isTrue);

      final second = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(second.wasCreated, isFalse,
          reason: 're-opening an existing root must report wasCreated == false');
      expect(second.root, equals(first.root));
      expect(second.trailsDir, equals(first.trailsDir));
      expect(second.tombstonesDir, equals(first.tombstonesDir));
      expect(second.checkpointsDir, equals(first.checkpointsDir));
    });

    test('regenerates a missing subdirectory on re-open', () {
      // If an operator deletes `trails/` between runs, the opener
      // recreates it rather than failing. The directory contract is
      // "these dirs exist after openOrCreate returns" — not "these
      // dirs were never deleted".
      final parent = _tempDir('tbm_a26_regen_');
      final root = '${parent.path}${Platform.pathSeparator}brain';

      final first = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      Directory(first.trailsDir).deleteSync(recursive: true);
      expect(Directory(first.trailsDir).existsSync(), isFalse);

      final second = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(Directory(second.trailsDir).existsSync(), isTrue);
    });

    test('throws when the root path points at a file', () {
      final parent = _tempDir('tbm_a26_notdir_');
      final file = File('${parent.path}${Platform.pathSeparator}brain');
      file.writeAsStringSync('not a memory directory');

      expect(
        () => MemoryDirectory.openOrCreate(
          MemoryConfig.forTesting(root: file.path),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('throws ArgumentError when the root path is empty', () {
      // Bypass `MemoryConfig.forTesting`'s own non-empty check by
      // constructing the config directly — exercises the
      // defence-in-depth check inside the opener.
      final cfg = MemoryConfig(
        root: '',
        sqliteVec: const SqliteVecConfig(extensionPath: ''),
      );
      expect(
        () => MemoryDirectory.openOrCreate(cfg),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resolves all exposed paths as absolute', () {
      // Use a relative parent then chdir into the temp parent so the
      // configured root is a *relative* string; the opener must
      // promote it to absolute on the way out.
      final parent = _tempDir('tbm_a26_abs_');
      final originalCwd = Directory.current;
      Directory.current = parent;
      addTearDown(() {
        Directory.current = originalCwd;
      });

      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: 'brain'),
      );

      for (final path in <String>[
        dir.root,
        dir.memoryDbPath,
        dir.vectorsDbPath,
        dir.trailsDir,
        dir.tombstonesDir,
        dir.checkpointsDir,
      ]) {
        expect(
          path,
          startsWith(Platform.pathSeparator),
          reason: 'expected absolute path, got: $path',
        );
      }
    });

    test('exposes canonical filenames for the SQLite databases', () {
      final parent = _tempDir('tbm_a26_names_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(dir.memoryDbPath, endsWith('memory.db'));
      expect(dir.vectorsDbPath, endsWith('vectors.db'));
      expect(dir.trailsDir, endsWith('trails'));
      expect(dir.tombstonesDir, endsWith('tombstones'));
      expect(dir.checkpointsDir, endsWith('checkpoints'));
    });
  });

  group('A.26 MemoryDirectory freshness probes', () {
    test('isFresh is true before either DB file exists', () {
      final parent = _tempDir('tbm_a26_fresh_probe_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(dir.isFresh, isTrue);
      expect(dir.memoryDbExists, isFalse);
      expect(dir.vectorsDbExists, isFalse);
    });

    test('memoryDbExists flips to true once the file is materialised', () {
      // Simulates A.27+ landing the SQLite open — we cheat by
      // touching the file directly, which is enough to exercise
      // the probe.
      final parent = _tempDir('tbm_a26_db_probe_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      File(dir.memoryDbPath).writeAsStringSync('');
      expect(dir.memoryDbExists, isTrue);
      expect(dir.isFresh, isFalse);
    });
  });

  group('A.26 MemoryDirectory equality', () {
    test('two MemoryDirectory values for the same root compare equal', () {
      final parent = _tempDir('tbm_a26_eq_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final a = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      final b = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
