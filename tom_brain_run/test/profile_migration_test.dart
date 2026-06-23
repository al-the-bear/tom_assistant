// Step 8 — one-shot legacy-store migration
// (`memory_session_profiles.md` § 11, plan step 8, decisions MSPP-26/MSPP-27).
//
// `migrateLegacyMemoryRoot` relocates a pre-profiles bare-root memory store into
// `<root>/profiles/defaultmemory_default/` exactly once, leaving every
// `.root`-keyed non-memory store in place, and is an idempotent no-op on every
// boot after the first.
//
// Group 1 proves the file-layout contract + idempotency with plain fixture files
// (no store, so no vec0 needed). Group 2 proves the done-when's "default-profile
// reads return the migrated data" with a real on-disk store round-trip — gated on
// the packaged vec0 binary like the other tom_brain_run live suites.

import 'dart:io';
import 'dart:typed_data';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, SqliteTomBrainMemory, SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart'
    show LegacyMigrationOutcome, migrateLegacyMemoryRoot;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, Scope, Vec;
import 'package:test/test.dart';

/// The boot default profile name (MSP-4). Kept as a local literal so the test
/// fails loudly if the production constant ever drifts away from the on-disk
/// directory the migration must produce.
const String _defaultProfile = 'defaultmemory_default';

