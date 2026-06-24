// BundleManifest — the compiled-in asset bundle for the standalone `tom_brain`
// CLI (`tom_brain_cli.md` § 4; CLI plan step 4).
//
// Dart AOT has no native file-asset embedding, so the bundle is *generated Dart
// source*: text maps for the `cognition/` prompt templates and the
// `scripts/system/` procedures, plus base64-encoded byte maps for the native
// `sqlite-vec` library (one entry per baked platform tuple; CLI-Q13 override).
// The `tom_brain bundle` codegen renders a populated [BundleManifest] into
// `lib/src/bundle/brain_bundle.g.dart`; that file ships an empty default so a
// no-bundle build still compiles (`BundleManifest.empty`).
//
// This type is a pure value (no `dart:io`): it only owns the three text/byte
// maps and the content fingerprint. Decoding the native bytes, extracting them
// to disk, and pointing the memory config at them is `BundledSqliteVec`'s job
// (`bundled_sqlite_vec.dart`); reading the source trees and rendering the Dart
// source is `bundle_codegen.dart`'s job. Keeping the manifest side-effect-free
// is what lets the round-trip test build and assert a manifest in memory
// without compiling generated Dart.

import 'dart:convert' show base64;
import 'dart:typed_data' show Uint8List;

/// Compiled-in asset bundle: prompt + script text maps, native `vec0` byte
/// maps, and a content fingerprint.
///
/// Immutable value type. The maps are captured unmodifiable at construction so
/// a caller's later mutation cannot reach the bundle. [empty] is the default a
/// freshly checked-out (un-bundled) build links against.
final class BundleManifest {
  /// `cognition-root-relative template path → verbatim template body`.
  ///
  /// Keyed by the same path the run layer's `buildBundledPromptResolver`
  /// looks a registered prompt's template file up by (step 3), so a bundled
  /// prompt resolves with no on-disk `cognition/` tree.
  final Map<String, String> prompts;

  /// `procedure locator → verbatim d4rt source`.
  ///
  /// Keyed by the bundle-local locator `BundledProcedureStore` addresses each
  /// procedure by (step 3) — typically the source filename stem.
  final Map<String, String> scripts;

  /// `platform tuple → base64 of vec0.{so,dylib,dll}`.
  ///
  /// Platform tuples are the `SqliteVecBinaryResolver` set (`linux-x64`,
  /// `darwin-arm64`, `win32-x64`, …). The default build bakes only the current
  /// platform; `--all-platforms` bakes every shipped tuple.
  final Map<String, String> sqliteVec;

  /// Content fingerprint of the whole bundle (`sha256:<hex>`), computed by the
  /// codegen over the sorted entries. Empty for [empty]. Used to decide
  /// "decode-and-extract once per binary version" and to label `--list`.
  final String buildHash;

  /// Builds a manifest over the given maps; each is copied unmodifiable.
  BundleManifest({
    required Map<String, String> prompts,
    required Map<String, String> scripts,
    required Map<String, String> sqliteVec,
    required this.buildHash,
  })  : prompts = Map<String, String>.unmodifiable(prompts),
        scripts = Map<String, String>.unmodifiable(scripts),
        sqliteVec = Map<String, String>.unmodifiable(sqliteVec);

  /// The empty default: no prompts, no scripts, no native libraries, no hash.
  ///
  /// `brain_bundle.g.dart` links against this until `tom_brain bundle`
  /// overwrites it, so an un-bundled checkout always compiles.
  static final BundleManifest empty = BundleManifest(
    prompts: const <String, String>{},
    scripts: const <String, String>{},
    sqliteVec: const <String, String>{},
    buildHash: '',
  );

  /// `true` when no assets are bundled (the [empty] shape).
  bool get isEmpty =>
      prompts.isEmpty && scripts.isEmpty && sqliteVec.isEmpty;

  /// Sorted bundled prompt template paths.
  List<String> get promptIds => (prompts.keys.toList())..sort();

  /// Sorted bundled procedure locators.
  List<String> get scriptIds => (scripts.keys.toList())..sort();

  /// Sorted baked native platform tuples.
  List<String> get nativePlatforms => (sqliteVec.keys.toList())..sort();

  /// Decodes the base64 native library for [platformTuple], or `null` when the
  /// tuple is not baked into this bundle.
  Uint8List? nativeBytes(String platformTuple) {
    final encoded = sqliteVec[platformTuple];
    if (encoded == null) return null;
    return base64.decode(encoded);
  }

  /// Total *decoded* size of all baked native libraries, in bytes.
  ///
  /// This is the figure the size-budget test asserts against (AOT stores the
  /// decoded bytes, not the base64 source), so a single-platform manifest sits
  /// in the documented ~125–283 KB band and `--all-platforms` near ~895 KB.
  int get decodedNativeSizeBytes {
    var total = 0;
    for (final encoded in sqliteVec.values) {
      total += base64.decode(encoded).length;
    }
    return total;
  }
}
