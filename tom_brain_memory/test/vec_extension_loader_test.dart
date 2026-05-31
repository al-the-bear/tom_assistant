// A.50 sqlite-vec (vec0) loader contract test.
//
// Locks the boot-time loader surface introduced by Plan step A.50:
//
//   1. `VecExtensionLoader.load(...)` outcomes
//      - empty extensionPath          → unavailable / notConfigured
//      - configured path missing      → unavailable / fileMissing
//      - dlopen throws                → failed / dynamicLibraryError
//      - symbol lookup throws         → failed / symbolMissing
//      - ensureExtensionLoaded throws → failed / registrationFailed
//      - everything succeeds          → loaded (verified by registrar
//                                        being invoked once with the
//                                        expected entrypoint pointer)
//
//   2. `VecExtensionLoader.load(...)` side-effect discipline
//      - unavailable branches never call the opener / lookup /
//        registrar.
//      - dlopen-failure branch never calls lookup / registrar.
//      - lookup-failure branch never calls registrar.
//
//   3. `VectorIndexUnavailable` event shape
//      - kind == 'memory.vector-index-unavailable'
//      - payloadJson carries extensionPath / reason / summary /
//        wasError, includes cause iff the originating outcome was
//        `failed`.
//      - is a `MemoryEvent` (so the spec § 16 stream typing holds).
//
//   4. `loadVecExtensionWithFailOpen` wiring helper
//      - emits exactly one event on every non-loaded outcome.
//      - emits zero events on the loaded outcome.
//      - the emitted event matches the loader's result (path /
//        reason / summary / cause).
//      - `wasError` matches the result.isFailed band (true for
//        failed, false for unavailable).
//      - injected `now` is used verbatim for `occurredAt`.
//
//   5. Defaults
//      - `entrypointSymbol` defaults to `sqlite3_vec_init` (the
//        upstream-shipped symbol). Locked because A.51+ wiring will
//        depend on this constant remaining stable.

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

/// One-shot tempdir helper. Returns the directory; teardown deletes
/// it recursively.
Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

/// Builds a `MemoryConfig.forTesting(...)` with an arbitrary
/// `extensionPath`. The memory root is a fresh tempdir.
MemoryConfig _configWithExtensionPath(String extensionPath) {
  final root = _tempDir('tbm_a50_').path;
  return MemoryConfig.forTesting(
    root: root,
    extensionPath: extensionPath,
  );
}

/// Writes a tiny file at `dir/name` and returns its path. Useful for
/// the "file exists but is not a shared library" assertion.
String _writeStubFile(Directory dir, String name, String contents) {
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.writeAsStringSync(contents);
  return file.path;
}

/// A `Pointer<Void>` that is never dereferenced. Synthesised via
/// `Pointer.fromAddress` so the loader's lookup → register path can
/// be exercised without a real shared library.
Pointer<Void> _fakeEntrypoint(int address) =>
    Pointer<Void>.fromAddress(address);

