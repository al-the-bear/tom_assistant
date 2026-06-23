// r49 — `appendApiKeyToRunConfig` (the run-layer durable half of
// `/create_api_key`, MSP-7 / § 13, MSPP-42…47).
//
// Proves the comment-preserving `yaml_edit` append of one `access.apiKeys[]`
// entry (key + sessionPrefix + memoryPrefix), across the three shapes the run
// config can be in (no `access:`, `access:` without `apiKeys:`, an existing
// `apiKeys:` list), that siblings/comments survive, that the entry round-trips
// as a proper map (the restart-recovery contract), and that any bad shape /
// missing file throws so the access-side §13 rollback fires.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart' show ApiKeyConfig;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

ApiKeyConfig _config({String key = 'abc-key'}) => ApiKeyConfig(
      key: key,
      sessionPrefix: '${key}_',
      memoryPrefix: '${key}_',
    );

/// Reads back the single appended entry from [file] as a plain map, the way a
/// restart's config loader would see it.
Map<Object?, Object?> _onlyEntry(File file) {
  final dynamic doc = loadYaml(file.readAsStringSync());
  final YamlList list = (doc['access'] as YamlMap)['apiKeys'] as YamlList;
  expect(list, hasLength(1));
  return Map<Object?, Object?>.from(list.first as YamlMap);
}

void main() {
  late Directory dir;
  late File file;

  setUp(() => dir = Directory.systemTemp.createTempSync('api_key_persist_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, String contents) =>
      File('${dir.path}/$name')..writeAsStringSync(contents);

  group('appendApiKeyToRunConfig', () {
    test('appends to an existing apiKeys list, preserving comments + siblings',
        () {
      file = write('run.yaml', '''
# head comment must survive.
access:
  bearerAuth: required # inline comment
  apiKeys:
    - key: existing-key
      sessionPrefix: existing_
      memoryPrefix: existing_
''');

      appendApiKeyToRunConfig(file, _config(key: 'new-key'));

      final dynamic doc = loadYaml(file.readAsStringSync());
      final YamlList list =
          (doc['access'] as YamlMap)['apiKeys'] as YamlList;
      expect(list, hasLength(2));
      expect((list.last as YamlMap)['key'], 'new-key');
      // Siblings + comments untouched.
      final String rewritten = file.readAsStringSync();
      expect(rewritten, contains('# head comment must survive.'));
      expect(rewritten, contains('# inline comment'));
      expect(rewritten, contains('bearerAuth: required'));
      expect(rewritten, contains('key: existing-key'));
    });

    test('creates the apiKeys list when access: exists but has none', () {
      file = write('run.yaml', '''
access:
  bearerAuth: required
''');

      appendApiKeyToRunConfig(file, _config(key: 'k1'));

      final Map<Object?, Object?> entry = _onlyEntry(file);
      expect(entry['key'], 'k1');
      expect(entry['sessionPrefix'], 'k1_');
      expect(entry['memoryPrefix'], 'k1_');
      // The pre-existing sibling under access: survives.
      expect(file.readAsStringSync(), contains('bearerAuth: required'));
    });

    test('creates the access: map when it is absent, keeping other top-level',
        () {
      file = write('run.yaml', '''
substrate:
  providers: []
''');

      appendApiKeyToRunConfig(file, _config(key: 'k2'));

      final Map<Object?, Object?> entry = _onlyEntry(file);
      expect(entry['key'], 'k2');
      expect(entry['sessionPrefix'], 'k2_');
      expect(entry['memoryPrefix'], 'k2_');
      // The unrelated top-level section survives.
      expect(file.readAsStringSync(), contains('substrate:'));
    });

    test('writes only key / sessionPrefix / memoryPrefix (no principal)', () {
      file = write('run.yaml', 'access:\n  apiKeys: []\n');
      appendApiKeyToRunConfig(file, _config(key: 'k3'));
      final Map<Object?, Object?> entry = _onlyEntry(file);
      expect(entry.keys.toSet(), {'key', 'sessionPrefix', 'memoryPrefix'});
    });

    test('throws when the file is missing (triggers the §13 rollback)', () {
      expect(
        () => appendApiKeyToRunConfig(
            File('${dir.path}/nope.yaml'), _config()),
        throwsA(isA<ApiKeyPersistException>()),
      );
    });

    test('throws when access: is not a map', () {
      file = write('run.yaml', 'access: not-a-map\n');
      expect(
        () => appendApiKeyToRunConfig(file, _config()),
        throwsA(isA<ApiKeyPersistException>()),
      );
    });

    test('throws when access.apiKeys is not a list', () {
      file = write('run.yaml', 'access:\n  apiKeys: not-a-list\n');
      expect(
        () => appendApiKeyToRunConfig(file, _config()),
        throwsA(isA<ApiKeyPersistException>()),
      );
    });

    test('the appended entry round-trips as a map (restart recovery)', () {
      file = write('run.yaml', 'access:\n  apiKeys: []\n');
      appendApiKeyToRunConfig(file, _config(key: 'durable'));

      // A "restart": a brand-new parse of the same file sees a clean entry.
      final Map<Object?, Object?> entry = _onlyEntry(file);
      expect(entry['key'], 'durable');
      expect(entry['sessionPrefix'], 'durable_');
      expect(entry['memoryPrefix'], 'durable_');
    });
  });
}
