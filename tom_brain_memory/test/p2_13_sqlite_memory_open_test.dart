// P2.13 — SqliteTomBrainMemory.open(config) assembly + refuse-to-boot.
//
// prototype_implementation_plan_2.md #13:
//   "Memory: implement SqliteTomBrainMemory.open(config). Assemble the
//    existing parts (MemoryDirectory.openOrCreate, applySchemaV1,
//    TwoDbCoordinator, BootIntegrityCheck) into the concrete store, and
//    wire loadVecExtensionOrRefuseToBoot into open() (closes P1.1) so a
//    missing/broken vec0 raises VectorRuntimeUnavailable and the store
//    refuses to open. […] Test: opens on a tmp dir with the packaged
//    binary; refuses to boot when the binary is absent/broken; schema +
//    bootstrap tables present after open. Verify: real vec0 query
//    roundtrip through an opened store (extends the existing a53 test to
//    go through open())."
//
// Two of the four cases (refuse-to-boot for an unconfigured runtime and
// for a broken binary) need no real binary and run on every host. The
// two positive cases (open + vec0 roundtrip, idempotent re-open) need
// the packaged vec0 and are skipped — not failed — when the running
// platform has no binary under tom_binaries/sqlite_vec/<platform>/,
// mirroring a53_real_vec0_binary_roundtrip_test.dart.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors a53_real_vec0_binary_roundtrip_test.dart.
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

  // Resolve the packaged binary for the running platform, if present.
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('SqliteTomBrainMemory.open — assembly (needs packaged vec0)', () {
    test(
      'opens a fresh root: directory layout + schema + bootstrap tables, '
      'and a real vec0 query roundtrips through the opened store',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_open_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final config = MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        );

        final store = SqliteTomBrainMemory();
        addTearDown(store.close);

        await store.open(config);

        // Directory layout materialised by MemoryDirectory.openOrCreate.
        expect(Directory('${root.path}/trails').existsSync(), isTrue);
        expect(Directory('${root.path}/tombstones').existsSync(), isTrue);
        expect(Directory('${root.path}/checkpoints').existsSync(), isTrue);

        // Schema applied transitively by BootIntegrityCheck's migrator.
        expect(
          readSchemaVersion(store.debugMemoryDatabase),
          equals(schemaV2Version),
        );

        // Bootstrap tables present after open.
        final tables = store.debugMemoryDatabase
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toSet();
        expect(
          tables,
          containsAll(<String>[
            'migrations',
            'nodes',
            'edges',
            'node_types',
            'stacks',
            'stack_entries',
            'trails',
            'pending_vector_writes',
            'centroids',
          ]),
        );

        // vectors.db carries the vector_indexes meta table.
        final vectorTables = store.debugVectorsDatabase
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toSet();
        expect(vectorTables, contains('vector_indexes'));

        // Real vec0 roundtrip through the opened store's vectors.db.
        // vec0 was registered with sqlite3_auto_extension before the
        // vectors.db connection was opened, so the handle has vec0.
        final vdb = store.debugVectorsDatabase;
        final version =
            vdb.select('SELECT vec_version() AS v').first['v'] as String;
        expect(version, isNotEmpty);

        vdb.execute('CREATE VIRTUAL TABLE vt USING vec0(embedding float[4])');
        vdb.execute("INSERT INTO vt(rowid, embedding) VALUES (1, '[1,2,3,4]')");
        final match = vdb.select(
          'SELECT rowid, distance FROM vt '
          "WHERE embedding MATCH '[1,2,3,4]' ORDER BY distance LIMIT 1",
        );
        expect(match, hasLength(1));
        expect(match.first['rowid'], equals(1));
        expect(match.first['distance'] as double, closeTo(0.0, 1e-6));
      },
      skip: skipNoBinary,
    );

    test(
      'is idempotent — a second open() on an already-open store is a no-op',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_reopen_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final config = MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        );

        final store = SqliteTomBrainMemory();
        addTearDown(store.close);

        await store.open(config);
        final firstHandle = store.debugMemoryDatabase;

        // Second open must return immediately without re-opening handles.
        await store.open(config);
        expect(identical(store.debugMemoryDatabase, firstHandle), isTrue);
      },
      skip: skipNoBinary,
    );
  });

  group('SqliteTomBrainMemory.open — refuse-to-boot (runs everywhere)', () {
    test(
      'throws VectorRuntimeUnavailable(notConfigured) and opens no DB '
      'when sqlite-vec is unconfigured',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_noboot_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        // Neither extensionPath nor binariesRoot is set.
        final config = MemoryConfig.forTesting(root: root.path);
        final store = SqliteTomBrainMemory();

        await expectLater(
          store.open(config),
          throwsA(
            isA<VectorRuntimeUnavailable>().having(
              (e) => e.reason,
              'reason',
              VecUnavailableReason.notConfigured,
            ),
          ),
        );

        // vec0 is loaded BEFORE any SQLite file is opened, so a refused
        // boot must not have materialised memory.db / vectors.db.
        expect(File('${root.path}/memory.db').existsSync(), isFalse);
        expect(File('${root.path}/vectors.db').existsSync(), isFalse);
      },
    );

    test(
      'throws VectorRuntimeUnavailable(wasError) when the configured '
      'binary is present but not a loadable shared library',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_broken_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        // A real file that exists but is not a shared library: the loader
        // gets past the file-missing check and fails at DynamicLibrary.open.
        final brokenBinary = File('${root.path}/not_a_real_vec0.bin')
          ..writeAsStringSync('this is not a shared library');

        final config = MemoryConfig.forTesting(
          root: root.path,
          extensionPath: brokenBinary.path,
        );
        final store = SqliteTomBrainMemory();

        await expectLater(
          store.open(config),
          throwsA(
            isA<VectorRuntimeUnavailable>().having(
              (e) => e.wasError,
              'wasError',
              isTrue,
            ),
          ),
        );

        expect(File('${root.path}/memory.db').existsSync(), isFalse);
      },
    );
  });
}
