// memory_session_profiles_plan.md step 1 — config schema + example YAML for the
// memory/session-profile blocks (`access.apiKeys[]`, `access.telegram.chats[]`).
//
// Step 1 is declarative only: it lands the JSON-schema constraints (editor
// validation) and the example documentation; it adds NO runtime consumer. The
// typed loader parsing of these blocks is plan step 3. So this suite proves the
// two things step 1 actually delivers:
//
//   1. The brain_run JSON schema constrains `access.apiKeys[]` and
//      `access.telegram.chats[]` with the documented item contracts (required
//      key / chatId, closed item property sets). A small self-contained
//      conformance helper validates example-shaped blocks against the schema's
//      item definitions (no `json_schema` validator is on the classpath, so we
//      check the item contract directly rather than pulling a new dependency).
//
//   2. The whole-process loader still accepts a config that OMITS the new blocks
//      — "absent is legal". (The "present is legal" leg at the loader belongs to
//      step 3, when AccessConfigLoader learns these keys; until then the example
//      ships them commented, because the loader's unknown-key gate (AC-12)
//      rejects them.)

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// Locates `<workspace>/.tom/json-schema/tom_brain/brain_run.schema.json` by
/// walking up from the test's CWD (mirrors r31's `_findSqliteVecRoot`).
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

/// Validates [value] against a draft-07 *object item* sub-schema [itemSchema]
/// that uses only the features these two blocks rely on: `required`,
/// `additionalProperties: false`, and per-property `type`. Returns the list of
/// violations (empty ⇒ conforms). Intentionally minimal — it covers exactly the
/// constraints step 1 pins, not the whole of JSON Schema.
List<String> _itemViolations(
  Map<String, Object?> itemSchema,
  Map<String, Object?> value,
) {
  final violations = <String>[];
  final props = (itemSchema['properties'] as Map?)?.cast<String, Object?>() ??
      const <String, Object?>{};
  final required =
      (itemSchema['required'] as List?)?.cast<String>() ?? const <String>[];
  final additional = itemSchema['additionalProperties'];

  for (final key in required) {
    if (!value.containsKey(key)) violations.add('missing required "$key"');
  }
  if (additional == false) {
    for (final key in value.keys) {
      if (!props.containsKey(key)) violations.add('unknown key "$key"');
    }
  }
  for (final entry in value.entries) {
    final spec = props[entry.key];
    if (spec is! Map) continue;
    final typeSpec = spec['type'];
    final allowed = typeSpec is List
        ? typeSpec.cast<String>()
        : <String>[if (typeSpec is String) typeSpec];
    if (allowed.isEmpty) continue;
    if (!_typeMatches(allowed, entry.value)) {
      violations.add('"${entry.key}" type ${entry.value.runtimeType} '
          'not in $allowed');
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
    }
  }
  return false;
}