void main() {
  group('A.50 VecExtensionLoader — unavailable outcomes', () {
    test('empty extensionPath returns unavailable / notConfigured', () {
      final loader = VecExtensionLoader();
      final cfg = _configWithExtensionPath('');

      final result = loader.load(sqlite: sqlite3, config: cfg);

      expect(result.outcome, equals(VecLoadOutcome.unavailable));
      expect(result.reason, equals(VecUnavailableReason.notConfigured));
      expect(result.isUnavailable, isTrue);
      expect(result.isFailed, isFalse);
      expect(result.isLoaded, isFalse);
      expect(result.cause, isNull);
      expect(result.extensionPath, equals(''));
      expect(result.summary, contains('BM25-only mode'));
    });

    test('missing-on-disk path returns unavailable / fileMissing', () {
      final ghost =
          '${_tempDir('tbm_a50_ghost_').path}${Platform.pathSeparator}vec0.so';
      expect(File(ghost).existsSync(), isFalse);

      final loader = VecExtensionLoader();
      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(ghost),
      );

      expect(result.outcome, equals(VecLoadOutcome.unavailable));
      expect(result.reason, equals(VecUnavailableReason.fileMissing));
      expect(result.extensionPath, equals(ghost));
      expect(result.summary, contains(ghost));
      expect(result.summary, contains('BM25-only mode'));
      expect(result.cause, isNull);
    });

    test('unavailable branches never call the opener / lookup / registrar',
        () {
      var openerCalls = 0;
      var lookupCalls = 0;
      var registrarCalls = 0;

      final loader = VecExtensionLoader(
        openDynamicLibrary: (path) {
          openerCalls++;
          return DynamicLibrary.process();
        },
        lookupSymbol: (lib, sym) {
          lookupCalls++;
          return _fakeEntrypoint(0xDEAD);
        },
        registerExtension: (sql, ext) {
          registrarCalls++;
        },
      );

      // Empty path branch.
      loader.load(sqlite: sqlite3, config: _configWithExtensionPath(''));
      // Missing file branch.
      loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(
          '${_tempDir('tbm_a50_ghost2_').path}${Platform.pathSeparator}vec0.so',
        ),
      );

      expect(openerCalls, equals(0));
      expect(lookupCalls, equals(0));
      expect(registrarCalls, equals(0));
    });
  });

  group('A.50 VecExtensionLoader — failed outcomes', () {
    test('dlopen throwing returns failed / dynamicLibraryError', () {
      final root = _tempDir('tbm_a50_dlerr_');
      final stub = _writeStubFile(root, 'not_a_library.bin', 'plain text');

      var openerCalls = 0;
      var lookupCalls = 0;
      var registrarCalls = 0;

      final loader = VecExtensionLoader(
        openDynamicLibrary: (path) {
          openerCalls++;
          throw ArgumentError('synthetic dlopen failure for $path');
        },
        lookupSymbol: (lib, sym) {
          lookupCalls++;
          return _fakeEntrypoint(0xBEEF);
        },
        registerExtension: (sql, ext) {
          registrarCalls++;
        },
      );

      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
      );

      expect(result.outcome, equals(VecLoadOutcome.failed));
      expect(result.reason, equals(VecUnavailableReason.dynamicLibraryError));
      expect(result.isFailed, isTrue);
      expect(result.extensionPath, equals(stub));
      expect(result.cause, isA<ArgumentError>());
      expect(result.summary, contains('DynamicLibrary.open failed'));
      expect(openerCalls, equals(1));
      expect(lookupCalls, equals(0));
      expect(registrarCalls, equals(0));
    });

    test('symbol lookup throwing returns failed / symbolMissing', () {
      final root = _tempDir('tbm_a50_symerr_');
      final stub = _writeStubFile(root, 'fake_lib.bin', 'whatever');

      var registrarCalls = 0;

      final loader = VecExtensionLoader(
        openDynamicLibrary: (_) => DynamicLibrary.process(),
        lookupSymbol: (lib, sym) {
          throw ArgumentError('synthetic symbol-not-found $sym');
        },
        registerExtension: (sql, ext) {
          registrarCalls++;
        },
      );

      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
      );

      expect(result.outcome, equals(VecLoadOutcome.failed));
      expect(result.reason, equals(VecUnavailableReason.symbolMissing));
      expect(result.cause, isA<ArgumentError>());
      expect(
        result.summary,
        contains('"${VecExtensionLoader.defaultEntrypointSymbol}"'),
      );
      expect(registrarCalls, equals(0));
    });

    test(
        'ensureExtensionLoaded throwing returns failed / registrationFailed',
        () {
      final root = _tempDir('tbm_a50_regerr_');
      final stub = _writeStubFile(root, 'fake_lib.bin', 'whatever');

      final loader = VecExtensionLoader(
        openDynamicLibrary: (_) => DynamicLibrary.process(),
        lookupSymbol: (_, _) => _fakeEntrypoint(0xC0FFEE),
        registerExtension: (sql, ext) {
          throw StateError('synthetic registration failure');
        },
      );

      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
      );

      expect(result.outcome, equals(VecLoadOutcome.failed));
      expect(
        result.reason,
        equals(VecUnavailableReason.registrationFailed),
      );
      expect(result.cause, isA<StateError>());
      expect(result.summary, contains('ensureExtensionLoaded threw'));
    });
  });

  group('A.50 VecExtensionLoader — loaded outcome', () {
    test('happy path returns loaded and registers exactly once', () {
      final root = _tempDir('tbm_a50_happy_');
      final stub = _writeStubFile(root, 'fake_vec0.bin', 'pretend-binary');

      final lookupCalls = <String>[];
      final registered = <SqliteExtension>[];

      final loader = VecExtensionLoader(
        openDynamicLibrary: (_) => DynamicLibrary.process(),
        lookupSymbol: (lib, sym) {
          lookupCalls.add(sym);
          return _fakeEntrypoint(0x1234);
        },
        registerExtension: (sql, ext) {
          registered.add(ext);
        },
      );

      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
      );

      expect(result.outcome, equals(VecLoadOutcome.loaded));
      expect(result.isLoaded, isTrue);
      expect(result.reason, isNull);
      expect(result.cause, isNull);
      expect(result.extensionPath, equals(stub));
      expect(result.summary, contains('sqlite-vec loaded'));
      expect(
        lookupCalls,
        equals([VecExtensionLoader.defaultEntrypointSymbol]),
      );
      expect(registered, hasLength(1));
    });

    test('custom entrypoint symbol flows through to the lookup call', () {
      final root = _tempDir('tbm_a50_custom_sym_');
      final stub = _writeStubFile(root, 'fake_vec0.bin', 'pretend-binary');

      String? observedSymbol;

      final loader = VecExtensionLoader(
        entrypointSymbol: 'sqlite3_vec_alt_init',
        openDynamicLibrary: (_) => DynamicLibrary.process(),
        lookupSymbol: (lib, sym) {
          observedSymbol = sym;
          return _fakeEntrypoint(0x4321);
        },
        registerExtension: (_, _) {},
      );

      final result = loader.load(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
      );

      expect(result.isLoaded, isTrue);
      expect(observedSymbol, equals('sqlite3_vec_alt_init'));
    });

    test('default entrypoint symbol is "sqlite3_vec_init"', () {
      expect(
        VecExtensionLoader.defaultEntrypointSymbol,
        equals('sqlite3_vec_init'),
      );
    });
  });

  group('A.50 VectorIndexUnavailable event', () {
    test('is a MemoryEvent with the documented discriminator', () {
      final event = VectorIndexUnavailable(
        extensionPath: '',
        reason: VecUnavailableReason.notConfigured,
        summary: 'not configured',
        wasError: false,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );

      expect(event, isA<MemoryEvent>());
      expect(event.kind, equals('memory.vector-index-unavailable'));
    });

    test('payloadJson carries every field, omits cause when null', () {
      final event = VectorIndexUnavailable(
        extensionPath: '/x/vec0.so',
        reason: VecUnavailableReason.fileMissing,
        summary: 'not on disk',
        wasError: false,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );

      final payload = event.payloadJson();
      expect(payload['extensionPath'], equals('/x/vec0.so'));
      expect(payload['reason'], equals('fileMissing'));
      expect(payload['summary'], equals('not on disk'));
      expect(payload['wasError'], isFalse);
      expect(payload.containsKey('cause'), isFalse);
    });

    test('payloadJson includes cause when wasError is true', () {
      final cause = StateError('boom');
      final event = VectorIndexUnavailable(
        extensionPath: '/x/vec0.so',
        reason: VecUnavailableReason.registrationFailed,
        summary: 'register threw',
        wasError: true,
        cause: cause,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );

      final payload = event.payloadJson();
      expect(payload['wasError'], isTrue);
      expect(payload['cause'], equals(cause.toString()));
    });
  });

  group('A.50 loadVecExtensionWithFailOpen wiring helper', () {
    test('emits one event on unavailable / notConfigured', () {
      final events = <MemoryEvent>[];
      final now = DateTime.utc(2026, 5, 30, 9, 30, 0);

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _configWithExtensionPath(''),
        emit: events.add,
        now: () => now,
      );

      expect(result.isUnavailable, isTrue);
      expect(events, hasLength(1));
      final event = events.single as VectorIndexUnavailable;
      expect(event.reason, equals(VecUnavailableReason.notConfigured));
      expect(event.wasError, isFalse);
      expect(event.extensionPath, equals(''));
      expect(event.summary, equals(result.summary));
      expect(event.occurredAt, equals(now));
      expect(event.cause, isNull);
    });

    test('emits one event on unavailable / fileMissing', () {
      final ghost =
          '${_tempDir('tbm_a50_helper_ghost_').path}${Platform.pathSeparator}vec0.so';
      final events = <MemoryEvent>[];

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _configWithExtensionPath(ghost),
        emit: events.add,
      );

      expect(result.isUnavailable, isTrue);
      expect(events, hasLength(1));
      final event = events.single as VectorIndexUnavailable;
      expect(event.reason, equals(VecUnavailableReason.fileMissing));
      expect(event.wasError, isFalse);
      expect(event.extensionPath, equals(ghost));
    });

    test('emits one event on failed branches and sets wasError=true', () {
      final root = _tempDir('tbm_a50_helper_fail_');
      final stub = _writeStubFile(root, 'fake.bin', 'x');
      final events = <MemoryEvent>[];

      final brokenLoader = VecExtensionLoader(
        openDynamicLibrary: (path) =>
            throw ArgumentError('synthetic open failure for $path'),
      );

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
        emit: events.add,
        loader: brokenLoader,
      );

      expect(result.isFailed, isTrue);
      expect(events, hasLength(1));
      final event = events.single as VectorIndexUnavailable;
      expect(event.wasError, isTrue);
      expect(event.reason, equals(VecUnavailableReason.dynamicLibraryError));
      expect(event.cause, isA<ArgumentError>());
      expect(event.summary, equals(result.summary));
    });

    test('emits zero events on the loaded branch', () {
      final root = _tempDir('tbm_a50_helper_happy_');
      final stub = _writeStubFile(root, 'fake_vec0.bin', 'x');
      final events = <MemoryEvent>[];

      final happyLoader = VecExtensionLoader(
        openDynamicLibrary: (_) => DynamicLibrary.process(),
        lookupSymbol: (_, _) => _fakeEntrypoint(0xAABB),
        registerExtension: (_, _) {},
      );

      final result = loadVecExtensionWithFailOpen(
        sqlite: sqlite3,
        config: _configWithExtensionPath(stub),
        emit: events.add,
        loader: happyLoader,
      );

      expect(result.isLoaded, isTrue);
      expect(events, isEmpty);
    });
  });
}
