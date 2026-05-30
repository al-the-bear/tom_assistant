// A.23 folder-layout contract test.
//
// Locks the twelve `lib/src/<folder>/` subfolders required by Plan
// step A.23 and the per-folder barrel file convention used across the
// Tom Brain projects (sibling: `tom_brain_shared`).
//
// What this test asserts:
//
//   1. Each of the twelve subfolders exists under `lib/src/`.
//   2. Each subfolder contains a `<folder>.dart` barrel file.
//   3. The top-level barrel `lib/tom_brain_memory.dart` re-exports
//      every one of those subfolder barrels (one `export` line per
//      subfolder).
//   4. The stale A.21 placeholder `lib/src/.gitkeep` is gone.
//
// What this test does NOT assert:
//
//   - Public symbols inside the barrels. At A.23 every subfolder
//     barrel is intentionally empty; symbols land in A.24+.
//   - File contents beyond the import-graph shape. Doc-comment text
//     is reviewed by humans, not by this test.
//
// Locating the package root: the test runs with the project root as
// the working directory (Dart's standard `dart test` behaviour), so
// `lib/src/<folder>` resolves directly.

import 'dart:io';

import 'package:test/test.dart';

const _requiredSubfolders = <String>[
  // Per Plan step A.23 — order matters only as documentation; the test
  // checks the set, not the order.
  'api',
  'classification',
  'config',
  'edges',
  'isolate_adapter',
  'mcp_server',
  'migrations',
  'nodes',
  'retrieval',
  'stacks',
  'store',
  'trails',
];

void main() {
  group('A.23 folder layout', () {
    test('there are exactly twelve required subfolders', () {
      // Sanity-check the list itself against the Plan A.23 inventory
      // so that a stray edit to `_requiredSubfolders` cannot silently
      // shrink the contract.
      expect(_requiredSubfolders, hasLength(12));
      expect(_requiredSubfolders.toSet(), hasLength(12),
          reason: 'subfolder list must be free of duplicates');
    });

    for (final folder in _requiredSubfolders) {
      test('lib/src/$folder/ exists', () {
        final dir = Directory('lib/src/$folder');
        expect(dir.existsSync(), isTrue,
            reason: 'expected lib/src/$folder/ to exist');
      });

      test('lib/src/$folder/$folder.dart exists', () {
        final file = File('lib/src/$folder/$folder.dart');
        expect(file.existsSync(), isTrue,
            reason: 'expected per-folder barrel '
                'lib/src/$folder/$folder.dart to exist');
      });
    }

    test('top-level barrel re-exports every subfolder barrel', () {
      final topLevel = File('lib/tom_brain_memory.dart').readAsStringSync();
      for (final folder in _requiredSubfolders) {
        final expected = "export 'src/$folder/$folder.dart';";
        expect(topLevel, contains(expected),
            reason: 'lib/tom_brain_memory.dart must re-export '
                "src/$folder/$folder.dart");
      }
    });

    test('stale A.21 placeholder lib/src/.gitkeep is gone', () {
      // Real subfolders make the placeholder redundant. If anyone
      // re-introduces it the layout has regressed.
      final placeholder = File('lib/src/.gitkeep');
      expect(placeholder.existsSync(), isFalse,
          reason: 'lib/src/.gitkeep was A.21\'s placeholder and must be '
              'removed once A.23 lands the real subfolders');
    });

    test('no unexpected subfolders are present under lib/src/', () {
      // Catches the inverse mistake: a half-finished refactor that
      // leaves a stray folder under `lib/src/`. New folders must
      // appear in `_requiredSubfolders` first, which forces the
      // change to be reviewed against Plan step A.23.
      final srcRoot = Directory('lib/src');
      final actual = srcRoot
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toSet();
      expect(actual, equals(_requiredSubfolders.toSet()),
          reason: 'lib/src/ folder set must match the A.23 inventory');
    });
  });
}