void main() {
  group('memory/session-profile config schema (plan step 1)', () {
    final schemaPath = _findBrainRunSchema();

    test('the brain_run schema file is locatable and well-formed JSON', () {
      expect(schemaPath, isNotNull,
          reason: 'brain_run.schema.json not found by walking up from CWD');
      final decoded =
          jsonDecode(File(schemaPath!).readAsStringSync()) as Map<String, Object?>;
      expect(decoded[r'$schema'], contains('json-schema.org'));
    });

    test('access.apiKeys[] is constrained: array of closed items requiring key',
        () {
      final schema =
          jsonDecode(File(schemaPath!).readAsStringSync()) as Map<String, Object?>;
      final apiKeys = (((schema['properties'] as Map)['access'] as Map)
          ['properties'] as Map)['apiKeys'] as Map<String, Object?>;
      expect(apiKeys['type'], 'array');
      final item = apiKeys['items'] as Map<String, Object?>;
      expect(item['additionalProperties'], isFalse);
      expect(item['required'], contains('key'));
      final props = (item['properties'] as Map).cast<String, Object?>();
      expect(
        props.keys,
        containsAll(<String>[
          'key',
          'principal',
          'sessionPrefix',
          'memoryPrefix',
          'displayName',
        ]),
      );
    });

    test('access.telegram.chats[] is constrained: array of closed items '
        'requiring chatId', () {
      final schema =
          jsonDecode(File(schemaPath!).readAsStringSync()) as Map<String, Object?>;
      final telegram = (((schema['properties'] as Map)['access'] as Map)
          ['properties'] as Map)['telegram'] as Map<String, Object?>;
      // telegram stays permissive (botToken is owned by AccessConfigLoader);
      // only the chats[] block is pinned.
      expect(telegram['additionalProperties'], isTrue);
      final chats =
          (telegram['properties'] as Map)['chats'] as Map<String, Object?>;
      expect(chats['type'], 'array');
      final item = chats['items'] as Map<String, Object?>;
      expect(item['additionalProperties'], isFalse);
      expect(item['required'], contains('chatId'));
      final props = (item['properties'] as Map).cast<String, Object?>();
      expect(
        props.keys,
        containsAll(<String>[
          'chatId',
          'principal',
          'sessionPrefix',
          'memoryPrefix',
          'defaultSession',
          'defaultMemory',
        ]),
      );
    });

    test('example-shaped apiKeys entries (real key + no-key) conform; an entry '
        'with an unknown key or no key is rejected', () {
      final schema =
          jsonDecode(File(schemaPath!).readAsStringSync()) as Map<String, Object?>;
      final item = ((((schema['properties'] as Map)['access'] as Map)
                  ['properties'] as Map)['apiKeys']
              as Map)['items'] as Map<String, Object?>;

      // The two example shapes (§ 5.1 / § 6) both conform.
      expect(
        _itemViolations(item, <String, Object?>{
          'key': 'sk-acme',
          'principal': 'owner',
          'sessionPrefix': 'acme_',
          'memoryPrefix': 'acme_',
          'displayName': 'ACME bot',
        }),
        isEmpty,
      );
      expect(
        _itemViolations(item, <String, Object?>{
          'key': 'no-key',
          'sessionPrefix': 'defaultsession_',
          'memoryPrefix': 'defaultmemory_',
        }),
        isEmpty,
      );

      // A typo'd key name and a missing `key` are both caught by the schema.
      expect(
        _itemViolations(item, <String, Object?>{
          'key': 'sk-x',
          'sesionPrefix': 'oops_',
        }),
        contains('unknown key "sesionPrefix"'),
      );
      expect(
        _itemViolations(item, <String, Object?>{'sessionPrefix': 'p_'}),
        contains('missing required "key"'),
      );
    });

    test('example-shaped telegram.chats entry conforms; chatId may be a string '
        'or an integer; a missing chatId is rejected', () {
      final schema =
          jsonDecode(File(schemaPath!).readAsStringSync()) as Map<String, Object?>;
      final item = (((((schema['properties'] as Map)['access'] as Map)
                  ['properties'] as Map)['telegram']
              as Map)['properties'] as Map)['chats'] as Map;
      final itemSchema = (item['items'] as Map).cast<String, Object?>();

      expect(
        _itemViolations(itemSchema, <String, Object?>{
          'chatId': '12345',
          'principal': 'owner',
          'sessionPrefix': 'tg_owner_',
          'memoryPrefix': 'tg_owner_',
          'defaultSession': 'default',
          'defaultMemory': 'default',
        }),
        isEmpty,
      );
      expect(
        _itemViolations(itemSchema, <String, Object?>{'chatId': 12345}),
        isEmpty,
      );
      expect(
        _itemViolations(itemSchema, <String, Object?>{'principal': 'owner'}),
        contains('missing required "chatId"'),
      );
    });
  });

  group('whole-process loader still accepts configs omitting the new blocks',
      () {
    // A minimal valid whole-process doc with NO apiKeys / telegram.chats blocks
    // — proves "absent is legal" (the loader is unchanged by step 1).
    const String doc = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - m
  roleRoutes:
    assistant_to_user:
      - providerId: omlx
        model: m
  embedding:
    providerId: omlx
    model: m
    dims: 768
    normalize: true
memory:
  root: /tmp/x
  sqliteVec:
    binariesRoot: /opt/vec
access:
  openai:
    port: 8080
    basePath: /v1
  telegram:
    botToken: tg-token
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - run-token
  rateLimit:
    capacity: 1000
    refillTokens: 1000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000
''';

    test('parses to a BrainRunConfig with the existing access fields populated',
        () {
      final BrainRunConfig config = BrainRunConfigLoader.parse(doc);
      expect(config.access.openAiPort, 8080);
      expect(config.access.telegramBotToken, 'tg-token');
      expect(config.access.users.map((u) => u.id), contains('owner'));
    });
  });
}
