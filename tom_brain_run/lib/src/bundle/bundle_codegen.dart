// Bundle codegen — reads the `cognition/` prompts, the `scripts/system/`
// procedures, and the native `vec0` libraries, builds a [BundleManifest], and
// renders it as the Dart source `tom_brain bundle` writes to
// `lib/src/bundle/brain_bundle.g.dart` (`tom_brain_cli.md` § 4; CLI plan
// step 4).
//
// Split into two pure-ish halves on purpose:
//
//   * [buildBundleManifest] does the filesystem reads and returns an in-memory
//     [BundleManifest] — so a test asserts the map contents directly.
//   * [renderBundleSource] turns a [BundleManifest] into a Dart source string —
//     so a test asserts the rendered source without compiling it.
//
// Keeping them separate is what makes the codegen round-trip testable without a
// generated-code compile step: build a manifest from temp dirs, render it,
// re-parse / re-extract, and compare.

import 'dart:convert' show base64, utf8;
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart' show sha256;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show SqliteVecBinaryResolver, UnsupportedSqliteVecPlatform;

import 'bundle_manifest.dart';

/// Raised when the bundle codegen cannot read an input it was pointed at — a
/// missing prompts/scripts directory, or a native `vec0` library absent from
/// the binaries root for a requested platform.
final class BundleCodegenException implements Exception {
  /// Operator-facing explanation.
  final String message;

  const BundleCodegenException(this.message);

  @override
  String toString() => 'BundleCodegenException: $message';
}

/// Reads the bundle inputs and assembles a [BundleManifest].
///
///   * [promptsDir] — root of the `cognition/` prompt templates. Every file
///     under it (recursively) is bundled, keyed by its `/`-separated path
///     relative to [promptsDir] (the key the run layer's bundled prompt
///     resolver looks up). `null` bundles no prompts.
///   * [scriptsDir] — `scripts/system/` directory. Every `*.dart` file in it
///     (non-recursive, matching the disk store) is bundled, keyed by its
///     filename stem (the `.dart` / `.d4rt.dart` extension stripped). `null`
///     bundles no scripts.
///   * [sqliteVecBinariesRoot] — the `tom_binaries/sqlite_vec/` tree. The
///     `vec0` library for each requested platform is base64-encoded. `null`
///     bundles no native libraries.
///   * [platforms] — the ABIs to bake native libraries for. Defaults to
///     `[currentAbi]` (the current build platform only); pass every shipped
///     ABI for an `--all-platforms` build.
///   * [currentAbi] — the build platform, defaulting to `Abi.current()`.
///     Injectable so tests drive a deterministic platform.
///
/// The `sha256:` [BundleManifest.buildHash] is computed over the sorted
/// entries (prompts, scripts, then decoded native bytes) so it is stable for a
/// given input set regardless of read order.
Future<BundleManifest> buildBundleManifest({
  Directory? promptsDir,
  Directory? scriptsDir,
  Directory? sqliteVecBinariesRoot,
  List<Abi>? platforms,
  Abi? currentAbi,
}) async {
  final prompts = promptsDir == null
      ? <String, String>{}
      : await _readPrompts(promptsDir);
  final scripts = scriptsDir == null
      ? <String, String>{}
      : await _readScripts(scriptsDir);
  final sqliteVec = sqliteVecBinariesRoot == null
      ? <String, String>{}
      : await _readNativeLibraries(
          sqliteVecBinariesRoot,
          platforms ?? <Abi>[currentAbi ?? Abi.current()],
        );

  return BundleManifest(
    prompts: prompts,
    scripts: scripts,
    sqliteVec: sqliteVec,
    buildHash: _buildHash(prompts, scripts, sqliteVec),
  );
}

Future<Map<String, String>> _readPrompts(Directory dir) async {
  if (!dir.existsSync()) {
    throw BundleCodegenException('prompts directory not found: ${dir.path}');
  }
  final out = <String, String>{};
  final rootPath = _trimTrailingSeparators(dir.path);
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final key = _relativePosix(rootPath, entity.path);
    out[key] = await entity.readAsString();
  }
  return out;
}

Future<Map<String, String>> _readScripts(Directory dir) async {
  if (!dir.existsSync()) {
    throw BundleCodegenException('scripts directory not found: ${dir.path}');
  }
  final out = <String, String>{};
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = _fileName(entity.path);
    if (!name.endsWith('.dart')) continue;
    out[_scriptLocator(name)] = await entity.readAsString();
  }
  return out;
}

