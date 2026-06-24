// Bundle listing — the `tom_brain bundle --list` rendering (`tom_brain_cli.md`
// § 4; CLI plan step 4).
//
// A pure function over a [BundleManifest] → the human-readable inventory the
// `--list` flag prints: the bundled prompt ids, the bundled procedure
// locators, the baked native platform tuples, and the build hash. Pure so the
// CLI subcommand (step 8) just prints what it returns and a test asserts the
// rendering directly.

import 'bundle_manifest.dart';

/// Renders the `--list` inventory of [manifest].
///
/// Lists prompt ids, script locators, native platform tuples (with the
/// decoded byte total), and the build hash. An empty bundle renders a single
/// "(empty)" line so the operator sees an un-bundled build clearly.
String renderBundleListing(BundleManifest manifest) {
  if (manifest.isEmpty) {
    return 'Bundle: (empty — run `tom_brain bundle` to populate)';
  }
  final b = StringBuffer()
    ..writeln('Bundle ${manifest.buildHash}')
    ..writeln('  prompts (${manifest.promptIds.length}):');
  for (final id in manifest.promptIds) {
    b.writeln('    - $id');
  }
  b.writeln('  scripts (${manifest.scriptIds.length}):');
  for (final id in manifest.scriptIds) {
    b.writeln('    - $id');
  }
  b.writeln('  native platforms (${manifest.nativePlatforms.length}, '
      '${manifest.decodedNativeSizeBytes} bytes):');
  for (final platform in manifest.nativePlatforms) {
    final bytes = manifest.nativeBytes(platform)?.length ?? 0;
    b.writeln('    - $platform ($bytes bytes)');
  }
  return b.toString().trimRight();
}
