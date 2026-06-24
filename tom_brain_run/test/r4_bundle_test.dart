// Step 4 (tom_brain_cli_plan.md) — the compiled-in asset bundle: the
// `BundleManifest` value type + empty default, the `tom_brain bundle` codegen
// (`buildBundleManifest` / `renderBundleSource`), `BundledSqliteVec` extract +
// hash-skip, the `resolveSqliteVecBinariesRoot` resolution order, the `--list`
// rendering, and the native-library size budget.
//
// Contract under test (the new pieces this step adds):
//
//   * `BundleManifest` carries `prompts` / `scripts` / `sqliteVec` maps + a
//     `sha256:` `buildHash`; `BundleManifest.empty` (what the committed
//     `brain_bundle.g.dart` links against) is empty so a no-bundle build
//     compiles.
//   * `buildBundleManifest(...)` reads the prompt/script/native inputs into a
//     manifest; `renderBundleSource(...)` turns one back into Dart source — the
//     two halves the codegen round-trips through.
//   * `BundledSqliteVec.extract(...)` decodes + writes the current platform's
//     `vec0` under `<binariesRoot>/<platform>/vec0.<ext>`, skipping the write
//     when an identical file is already there.
//   * `resolveSqliteVecBinariesRoot(...)` walks explicit config → on-disk
//     agent bin → bundle (extracted) → `${TOM_BINARIES_ROOT}` → boot error.
//   * `renderBundleListing(...)` prints the prompt/script ids, native
//     platforms, and build hash.

import 'dart:convert' show base64;
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show SqliteVecConfig;

/// `<workspace>/tom_binaries/sqlite_vec`, walking up from the test cwd. Mirrors
/// the #34 / #35 suites.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}${Platform.pathSeparator}'
        'tom_binaries${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// The five ABIs whose `vec0` libraries are shipped in-quest (linux-armhf is
/// not built, so it is not an `--all-platforms` target).
const List<Abi> _allShippedAbis = <Abi>[
  Abi.macosArm64,
  Abi.macosX64,
  Abi.linuxArm64,
  Abi.linuxX64,
  Abi.windowsX64,
];

/// A synthetic single-platform manifest carrying [bytes] for the current ABI —
/// used by the extract / resolution tests that should not depend on the real
/// binaries.
BundleManifest _syntheticManifest(Uint8List bytes, {Abi? abi}) {
  final tuple = SqliteVecBinaryResolver(abi: abi).platformTuple;
  return BundleManifest(
    prompts: const <String, String>{},
    scripts: const <String, String>{},
    sqliteVec: <String, String>{tuple: base64.encode(bytes)},
    buildHash: 'sha256:test',
  );
}

