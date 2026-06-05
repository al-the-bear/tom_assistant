// Folder-layout contract test (E.8 access layout).
//
// Locks the `lib/src/<module>/` layout required by Plan step E.8 (extended
// by plan items #27 and #28): eleven leaf modules, four of them nested under
// a shared `adapters/` grouping directory. It also locks the per-folder
// barrel-file convention used
// across the Tom Brain projects (siblings: `tom_brain_shared`,
// `tom_brain_memory`, `tom_brain_substrate`, `tom_brain_procedure_prototype`)
// and the top-level barrel re-export.
//
// What this test asserts:
//
//   1. Each of the eleven leaf-module directories exists under `lib/src/`.
//   2. Each leaf module contains a `<leaf>.dart` barrel file.
//   3. The top-level barrel `lib/tom_brain_access_prototype.dart`
//      re-exports every one of those barrels (one `export` line each).
//   4. The stale E.6 placeholder `lib/src/.gitkeep` is gone.
//   5. No unexpected directories are present under `lib/src/` or under
//      `lib/src/adapters/`.
//
// What this test does NOT assert:
//
//   - Public symbols inside the barrels. At E.8 every barrel is
//     intentionally empty; symbols land in E.9+.
//   - File contents beyond the import-graph shape. Doc-comment text is
//     reviewed by humans, not by this test.
//
// Locating the package root: the test runs with the project root as the
// working directory (Dart's standard `dart test` behaviour), so
// `lib/src/<module>` resolves directly.

import 'dart:io';

import 'package:test/test.dart';

/// Leaf-module paths relative to `lib/src/`, per Plan step E.8. Four are
/// nested under the `adapters/` grouping directory. Order matters only as
/// documentation; the assertions check sets, not order. Subsequent plan
/// steps may extend the inventory (and must update this list, which forces
/// review against the plan).
const _leafModules = <String>[
  'adapters/openai_http_sse', // E.11–E.18 — OpenAI HTTP/SSE adapter
  'adapters/ollama', // #27 — Ollama HTTP adapter
  'adapters/anthropic', // #28 — Anthropic Messages HTTP adapter
  'adapters/telegram', // E.19–E.23 — Telegram adapter
  'identity', // E.24–E.27 — IdentityResolver / SessionManager / PersonaResolver
  'edge_security', // E.28–E.32 — auth / rate-limit / quota / anchor pre-check
  'heuristic_classifier', // E.33–E.35 — cheap kind-hint classifier + cache
  'delivery', // E.36–E.40 — DeliveryRegistry + SSE/Telegram delivery
  'boot', // E.41–E.45 — BrainAccessBoot + shutdown + healthz
  'config', // E.44 — process YAML config loader
  'api', // E.9+ / E.51–E.52 — public surface
];

/// Last path component of a leaf-module path (its barrel basename).
String _leafName(String module) => module.split('/').last;

/// Direct children of `lib/src/`: the leaf modules' first path segment.
Set<String> get _expectedTopLevelDirs =>
    _leafModules.map((m) => m.split('/').first).toSet();

/// Direct children of `lib/src/adapters/`: the leaf names of the nested
/// adapter modules.
Set<String> get _expectedAdapterDirs => _leafModules
    .where((m) => m.startsWith('adapters/'))
    .map(_leafName)
    .toSet();

void main() {
  group('folder layout (E.8 access modules)', () {
    test('leaf-module inventory matches the expected size and is unique', () {
      // Sanity-check the list itself so a stray edit cannot silently
      // shrink or duplicate the contract. E.8 declared nine leaf modules;
      // plan item #27 added the Ollama adapter for ten, and #28 the
      // Anthropic adapter for eleven.
      expect(_leafModules, hasLength(11));
      expect(_leafModules.toSet(), hasLength(11),
          reason: 'leaf-module list must be free of duplicates');
    });

    for (final module in _leafModules) {
      final leaf = _leafName(module);

      test('lib/src/$module/ exists', () {
        final dir = Directory('lib/src/$module');
        expect(dir.existsSync(), isTrue,
            reason: 'expected lib/src/$module/ to exist');
      });

      test('lib/src/$module/$leaf.dart exists', () {
        final file = File('lib/src/$module/$leaf.dart');
        expect(file.existsSync(), isTrue,
            reason: 'expected per-folder barrel '
                'lib/src/$module/$leaf.dart to exist');
      });
    }

    test('top-level barrel re-exports every leaf-module barrel', () {
      final topLevel =
          File('lib/tom_brain_access_prototype.dart').readAsStringSync();
      for (final module in _leafModules) {
        final leaf = _leafName(module);
        final expected = "export 'src/$module/$leaf.dart';";
        expect(topLevel, contains(expected),
            reason: 'lib/tom_brain_access_prototype.dart must re-export '
                "src/$module/$leaf.dart");
      }
    });

    test('stale E.6 placeholder lib/src/.gitkeep is gone', () {
      // Real subfolders make the placeholder redundant. If anyone
      // re-introduces it the layout has regressed.
      final placeholder = File('lib/src/.gitkeep');
      expect(placeholder.existsSync(), isFalse,
          reason: 'lib/src/.gitkeep was E.6\'s placeholder and must be '
              'removed once E.8 lands the real subfolders');
    });

    test('no unexpected directories are present under lib/src/', () {
      // Catches the inverse mistake: a half-finished refactor leaving a
      // stray folder under `lib/src/`. New folders must appear in
      // `_leafModules` first, which forces review against Plan step E.8.
      final actual = Directory('lib/src')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toSet();
      expect(actual, equals(_expectedTopLevelDirs),
          reason: 'lib/src/ folder set must match the E.8 inventory '
              '(top-level: ${_expectedTopLevelDirs.toList()..sort()})');
    });

    test('no unexpected directories are present under lib/src/adapters/', () {
      // The `adapters/` grouping holds exactly the four channel adapters.
      final actual = Directory('lib/src/adapters')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path.split(Platform.pathSeparator).last)
          .toSet();
      expect(actual, equals(_expectedAdapterDirs),
          reason: 'lib/src/adapters/ folder set must match the E.8 '
              'inventory (${_expectedAdapterDirs.toList()..sort()})');
    });
  });
}
