// session_configuration_plan.md step 1 — config schema + example YAML for the
// Profile selection axis (the third leg alongside session and memory).
//
// Step 1 is declarative only: it lands the JSON-schema constraints (editor
// validation) and the worked example; it adds NO runtime consumer. The typed
// ProfileRegistry / loader is a later session_configuration plan step. So this
// suite proves the two things step 1 actually delivers:
//
//   1. The brain_run JSON schema constrains the top-level `profiles:` block:
//      a map keyed by profile id whose values are closed profile objects
//      covering every field of spec § 3.1 — `mode` (enum), `entryProcedure`,
//      `role`, `anchored`, `templateOverlay`, `mcpServers`, `defineMcpServers`,
//      `budget` (ProfileBudget), `rateLimits` (ProfileRateLimits),
//      `defaultSession`, `defaultMemory`.
//
//   2. The shipped worked example `example/profiles.example.yaml` (spec § 3.8:
//      default / research / quick / relay) validates against that sub-schema.
//
// As with `profile_config_schema_test.dart` (the memory/session-profile step-1
// suite), no `json_schema` validator is on the classpath, so a small
// self-contained recursive conformance helper checks exactly the draft-07
// features these blocks use (`type`, `enum`, `required`,
// `additionalProperties: false`, nested `properties`, array `items`) — not the
// whole of JSON Schema.

import 'dart:convert';
import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;
import 'package:test/test.dart';

