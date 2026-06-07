// Folder-layout contract test (C.8 engine layout + D.6 dispatcher half).
//
// Locks the `lib/src/<folder>/` subfolder inventory: the nine engine
// subfolders required by Plan step C.8, the `dispatcher/` subfolder added
// by Plan step D.6 (the first dispatcher-half addition to this project),
// the `budget/` subfolder (Q-C.51.1), and the `prompts/` subfolder added
// by Extension F step 1 (the placeholder system). It also locks the
// per-folder barrel-file convention used
// across the Tom Brain projects (siblings: `tom_brain_shared`,
// `tom_brain_memory`, `tom_brain_substrate`) and the top-level barrel
// re-export.
//
// What this test asserts:
//
//   1. Each of the twelve subfolders exists under `lib/src/`.
//   2. Each subfolder contains a `<folder>.dart` barrel file.
//   3. The top-level barrel `lib/tom_brain_procedure_prototype.dart`
//      re-exports every one of those subfolder barrels (one `export`
//      line per subfolder).
//   4. The stale C.6 placeholder `lib/src/.gitkeep` is gone.
//   5. No unexpected subfolders are present under `lib/src/`.
//
// What this test does NOT assert:
//
//   - Public symbols inside the barrels. At C.8 every subfolder barrel
//     is intentionally empty; symbols land in C.11+.
//   - File contents beyond the import-graph shape. Doc-comment text is
//     reviewed by humans, not by this test.
//
// Locating the package root: the test runs with the project root as
// the working directory (Dart's standard `dart test` behaviour), so
// `lib/src/<folder>` resolves directly.

import 'dart:io';

import 'package:test/test.dart';

const _requiredSubfolders = <String>[
  // Per Plan steps C.8 (engine half) + D.6 (dispatcher half) — order
  // matters only as documentation; the test checks the set, not the
  // order. Subsequent plan steps may extend the inventory (and must
  // update this list, which forces review).
  'api', // C.38–C.41 — ProcedureEngine surface
  'bridges', // C.11–C.15 — MemoryBridge / SubstrateBridge
  'budget', // Q-C.51.1 — BudgetLedger + procedure.budget.exceeded (PE-8)
  'config', // C.42–C.45 — EngineConfig + observability
  'd4rt_host', // C.16–C.18 — D4rtDcliHost
  'dispatcher', // D.6–D.50 — Dispatcher.accept + coordinator + fallback
  'preemption', // C.34–C.37 — PreemptionState + deadline
  'primitives_native', // C.19–C.22 — runProcedure / note / yield
  'procedure_store', // C.23–C.26 — store + loader + resolver
  'prompts', // Ext-F step 1 — PlaceholderResolver / Stack (§ 21.5, § 21.7)
  'recorder', // C.31–C.33 — RunRecorder + effort accounting
  'validator', // C.27–C.30 — header / sandbox / contract validators
];

void main() {
  group('folder layout (C.8 engine + D.6 dispatcher)', () {
    test('subfolder inventory matches the expected size and is unique', () {
      // Sanity-check the list itself so that a stray edit to
      // `_requiredSubfolders` cannot silently shrink or duplicate the
      // contract. C.8 seeds 9; D.6 adds `dispatcher/` for 10; Q-C.51.1 adds
      // `budget/` for 11; Ext-F step 1 adds `prompts/` for 12.
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
      final topLevel =
          File('lib/tom_brain_procedure_prototype.dart').readAsStringSync();
      for (final folder in _requiredSubfolders) {
        final expected = "export 'src/$folder/$folder.dart';";
        expect(topLevel, contains(expected),
            reason: 'lib/tom_brain_procedure_prototype.dart must re-export '
                "src/$folder/$folder.dart");
      }
    });

    test('stale C.6 placeholder lib/src/.gitkeep is gone', () {
      // Real subfolders make the placeholder redundant. If anyone
      // re-introduces it the layout has regressed.
      final placeholder = File('lib/src/.gitkeep');
      expect(placeholder.existsSync(), isFalse,
          reason: 'lib/src/.gitkeep was C.6\'s placeholder and must be '
              'removed once C.8 lands the real subfolders');
    });

    test('no unexpected subfolders are present under lib/src/', () {
      // Catches the inverse mistake: a half-finished refactor that
      // leaves a stray folder under `lib/src/`. New folders must appear
      // in `_requiredSubfolders` first, which forces the change to be
      // reviewed against Plan step C.8.
      final srcRoot = Directory('lib/src');
      final actual = srcRoot
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toSet();
      expect(actual, equals(_requiredSubfolders.toSet()),
          reason: 'lib/src/ folder set must match the C.8 inventory');
    });
  });
}
