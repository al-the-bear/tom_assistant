// SqliteHostLibrary — branch coverage for the host-library repair.
//
// Every dependency is injected, so these run identically on a host whose
// SQLite is already capable and on one whose is not. The real-world
// verdict for the running process is asserted separately, in
// `vector_runtime_precondition_test.dart`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('SqliteHostLibrary.resolve', () {
    test('a capable default is left alone', () {
      var installed = 0;
      final resolution = SqliteHostLibrary(
        defaultIsCapable: () => true,
        candidates: () => ['/never/looked/at'],
        isCapable: (_) => true,
        install: (_) => installed++,
      ).resolve();

      expect(resolution.outcome, SqliteHostLibraryOutcome.defaultCapable);
      expect(resolution.isExtensionCapable, isTrue);
      expect(resolution.libraryPath, isNull);
      expect(resolution.candidatesTried, isEmpty);
      expect(installed, 0,
          reason: 'a host with a working SQLite must keep it');
    });

    test('an incapable default is repaired with the first capable candidate',
        () {
      final installedPaths = <String>[];
      final resolution = SqliteHostLibrary(
        defaultIsCapable: () => false,
        candidates: () => ['/a/missing', '/b/capable', '/c/also-capable'],
        isCapable: (path) => path != '/a/missing',
        install: installedPaths.add,
      ).resolve();

      expect(resolution.outcome, SqliteHostLibraryOutcome.overridden);
      expect(resolution.isExtensionCapable, isTrue);
      expect(resolution.libraryPath, '/b/capable');
      expect(resolution.candidatesTried, ['/a/missing', '/b/capable'],
          reason: 'candidates after the winner are never inspected');
      expect(installedPaths, ['/b/capable']);
    });

    test('an incapable default with no capable candidate reports the remedy',
        () {
      final resolution = SqliteHostLibrary(
        defaultIsCapable: () => false,
        candidates: () => ['/a', '/b'],
        isCapable: (_) => false,
        install: (_) => fail('nothing capable was found; nothing to install'),
      ).resolve();

      expect(resolution.outcome, SqliteHostLibraryOutcome.noCapableLibrary);
      expect(resolution.isExtensionCapable, isFalse);
      expect(resolution.libraryPath, isNull);
      expect(resolution.candidatesTried, ['/a', '/b']);
      expect(resolution.summary, contains('SQLITE_OMIT_LOAD_EXTENSION'));
      expect(resolution.summary, contains(sqliteLibraryEnvVar),
          reason: 'the message must name the way out');
      expect(resolution.summary, contains('/a, /b'),
          reason: 'the operator needs to know what was already tried');
    });

    test('an empty candidate list is the no-capable-library branch', () {
      final resolution = SqliteHostLibrary(
        defaultIsCapable: () => false,
        candidates: () => const <String>[],
        isCapable: (_) => fail('there is nothing to check'),
        install: (_) => fail('there is nothing to install'),
      ).resolve();

      expect(resolution.outcome, SqliteHostLibraryOutcome.noCapableLibrary);
      expect(resolution.summary, contains('<none>'));
    });

    test('a candidate that is not a shared library is rejected, not thrown',
        () {
      // The real capability probe opens the file. Pointing it at a
      // directory and at a plain text file drives both `DynamicLibrary`
      // failure shapes; the repair runs on the boot path, so neither may
      // escape as an exception.
      final scratch = Directory.systemTemp.createTempSync('tbm_host_lib_');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final notALibrary = File('${scratch.path}/not-a-library.dylib')
        ..writeAsStringSync('this is not a Mach-O / ELF image');

      final resolution = SqliteHostLibrary(
        defaultIsCapable: () => false,
        candidates: () => [
          '${scratch.path}/does-not-exist.dylib',
          scratch.path,
          notALibrary.path,
        ],
        install: (_) => fail('none of these can load extensions'),
      ).resolve();

      expect(resolution.outcome, SqliteHostLibraryOutcome.noCapableLibrary);
      expect(resolution.candidatesTried, hasLength(3));
    });
  });

  group('SqliteHostLibraryResolution.overrideTooLate', () {
    test('is not capable, and names the ordering rule and the remedy', () {
      final resolution = SqliteHostLibraryResolution(
        outcome: SqliteHostLibraryOutcome.overrideTooLate,
        libraryPath: '/b/capable',
        candidatesTried: const ['/b/capable'],
      );
      expect(resolution.isExtensionCapable, isFalse,
          reason: 'a repair that never ran did not repair anything');
      expect(resolution.summary, contains('/b/capable'));
      expect(resolution.summary, contains('extensionCapableSqlite3'),
          reason: 'the message must name the way out');
    });
  });

  group('SqliteHostLibrary.defaultCandidates', () {
    test('TOM_SQLITE3_LIB, when set, is the highest-priority candidate', () {
      final configured = Platform.environment[sqliteLibraryEnvVar];
      final candidates = SqliteHostLibrary.defaultCandidates().toList();
      if (configured != null && configured.isNotEmpty) {
        expect(candidates.first, configured);
      } else {
        expect(candidates, isNot(contains('')));
      }
    });

    test('macOS carries the Homebrew prefixes, other platforms do not', () {
      final candidates = SqliteHostLibrary.defaultCandidates().toList();
      final homebrew = candidates
          .where((c) => c.contains('/opt/sqlite/lib/libsqlite3.dylib'))
          .toList();
      if (Platform.isMacOS) {
        // Apple's system SQLite omits extension loading; Homebrew's does
        // not. Apple Silicon prefix before Intel.
        expect(homebrew, [
          '/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib',
          '/usr/local/opt/sqlite/lib/libsqlite3.dylib',
        ]);
      } else {
        expect(homebrew, isEmpty);
      }
    });
  });

  group('SqliteHostLibrary.platformDefaultIsCapable', () {
    test('a capable library loaded elsewhere in the process does not count',
        () {
      // Regression. `dart test` runs test files as isolates inside one
      // process and `DynamicLibrary.open` is process-wide, so as soon as
      // one isolate repairs itself the capable library is visible to
      // `DynamicLibrary.process()` from every other isolate. A probe that
      // consulted the process namespace therefore reported "capable" in
      // isolates still bound to Apple's system SQLite: the repair was
      // skipped, the store failed to boot, and because the resolution
      // claimed to be capable even the remedy note was suppressed.
      final resolution = ensureExtensionCapableSqlite();
      if (resolution.outcome != SqliteHostLibraryOutcome.overridden) {
        markTestSkipped('nothing was loaded on this host, so there is '
            'nothing that could contaminate the process namespace '
            '(${resolution.outcome.name})');
        return;
      }

      // The repair really did load a capable image into this process …
      expect(
        SqliteHostLibrary.libraryAtPathIsCapable(resolution.libraryPath!),
        isTrue,
      );
      // … and the default probe must still answer for the isolate's own
      // handle, which is the incapable one.
      expect(SqliteHostLibrary.platformDefaultIsCapable(), isFalse,
          reason: 'the probe must mirror what package:sqlite3 would open, '
              'not what happens to be loaded in the process');
    });

    test('it stays consistent with the outcome it produced', () {
      // Host-independent: whatever this machine is, the verdict and the
      // branch taken must still agree after the repair has run.
      final resolution = ensureExtensionCapableSqlite();
      final isCapable = SqliteHostLibrary.platformDefaultIsCapable();
      switch (resolution.outcome) {
        case SqliteHostLibraryOutcome.defaultCapable:
          expect(isCapable, isTrue);
        case SqliteHostLibraryOutcome.overridden:
        case SqliteHostLibraryOutcome.overrideTooLate:
        case SqliteHostLibraryOutcome.noCapableLibrary:
          expect(isCapable, isFalse,
              reason: 'the default was incapable when we branched; loading '
                  'a replacement must not change that answer');
        case SqliteHostLibraryOutcome.notApplicable:
          break;
      }
    });
  });

  group('SqliteHostLibrary.platformDefaultLibraryName', () {
    test('names the library package:sqlite3 would open here', () {
      final name = SqliteHostLibrary.platformDefaultLibraryName;
      if (Platform.isMacOS || Platform.isIOS) {
        expect(name, 'libsqlite3.dylib');
      } else if (Platform.isLinux || Platform.isAndroid) {
        expect(name, 'libsqlite3.so');
      } else if (Platform.isWindows) {
        expect(name, 'sqlite3.dll');
      } else {
        expect(name, isNull);
      }
    });
  });

  group('ensureExtensionCapableSqlite', () {
    test('is idempotent within an isolate', () {
      final first = ensureExtensionCapableSqlite();
      final second = ensureExtensionCapableSqlite();
      expect(identical(first, second), isTrue,
          reason: 'the override may only be installed once, before the '
              'first sqlite3 access');
    });

    test('an override that took effect is reported as overridden, not late',
        () {
      // The suite reaches `extensionCapableSqlite3` before anything
      // touches the bare `sqlite3` getter, so on a host that needs the
      // repair the override must actually have run. `overrideTooLate` here
      // would mean the ordering guarantee is broken.
      final resolution = ensureExtensionCapableSqlite();
      expect(resolution.outcome, isNot(SqliteHostLibraryOutcome.overrideTooLate),
          reason: resolution.summary);
    });

    test('publishes its verdict for diagnostics to read', () {
      final resolution = ensureExtensionCapableSqlite();
      expect(sqliteHostLibraryResolution, same(resolution));
      expect(resolution.summary, isNotEmpty);
      expect(resolution.toString(), contains(resolution.outcome.name));
    });
  });
}