/// Walks up from the test CWD to locate
/// `<workspace>/.tom/json-schema/tom_brain/brain_run.schema.json` (mirrors the
/// memory/session-profile suite's `_findBrainRunSchema`).
String? _findBrainRunSchema() {
  var dir = Directory.current.absolute;
  final rel = '.tom${Platform.pathSeparator}json-schema'
      '${Platform.pathSeparator}tom_brain'
      '${Platform.pathSeparator}brain_run.schema.json';
  for (var i = 0; i < 10; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$rel');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Locates the shipped `profiles.example.yaml` snippet. Tries the package-root
/// relative path first (how `dart test` / `testkit` run), then walks up looking
/// for the `tom_brain_run/example/` copy.
String? _findProfilesExample() {
  final direct = File('example${Platform.pathSeparator}profiles.example.yaml');
  if (direct.existsSync()) return direct.absolute.path;
  var dir = Directory.current.absolute;
  final rel = 'tom_brain_run${Platform.pathSeparator}example'
      '${Platform.pathSeparator}profiles.example.yaml';
  for (var i = 0; i < 10; i++) {
    final candidate = File('${dir.path}${Platform.pathSeparator}$rel');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Recursively validates [value] against the draft-07 (sub-)schema [schema],
/// returning the list of violations (empty ⇒ conforms). Covers exactly the
/// features the `profiles:` block uses: `type` (string or list of strings),
/// `enum`, `required`, `additionalProperties: false`, nested object
/// `properties`, and array `items`. Intentionally minimal.
List<String> _violations(
  Map<String, Object?> schema,
  Object? value,
  String path,
) {
  final violations = <String>[];

  final typeSpec = schema['type'];
  final allowedTypes = typeSpec is List
      ? typeSpec.cast<String>()
      : <String>[if (typeSpec is String) typeSpec];
  if (allowedTypes.isNotEmpty && !_typeMatches(allowedTypes, value)) {
    violations.add('$path: type ${value.runtimeType} not in $allowedTypes');
    return violations; // a wrong base type makes deeper checks meaningless
  }

  final enumSpec = schema['enum'];
  if (enumSpec is List && !enumSpec.contains(value)) {
    violations.add('$path: value "$value" not in enum $enumSpec');
  }

  if (value is Map) {
    final map = value.cast<String, Object?>();
    final props =
        (schema['properties'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final required =
        (schema['required'] as List?)?.cast<String>() ?? const <String>[];
    final additional = schema['additionalProperties'];

    for (final key in required) {
      if (!map.containsKey(key)) {
        violations.add('$path: missing required "$key"');
      }
    }
    if (additional == false) {
      for (final key in map.keys) {
        if (!props.containsKey(key)) {
          violations.add('$path: unknown key "$key"');
        }
      }
    }
    for (final entry in map.entries) {
      final spec = props[entry.key];
      if (spec is Map) {
        violations.addAll(_violations(
          spec.cast<String, Object?>(),
          entry.value,
          '$path.${entry.key}',
        ));
      } else if (additional is Map) {
        violations.addAll(_violations(
          additional.cast<String, Object?>(),
          entry.value,
          '$path.${entry.key}',
        ));
      }
    }
  } else if (value is List) {
    final items = schema['items'];
    if (items is Map) {
      final itemSchema = items.cast<String, Object?>();
      for (var i = 0; i < value.length; i++) {
        violations.addAll(_violations(itemSchema, value[i], '$path[$i]'));
      }
    }
  }

  return violations;
}

bool _typeMatches(List<String> allowed, Object? v) {
  for (final t in allowed) {
    switch (t) {
      case 'string':
        if (v is String) return true;
      case 'integer':
        if (v is int) return true;
      case 'number':
        if (v is num) return true;
      case 'boolean':
        if (v is bool) return true;
      case 'object':
        if (v is Map) return true;
      case 'array':
        if (v is List) return true;
      case 'null':
        if (v == null) return true;
    }
  }
  return false;
}

Map<String, Object?> _loadSchema(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

/// The `profiles.additionalProperties` sub-schema — one profile's item schema.
Map<String, Object?> _profileItemSchema(Map<String, Object?> schema) {
  final profiles =
      (schema['properties'] as Map)['profiles'] as Map<String, Object?>;
  return (profiles['additionalProperties'] as Map).cast<String, Object?>();
}

void main() {
  final schemaPath = _findBrainRunSchema();

  group('Profile-axis config schema (session_configuration plan step 1)', () {
    test('the brain_run schema is locatable and the profiles: block is a '
        'keyed map of closed profile objects', () {
      expect(schemaPath, isNotNull,
          reason: 'brain_run.schema.json not found by walking up from CWD');
      final schema = _loadSchema(schemaPath!);
      final profiles =
          (schema['properties'] as Map)['profiles'] as Map<String, Object?>;
      expect(profiles['type'], 'object');
      final item = _profileItemSchema(schema);
      expect(item['type'], 'object');
      expect(item['additionalProperties'], isFalse,
          reason: 'a profile object is closed — typos are rejected');
    });

    test('the profile item schema covers every field of spec § 3.1', () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      final props = (item['properties'] as Map).cast<String, Object?>();
      expect(
        props.keys,
        containsAll(<String>[
          'mode',
          'entryProcedure',
          'role',
          'anchored',
          'templateOverlay',
          'mcpServers',
          'defineMcpServers',
          'budget',
          'rateLimits',
          'defaultSession',
          'defaultMemory',
        ]),
      );
      // `mode` is the closed cognitive/answer/passthrough/retrieval enum
      // (§ 3.2; SC-Q4 added the zero-LLM `retrieval` diagnostic mode).
      final mode = (props['mode'] as Map).cast<String, Object?>();
      expect(mode['enum'],
          containsAll(<String>['cognitive', 'answer', 'passthrough', 'retrieval']));
      // budget / rateLimits are closed nested objects with their § 3.1 fields.
      final budget = (props['budget'] as Map).cast<String, Object?>();
      expect(budget['additionalProperties'], isFalse);
      expect(
        (budget['properties'] as Map).keys,
        containsAll(<String>[
          'maxLlmCalls',
          'maxToolCalls',
          'maxTokens',
          'wallClockSeconds',
        ]),
      );
      final rateLimits = (props['rateLimits'] as Map).cast<String, Object?>();
      expect(rateLimits['additionalProperties'], isFalse);
      expect(
        (rateLimits['properties'] as Map).keys,
        containsAll(<String>['requestsPerMinute', 'concurrentRuns']),
      );
    });

    test('defineMcpServers items are the canonical McpServerConfig shape '
        '(reconciled to the loader, SCP-16)', () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      final define = ((item['properties'] as Map)['defineMcpServers'] as Map)
          .cast<String, Object?>();
      expect(define['type'], 'array');
      final mcpItem = (define['items'] as Map).cast<String, Object?>();
      // Closed object: the loader is the strict authority — `id`/`transport`
      // are required, unknown keys (and the dropped § 3.8 `name` alias /
      // array-command friendly form) are rejected (SCP-16, hard principle 1).
      expect(mcpItem['additionalProperties'], isFalse);
      expect(
        (mcpItem['required'] as List).cast<String>(),
        containsAll(<String>['id', 'transport']),
      );
      expect(
        (mcpItem['properties'] as Map).keys,
        containsAll(<String>[
          'id',
          'transport',
          'description',
          'command',
          'args',
          'url',
          'headers',
          'exposeToLlms',
        ]),
      );
      expect((mcpItem['properties'] as Map).containsKey('name'), isFalse,
          reason: 'the § 3.8 `name` alias was reconciled away (SCP-16)');
      // The canonical worked item conforms.
      expect(
        _violations(mcpItem, <String, Object?>{
          'id': 'docs',
          'transport': 'stdio',
          'command': 'mcp-docs',
          'args': <String>['--root', './corpus'],
          'exposeToLlms': true,
        }, 'docs'),
        isEmpty,
      );
      // The retired friendly form (name alias, no transport) is now rejected.
      final bad = _violations(mcpItem, <String, Object?>{
        'name': 'docs',
        'command': <String>['mcp-docs', '--root', './corpus'],
        'exposeToLlms': true,
      }, 'docs');
      expect(bad, isNotEmpty);
      expect(bad.any((e) => e.contains('unknown key "name"')), isTrue);
      expect(bad.any((e) => e.contains('missing required "id"')), isTrue);
    });
  });

  group('the shipped profiles.example.yaml validates against the schema', () {
    final examplePath = _findProfilesExample();

    test('example file is locatable and parses to the four § 3.8 profiles', () {
      expect(examplePath, isNotNull,
          reason: 'profiles.example.yaml not found near tom_brain_run/example');
      final doc = loadYamlAsMap(File(examplePath!).readAsStringSync());
      final profiles = (doc['profiles'] as Map).cast<String, Object?>();
      expect(profiles.keys,
          containsAll(<String>['default', 'research', 'quick', 'relay']));
    });

    test('every profile in the example conforms to the profile item schema',
        () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      final doc = loadYamlAsMap(File(examplePath!).readAsStringSync());
      final profiles = (doc['profiles'] as Map).cast<String, Object?>();
      for (final entry in profiles.entries) {
        expect(
          _violations(item, entry.value, 'profiles.${entry.key}'),
          isEmpty,
          reason: 'profile "${entry.key}" must validate against the schema',
        );
      }
    });
  });

  group('the profile item schema rejects malformed profiles', () {
    test('an unknown profile field is rejected (closed object)', () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      expect(
        _violations(item, <String, Object?>{'moed': 'cognitive'}, 'p'),
        contains('p: unknown key "moed"'),
      );
    });

    test('an out-of-enum mode is rejected', () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      final v = _violations(item, <String, Object?>{'mode': 'turbo'}, 'p');
      expect(v.any((e) => e.contains('not in enum')), isTrue);
    });

    test('an unknown budget knob is rejected (closed nested object)', () {
      final item = _profileItemSchema(_loadSchema(schemaPath!));
      expect(
        _violations(item, <String, Object?>{
          'budget': <String, Object?>{'maxLllmCalls': 5},
        }, 'p'),
        contains('p.budget: unknown key "maxLllmCalls"'),
      );
    });
  });
}
