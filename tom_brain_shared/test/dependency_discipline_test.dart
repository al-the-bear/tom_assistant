// Dependency-discipline test for `tom_brain_shared` (Plan step A.9).
//
// Contract being enforced:
//
//   `tom_brain_shared` is the pure-types layer of Tom Brain. It is allowed
//   exactly two baseline runtime dependencies: `tom_basics` and
//   `tom_core_agentic` (generic, domain-free agentic building blocks the
//   shared-types layer builds on rather than re-implementing). Anything with
//   side effects (networking, storage, LLM, logging) belongs in a downstream
//   component (`tom_brain_memory`, `tom_brain_substrate`, ...), never here.
//
// This test parses `pubspec.yaml` and asserts:
//
//   1. The `dependencies` block exists and contains exactly the two allowed
//      keys.
//   2. Those keys are `tom_basics` and `tom_core_agentic`.
//   3. The `tom_basics` version constraint is a real constraint (not `any`).
//   4. None of an explicit forbid-list of side-effect packages appears in
//      `dependencies` (defensive — also fails (1) but the error message is
//      more useful when the offender is named).
//
// `dev_dependencies` is *not* policed: `lints`, `test`, and the `yaml`
// parser used by this very test live there and are scope-limited to
// development.

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('tom_brain_shared dependency discipline (A.9)', () {
    late YamlMap pubspec;

    setUpAll(() {
      final file = File('pubspec.yaml');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'pubspec.yaml must be readable from the package root '
            '(test cwd is the package root under `dart test`).',
      );
      final loaded = loadYaml(file.readAsStringSync());
      expect(
        loaded,
        isA<YamlMap>(),
        reason: 'pubspec.yaml must parse to a YAML map.',
      );
      pubspec = loaded as YamlMap;
    });

    test('runtime dependencies block exists and is a map', () {
      expect(pubspec.containsKey('dependencies'), isTrue);
      expect(pubspec['dependencies'], isA<YamlMap>());
    });

    test('exactly the two baseline runtime dependencies are declared', () {
      final deps = pubspec['dependencies'] as YamlMap;
      expect(
        deps.keys.cast<String>().toSet(),
        equals(<String>{'tom_basics', 'tom_core_agentic'}),
        reason:
            'tom_brain_shared must declare exactly its two baseline runtime '
            'dependencies (tom_basics, tom_core_agentic). '
            'Found: ${deps.keys.toList()}',
      );
    });

    test('tom_basics version is pinned (not "any")', () {
      final deps = pubspec['dependencies'] as YamlMap;
      final version = deps['tom_basics'];
      expect(
        version,
        isA<String>(),
        reason: 'tom_basics version must be a string constraint.',
      );
      expect(
        (version as String).trim().toLowerCase(),
        isNot(equals('any')),
        reason:
            'tom_basics must be pinned to a real version constraint; '
            '"any" is not permitted at the shared-types layer.',
      );
    });

    test('no side-effect packages appear in runtime dependencies', () {
      // Packages explicitly disallowed at the tom_brain_shared layer.
      // These belong in downstream components (memory, substrate, ...).
      const forbidden = <String>{
        'http',
        'dio',
        'sqlite3',
        'dart_mcp',
        'shelf',
        'shelf_router',
        'dart_jsonwebtoken',
        'path_provider',
        'file',
        'crypto',
        'logging',
        'logger',
        'sqflite',
        'drift',
      };
      final deps = pubspec['dependencies'] as YamlMap;
      final intersect = deps.keys.cast<String>().toSet().intersection(
        forbidden,
      );
      expect(
        intersect,
        isEmpty,
        reason:
            'tom_brain_shared must not declare side-effect packages. '
            'Forbidden packages found in dependencies: $intersect',
      );
    });
  });
}