Future<Map<String, String>> _readNativeLibraries(
  Directory binariesRoot,
  List<Abi> platforms,
) async {
  if (!binariesRoot.existsSync()) {
    throw BundleCodegenException(
      'sqlite-vec binaries root not found: ${binariesRoot.path}',
    );
  }
  final root = _trimTrailingSeparators(binariesRoot.path);
  final out = <String, String>{};
  for (final abi in platforms) {
    final resolver = SqliteVecBinaryResolver(abi: abi);
    final String tuple;
    final String libPath;
    try {
      tuple = resolver.platformTuple;
      libPath = resolver.resolve(root);
    } on UnsupportedSqliteVecPlatform catch (e) {
      throw BundleCodegenException('cannot bundle native library: $e');
    }
    final file = File(libPath);
    if (!file.existsSync()) {
      throw BundleCodegenException(
        'native vec0 library not found for $tuple: $libPath',
      );
    }
    out[tuple] = base64.encode(await file.readAsBytes());
  }
  return out;
}

/// `sha256:<hex>` over the sorted prompt/script entries and decoded native
/// bytes — stable for a given input set.
String _buildHash(
  Map<String, String> prompts,
  Map<String, String> scripts,
  Map<String, String> sqliteVec,
) {
  final bytes = BytesBuilder(copy: false);
  void addText(String section, Map<String, String> map) {
    final keys = map.keys.toList()..sort();
    for (final key in keys) {
      bytes
        ..add(utf8.encode('$section\u0000$key\u0000'))
        ..add(utf8.encode(map[key]!))
        ..addByte(0);
    }
  }

  addText('prompt', prompts);
  addText('script', scripts);
  final nativeKeys = sqliteVec.keys.toList()..sort();
  for (final key in nativeKeys) {
    bytes
      ..add(utf8.encode('native\u0000$key\u0000'))
      ..add(base64.decode(sqliteVec[key]!))
      ..addByte(0);
  }
  return 'sha256:${sha256.convert(bytes.takeBytes())}';
}

/// Renders [manifest] as the Dart source `brain_bundle.g.dart` carries.
///
/// The output assigns the manifest to a top-level `final` named [constName]
/// (default `brainBundle`) — matching the committed default's declaration.
String renderBundleSource(
  BundleManifest manifest, {
  String constName = 'brainBundle',
}) {
  final b = StringBuffer()
    ..writeln('// GENERATED — `tom_brain bundle` overwrites this file.')
    ..writeln('//')
    ..writeln('// Compiled-in asset bundle (`tom_brain_cli.md` § 4).')
    ..writeln("import 'bundle_manifest.dart';")
    ..writeln()
    ..writeln('/// The compiled-in asset bundle.')
    ..writeln('final BundleManifest $constName = BundleManifest(')
    ..write(_renderStringMap('prompts', manifest.prompts))
    ..write(_renderStringMap('scripts', manifest.scripts))
    ..write(_renderStringMap('sqliteVec', manifest.sqliteVec))
    ..writeln('  buildHash: ${_dartString(manifest.buildHash)},')
    ..writeln(');');
  return b.toString();
}

String _renderStringMap(String field, Map<String, String> map) {
  if (map.isEmpty) {
    return '  $field: const <String, String>{},\n';
  }
  final b = StringBuffer()..writeln('  $field: <String, String>{');
  final keys = map.keys.toList()..sort();
  for (final key in keys) {
    b.writeln('    ${_dartString(key)}: ${_dartString(map[key]!)},');
  }
  b.writeln('  },');
  return b.toString();
}

/// Renders a Dart single-line string literal, escaping the characters that
/// would otherwise break out of `'...'` (and `$` for interpolation).
String _dartString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return "'$escaped'";
}

String _scriptLocator(String fileName) {
  var stem = fileName;
  if (stem.endsWith('.dart')) {
    stem = stem.substring(0, stem.length - '.dart'.length);
  }
  if (stem.endsWith('.d4rt')) {
    stem = stem.substring(0, stem.length - '.d4rt'.length);
  }
  return stem;
}

String _fileName(String path) {
  final slash = path.lastIndexOf('/');
  final back = path.lastIndexOf(r'\');
  final cut = slash > back ? slash : back;
  return cut < 0 ? path : path.substring(cut + 1);
}

String _relativePosix(String rootPath, String filePath) {
  var rel = filePath;
  if (rel.startsWith(rootPath)) {
    rel = rel.substring(rootPath.length);
  }
  rel = rel.replaceAll(r'\', '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}

String _trimTrailingSeparators(String path) {
  var end = path.length;
  while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}