void main() {
  group('empty-manifest default', () {
    test('BundleManifest.empty carries nothing', () {
      expect(BundleManifest.empty.isEmpty, isTrue);
      expect(BundleManifest.empty.prompts, isEmpty);
      expect(BundleManifest.empty.scripts, isEmpty);
      expect(BundleManifest.empty.sqliteVec, isEmpty);
      expect(BundleManifest.empty.buildHash, isEmpty);
    });

    test('the committed brain_bundle.g.dart links the empty default', () {
      // A fresh, un-bundled checkout must compile and boot with no assets.
      expect(brainBundle.isEmpty, isTrue);
    });

    test('rendering the empty manifest emits compile-able empty maps', () {
      final source = renderBundleSource(BundleManifest.empty);
      expect(source, contains('BundleManifest('));
      expect(source, contains('prompts: const <String, String>{}'));
      expect(source, contains('scripts: const <String, String>{}'));
      expect(source, contains('sqliteVec: const <String, String>{}'));
    });
  });

  group('codegen round-trip — buildBundleManifest + renderBundleSource', () {
    late Directory root;
    late String? vecRoot;

    setUp(() {
      root = Directory.systemTemp.createTempSync('r4_codegen_');
      addTearDown(() => root.deleteSync(recursive: true));
      vecRoot = _findSqliteVecRoot();

      Directory('${root.path}/prompts/sub').createSync(recursive: true);
      File('${root.path}/prompts/top.user.md').writeAsStringSync('TOP body');
      File('${root.path}/prompts/sub/nested.system.md')
          .writeAsStringSync('NESTED body');

      Directory('${root.path}/scripts').createSync(recursive: true);
      File('${root.path}/scripts/foo_v1.dart').writeAsStringSync('// foo');
      File('${root.path}/scripts/bar_v1.d4rt.dart').writeAsStringSync('// bar');
      File('${root.path}/scripts/notes.txt').writeAsStringSync('ignored');
    });

    test('prompts key by cognition-root-relative path; scripts by stem',
        () async {
      final manifest = await buildBundleManifest(
        promptsDir: Directory('${root.path}/prompts'),
        scriptsDir: Directory('${root.path}/scripts'),
      );
      expect(manifest.prompts, containsPair('top.user.md', 'TOP body'));
      expect(
          manifest.prompts, containsPair('sub/nested.system.md', 'NESTED body'));
      expect(manifest.scripts, containsPair('foo_v1', '// foo'));
      expect(manifest.scripts, containsPair('bar_v1', '// bar'));
      // A non-.dart file is not a procedure.
      expect(manifest.scripts.containsKey('notes'), isFalse);
      expect(manifest.buildHash, startsWith('sha256:'));
    });

    test('the build hash is stable across reads (sorted, content-derived)',
        () async {
      final a = await buildBundleManifest(
        promptsDir: Directory('${root.path}/prompts'),
        scriptsDir: Directory('${root.path}/scripts'),
      );
      final b = await buildBundleManifest(
        promptsDir: Directory('${root.path}/prompts'),
        scriptsDir: Directory('${root.path}/scripts'),
      );
      expect(a.buildHash, equals(b.buildHash));
      expect(a.buildHash, isNot(equals('sha256:')));
    });

    test('rendered source carries every key/value and the build hash',
        () async {
      final manifest = await buildBundleManifest(
        promptsDir: Directory('${root.path}/prompts'),
        scriptsDir: Directory('${root.path}/scripts'),
      );
      final source = renderBundleSource(manifest);
      expect(source, contains("'top.user.md': 'TOP body'"));
      expect(source, contains("'sub/nested.system.md': 'NESTED body'"));
      expect(source, contains("'foo_v1': '// foo'"));
      expect(source, contains("'bar_v1': '// bar'"));
      expect(source, contains(manifest.buildHash));
    });

    test('the default native target is the current build platform only',
        () async {
      if (vecRoot == null) {
        markTestSkipped('tom_binaries/sqlite_vec not found');
        return;
      }
      final resolver = SqliteVecBinaryResolver();
      if (!resolver.isSupported) {
        markTestSkipped('current platform is not a sqlite-vec target');
        return;
      }
      final manifest = await buildBundleManifest(
        sqliteVecBinariesRoot: Directory(vecRoot!),
      );
      expect(manifest.nativePlatforms, equals(<String>[resolver.platformTuple]));
    });
  });

  group('BundledSqliteVec.extract — decode, write, hash-skip', () {
    late Directory root;
    late SqliteVecBinaryResolver resolver;
    late String relPath;
    final payload = Uint8List.fromList(List<int>.generate(64, (i) => i));

    setUp(() {
      root = Directory.systemTemp.createTempSync('r4_extract_');
      addTearDown(() => root.deleteSync(recursive: true));
      resolver = SqliteVecBinaryResolver();
      relPath = '${resolver.platformTuple}/${resolver.libraryFileName}';
    });

    test('decodes the current platform and writes the vec0 file', () async {
      final vec = BundledSqliteVec(_syntheticManifest(payload));
      final used = await vec.extract(binariesRoot: root.path);
      expect(used, equals(root.path));
      final file = File('${root.path}/$relPath');
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), equals(payload));
    });

    test('an identical existing file is left untouched (hash-skip)', () async {
      final file = File('${root.path}/$relPath')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(payload);
      final past = DateTime(2001, 1, 1);
      file.setLastModifiedSync(past);

      await BundledSqliteVec(_syntheticManifest(payload))
          .extract(binariesRoot: root.path);

      expect(file.lastModifiedSync(), equals(past),
          reason: 'identical bytes → no rewrite');
    });

    test('a stale existing file is overwritten with the bundled bytes',
        () async {
      final file = File('${root.path}/$relPath')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List.fromList(<int>[9, 9, 9]));
      final past = DateTime(2001, 1, 1);
      file.setLastModifiedSync(past);

      await BundledSqliteVec(_syntheticManifest(payload))
          .extract(binariesRoot: root.path);

      expect(file.readAsBytesSync(), equals(payload));
      expect(file.lastModifiedSync().isAfter(past), isTrue);
    });

    test('a bundle with no library for the platform throws', () async {
      final empty = BundleManifest(
        prompts: const {},
        scripts: const {},
        sqliteVec: const {},
        buildHash: 'sha256:x',
      );
      expect(
        () => BundledSqliteVec(empty).extract(binariesRoot: root.path),
        throwsA(isA<SqliteVecUnavailable>()),
      );
    });
  });

  group('resolveSqliteVecBinariesRoot — resolution order', () {
    late Directory root;
    late SqliteVecBinaryResolver resolver;
    final payload = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

    setUp(() {
      root = Directory.systemTemp.createTempSync('r4_resolve_');
      addTearDown(() => root.deleteSync(recursive: true));
      resolver = SqliteVecBinaryResolver();
    });

    test('explicit config.binariesRoot wins', () async {
      final res = await resolveSqliteVecBinariesRoot(
        config: const SqliteVecConfig(binariesRoot: '/explicit/root'),
        agentBinRoot: '${root.path}/agent/bin',
        bundle: _syntheticManifest(payload),
        env: (_) => null,
      );
      expect(res.origin, equals(SqliteVecOrigin.explicitConfig));
      expect(res.binariesRoot, equals('/explicit/root'));
    });

    test('an on-disk agent-bin library wins over the bundle', () async {
      final agentBin = '${root.path}/agent/bin';
      File('$agentBin/sqlite_vec/${resolver.platformTuple}/'
              '${resolver.libraryFileName}')
          .createSync(recursive: true);
      final res = await resolveSqliteVecBinariesRoot(
        config: const SqliteVecConfig(),
        agentBinRoot: agentBin,
        bundle: _syntheticManifest(payload),
        env: (_) => null,
      );
      expect(res.origin, equals(SqliteVecOrigin.diskAgentBin));
      expect(res.binariesRoot, equals('$agentBin/sqlite_vec'));
    });

    test('falls through to the bundle and extracts it', () async {
      final agentBin = '${root.path}/agent/bin';
      final res = await resolveSqliteVecBinariesRoot(
        config: const SqliteVecConfig(),
        agentBinRoot: agentBin,
        bundle: _syntheticManifest(payload),
        env: (_) => null,
      );
      expect(res.origin, equals(SqliteVecOrigin.bundleExtracted));
      expect(res.binariesRoot, equals('$agentBin/sqlite_vec'));
      final extracted = File('${res.binariesRoot}/${resolver.platformTuple}/'
          '${resolver.libraryFileName}');
      expect(extracted.existsSync(), isTrue);
      expect(extracted.readAsBytesSync(), equals(payload));
    });

    test('falls to \${TOM_BINARIES_ROOT} when the bundle is empty', () async {
      final tomBinaries = '${root.path}/tom_binaries';
      File('$tomBinaries/sqlite_vec/${resolver.platformTuple}/'
              '${resolver.libraryFileName}')
          .createSync(recursive: true);
      final res = await resolveSqliteVecBinariesRoot(
        config: const SqliteVecConfig(),
        agentBinRoot: '${root.path}/agent/bin',
        bundle: BundleManifest.empty,
        env: (name) =>
            name == 'TOM_BINARIES_ROOT' ? tomBinaries : null,
      );
      expect(res.origin, equals(SqliteVecOrigin.tomBinariesEnv));
      expect(res.binariesRoot, equals('$tomBinaries/sqlite_vec'));
    });

    test('throws when every source is exhausted', () async {
      expect(
        () => resolveSqliteVecBinariesRoot(
          config: const SqliteVecConfig(),
          agentBinRoot: '${root.path}/agent/bin',
          bundle: BundleManifest.empty,
          env: (_) => null,
        ),
        throwsA(isA<SqliteVecUnavailable>()),
      );
    });
  });

  group('renderBundleListing — the --list inventory', () {
    test('an empty bundle renders an (empty) line', () {
      expect(renderBundleListing(BundleManifest.empty), contains('(empty'));
    });

    test('a populated bundle lists ids, platforms, and the build hash', () {
      final manifest = BundleManifest(
        prompts: const {'p.user.md': 'P'},
        scripts: const {'s_v1': 'S'},
        sqliteVec: {'linux-x64': base64.encode(<int>[1, 2, 3])},
        buildHash: 'sha256:abc',
      );
      final listing = renderBundleListing(manifest);
      expect(listing, contains('sha256:abc'));
      expect(listing, contains('p.user.md'));
      expect(listing, contains('s_v1'));
      expect(listing, contains('linux-x64'));
    });
  });

  group('native-library size budget', () {
    late String? vecRoot;

    setUp(() => vecRoot = _findSqliteVecRoot());

    test('a single-platform bundle stays in the ~125–283 KB band', () async {
      if (vecRoot == null) {
        markTestSkipped('tom_binaries/sqlite_vec not found');
        return;
      }
      final resolver = SqliteVecBinaryResolver();
      if (!resolver.isSupported) {
        markTestSkipped('current platform is not a sqlite-vec target');
        return;
      }
      final manifest = await buildBundleManifest(
        sqliteVecBinariesRoot: Directory(vecRoot!),
      );
      // Decoded bytes — AOT stores these, not the base64 source. The band
      // spans darwin-x64 (~125 KB) to win32-x64 (~283 KB), with margin.
      expect(manifest.decodedNativeSizeBytes,
          inInclusiveRange(120 * 1024, 300 * 1024));
    });

    test('--all-platforms bakes all five and totals ≈ 895 KB', () async {
      if (vecRoot == null) {
        markTestSkipped('tom_binaries/sqlite_vec not found');
        return;
      }
      final manifest = await buildBundleManifest(
        sqliteVecBinariesRoot: Directory(vecRoot!),
        platforms: _allShippedAbis,
      );
      expect(manifest.nativePlatforms.length, equals(5));
      expect(manifest.decodedNativeSizeBytes,
          inInclusiveRange(850 * 1024, 950 * 1024));
    });
  });
}