void main() {
  String sep = Platform.pathSeparator;

  /// A fresh temp root, torn down after the test.
  Directory freshRoot() {
    final root = Directory.systemTemp.createTempSync('tom_brain_run_mig_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return root;
  }

  void writeFile(String path, [String content = 'x']) =>
      File(path)..createSync(recursive: true)..writeAsStringSync(content);

  /// Lays down a legacy bare-root store (DB files + sidecars + the three
  /// store subdirectories) plus the `.root`-keyed non-memory stores that must
  /// NOT move.
  void seedLegacyRoot(String root) {
    // Store artifacts (move set).
    writeFile('$root${sep}memory.db', 'MEMORY');
    writeFile('$root${sep}memory.db-wal');
    writeFile('$root${sep}memory.db-shm');
    writeFile('$root${sep}vectors.db', 'VECTORS');
    writeFile('$root${sep}vectors.db-wal');
    writeFile('$root${sep}trails${sep}run.jsonl', 'trail');
    writeFile('$root${sep}tombstones${sep}t.json', 'tomb');
    writeFile('$root${sep}checkpoints${sep}c.bin', 'ckpt');
    // Non-memory stores (must stay at the bare root).
    writeFile('$root${sep}session_todos.json', 'todos');
    writeFile('$root${sep}agent_sdk_sessions.json', 'agent');
    writeFile('$root${sep}dream_lane_sessions.json', 'dream');
    writeFile('$root${sep}telegram_sessions.json', 'tg');
    writeFile('$root${sep}edge_state${sep}rate.json', 'edge');
  }

  group('migrateLegacyMemoryRoot — file layout + idempotency', () {
    test('relocates the legacy store into profiles/$_defaultProfile', () {
      final root = freshRoot().path;
      seedLegacyRoot(root);

      final outcome = migrateLegacyMemoryRoot(MemoryConfig.forTesting(root: root));
      expect(outcome, LegacyMigrationOutcome.migrated);

      final dest = '$root${sep}profiles$sep$_defaultProfile';
      // Store artifacts (and their sidecars) moved into the default profile dir.
      expect(File('$dest${sep}memory.db').readAsStringSync(), 'MEMORY');
      expect(File('$dest${sep}memory.db-wal').existsSync(), isTrue);
      expect(File('$dest${sep}memory.db-shm').existsSync(), isTrue);
      expect(File('$dest${sep}vectors.db').readAsStringSync(), 'VECTORS');
      expect(File('$dest${sep}vectors.db-wal').existsSync(), isTrue);
      expect(File('$dest${sep}trails${sep}run.jsonl').existsSync(), isTrue);
      expect(File('$dest${sep}tombstones${sep}t.json').existsSync(), isTrue);
      expect(File('$dest${sep}checkpoints${sep}c.bin').existsSync(), isTrue);

      // The bare root no longer holds the moved artifacts.
      expect(File('$root${sep}memory.db').existsSync(), isFalse);
      expect(File('$root${sep}vectors.db').existsSync(), isFalse);
      expect(Directory('$root${sep}trails').existsSync(), isFalse);
      expect(Directory('$root${sep}tombstones').existsSync(), isFalse);
      expect(Directory('$root${sep}checkpoints').existsSync(), isFalse);

      // The `.root`-keyed non-memory stores stay exactly where they were.
      expect(File('$root${sep}session_todos.json').existsSync(), isTrue);
      expect(File('$root${sep}agent_sdk_sessions.json').existsSync(), isTrue);
      expect(File('$root${sep}dream_lane_sessions.json').existsSync(), isTrue);
      expect(File('$root${sep}telegram_sessions.json').existsSync(), isTrue);
      expect(File('$root${sep}edge_state${sep}rate.json').existsSync(), isTrue);
    });

    test('a second boot is a no-op (alreadyProfiled), layout unchanged', () {
      final root = freshRoot().path;
      seedLegacyRoot(root);
      final config = MemoryConfig.forTesting(root: root);

      expect(migrateLegacyMemoryRoot(config), LegacyMigrationOutcome.migrated);
      // Second pass: profiles/ now exists → no-op.
      expect(migrateLegacyMemoryRoot(config), LegacyMigrationOutcome.alreadyProfiled);

      final dest = '$root${sep}profiles$sep$_defaultProfile';
      // Migrated data is untouched by the second pass.
      expect(File('$dest${sep}memory.db').readAsStringSync(), 'MEMORY');
      // No legacy store is re-created at the bare root.
      expect(File('$root${sep}memory.db').existsSync(), isFalse);
    });

    test('a fresh install with no legacy store is a no-op (noLegacyStore)', () {
      final root = freshRoot().path;
      // Only a non-memory file is present — nothing memory-shaped to move.
      writeFile('$root${sep}session_todos.json', 'todos');

      expect(
        migrateLegacyMemoryRoot(MemoryConfig.forTesting(root: root)),
        LegacyMigrationOutcome.noLegacyStore,
      );
      // No profiles/ directory is created for a fresh install.
      expect(Directory('$root${sep}profiles').existsSync(), isFalse);
      expect(File('$root${sep}session_todos.json').existsSync(), isTrue);
    });

    test('an already-profiled root is left untouched even with a bare memory.db',
        () {
      final root = freshRoot().path;
      writeFile('$root${sep}memory.db', 'STRAY');
      // A pre-existing profiles/ dir means the install is already profiled; the
      // gate must not move the (unrelated) bare-root memory.db.
      Directory('$root${sep}profiles$sep$_defaultProfile')
          .createSync(recursive: true);

      expect(
        migrateLegacyMemoryRoot(MemoryConfig.forTesting(root: root)),
        LegacyMigrationOutcome.alreadyProfiled,
      );
      expect(File('$root${sep}memory.db').readAsStringSync(), 'STRAY');
    });
  });

  // ── Group 2: real-store round-trip (needs the packaged vec0 binary) ──────
  final String? vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }
  final String? skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under tom_binaries/sqlite_vec.'
      : null;

  group('migrateLegacyMemoryRoot — default-profile reads see migrated data', () {
    test('a node written to the legacy root is readable through the default '
        'profile after migration', () async {
      final root = freshRoot().path;
      final base = MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!);

      // 1. Write a node into the legacy bare-root store, then close it.
      final legacy = SqliteTomBrainMemory();
      await legacy.open(base);
      final id = await legacy.persist(
        NodeDraft(
          typeName: 'Event',
          values: const {'summary': 'migrated event', 'payload': <String, Object?>{}},
          embedding: _v768(seed: 8),
        ),
        scope: const Scope.nonIdempotent(producer: 'test:migration'),
      );
      await legacy.close();

      // 2. Migrate the bare-root store into the default profile.
      expect(migrateLegacyMemoryRoot(base), LegacyMigrationOutcome.migrated);

      // 3. Open the store at the *profiled default* path and read the node back.
      final migrated = SqliteTomBrainMemory();
      await migrated.open(base.withProfile(_defaultProfile));
      final node = await migrated.get(id);
      await migrated.close();

      expect(node, isNotNull);
      expect(node!.values['summary'], 'migrated event');
    });
  }, skip: skipNoBinary);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec` (mirrors r30 / r37).
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory(
      '${dir.path}${Platform.pathSeparator}tom_binaries'
      '${Platform.pathSeparator}sqlite_vec',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// A deterministic 768-dim (nomic-embed-text) embedding — the round-trip rides
/// on the *presence* of a dimension-correct embedding, not its values.
Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}
