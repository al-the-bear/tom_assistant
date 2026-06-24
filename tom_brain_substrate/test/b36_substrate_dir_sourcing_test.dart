// B.36 (split) — `SubstrateConfigLoader` directory-sourcing.
//
// CLI plan step 2 (tom_brain_cli_plan.md): the `substrate:` block may
// source `providers` from a `providersDir` and `roleRoutes`+`embedding`
// from a `modelsDir` instead of declaring them inline. This is the
// `<agent>/providers/` + `<agent>/models/` convention of the standalone
// `tom_brain` CLI.
//
// Contract under test:
//
//   * `providersDir` sources the providers list from every `*.yaml`
//     file under the directory (each file a top-level `providers:`
//     list, unioned in filename order).
//   * `modelsDir` sources `roleRoutes` (merged by role) and `embedding`
//     (declared exactly once) from the directory's `*.yaml` files.
//   * Inline still works unchanged (no directory keys).
//   * Setting both inline and a directory for the same aspect is a
//     clear config error.
//   * Relative directory paths resolve against the config file's
//     directory (threaded from `loadFromFile` / an explicit `basePath`).
//     A relative path with no base directory is an error.
//   * `${env:NAME}` expansion is preserved inside aspect files.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.36 substrate split — directory sourcing', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('substrate_split_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<File> writeConfig(String content) async {
      final f = File('${tmp.path}/substrate.yaml');
      await f.writeAsString(content);
      return f;
    }

    Future<void> writeAspect(String dir, String name, String content) async {
      final d = Directory('${tmp.path}/$dir');
      await d.create(recursive: true);
      await File('${d.path}/$name').writeAsString(content);
    }

    test('inline-only still parses unchanged (no directory keys)', () async {
      final cfg = SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    analyser:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
''');
      expect(cfg.providers.single.id, equals('s'));
      expect(cfg.roleRoutes.keys, equals(['analyser']));
      expect(cfg.embedding.dims, equals(1));
    });

    test('providersDir sources providers from the directory (file-relative)',
        () async {
      await writeAspect('providers', 'omlx.yaml', '''
providers:
  - id: omlx
    kind: openai
    baseUrl: http://10.8.0.7:8000/v1/
    models: [gemma]
''');
      await writeAspect('providers', 'ollama.yaml', '''
providers:
  - id: ollama
    kind: ollama
    baseUrl: http://localhost:11434
    models: [nomic-embed-text]
''');
      final file = await writeConfig('''
substrate:
  providersDir: providers
  roleRoutes:
    analyser:
      - {providerId: omlx, model: gemma}
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
''');
      final cfg = SubstrateConfigLoader.loadFromFile(file.path);
      expect(
        cfg.providers.map((p) => p.id).toList()..sort(),
        equals(['ollama', 'omlx']),
      );
      expect(cfg.embedding.providerId, equals('ollama'));
    });

    test('modelsDir sources roleRoutes + embedding from the directory',
        () async {
      await writeAspect('models', 'routes.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
  assistant_to_user:
    - {providerId: s, model: x}
''');
      await writeAspect('models', 'embedding.yaml', '''
embedding:
  providerId: s
  model: x
  dims: 1
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: s
      kind: stub
  modelsDir: models
''');
      final cfg = SubstrateConfigLoader.loadFromFile(file.path);
      expect(
        cfg.roleRoutes.keys.toList()..sort(),
        equals(['analyser', 'assistant_to_user']),
      );
      expect(cfg.embedding.model, equals('x'));
    });

    test('both providersDir and modelsDir together (full split)', () async {
      await writeAspect('providers', 'p.yaml', '''
providers:
  - id: s
    kind: stub
''');
      await writeAspect('models', 'm.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
embedding:
  providerId: s
  model: x
  dims: 1
''');
      final file = await writeConfig('''
substrate:
  providersDir: providers
  modelsDir: models
''');
      final cfg = SubstrateConfigLoader.loadFromFile(file.path);
      expect(cfg.providers.single.id, equals('s'));
      expect(cfg.roleRoutes.keys, equals(['analyser']));
      expect(cfg.embedding.dims, equals(1));
    });

    test('inline providers + providersDir is a both-set error', () async {
      await writeAspect('providers', 'p.yaml', '''
providers:
  - id: s
    kind: stub
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: t
      kind: stub
  providersDir: providers
  roleRoutes:
    analyser:
      - {providerId: t, model: x}
  embedding:
    providerId: t
    model: x
    dims: 1
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('providers'), contains('not both')),
          ),
        ),
      );
    });

    test('inline roleRoutes + modelsDir is a both-set error', () async {
      await writeAspect('models', 'm.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
embedding:
  providerId: s
  model: x
  dims: 1
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: s
      kind: stub
  modelsDir: models
  roleRoutes:
    analyser:
      - {providerId: s, model: x}
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('modelsDir'), contains('not both')),
          ),
        ),
      );
    });

    test('inline embedding + modelsDir is a both-set error', () async {
      await writeAspect('models', 'm.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
embedding:
  providerId: s
  model: x
  dims: 1
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: s
      kind: stub
  modelsDir: models
  embedding:
    providerId: s
    model: x
    dims: 1
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(isA<SubstrateConfigException>()),
      );
    });

    test('embedding declared in two model files is rejected', () async {
      await writeAspect('models', 'a.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
embedding:
  providerId: s
  model: x
  dims: 1
''');
      await writeAspect('models', 'b.yaml', '''
embedding:
  providerId: s
  model: x
  dims: 2
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: s
      kind: stub
  modelsDir: models
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('embedding'),
          ),
        ),
      );
    });

    test('same role declared in two model files is rejected', () async {
      await writeAspect('models', 'a.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: x}
embedding:
  providerId: s
  model: x
  dims: 1
''');
      await writeAspect('models', 'b.yaml', '''
roleRoutes:
  analyser:
    - {providerId: s, model: y}
''');
      final file = await writeConfig('''
substrate:
  providers:
    - id: s
      kind: stub
  modelsDir: models
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('analyser'),
          ),
        ),
      );
    });

    test('\${env:NAME} expansion is preserved inside aspect files', () async {
      await writeAspect('providers', 'omlx.yaml', '''
providers:
  - id: omlx
    kind: openai
    baseUrl: \${env:OMLX_URL}
    models: [gemma]
''');
      final file = await writeConfig('''
substrate:
  providersDir: providers
  roleRoutes:
    analyser:
      - {providerId: omlx, model: gemma}
  embedding:
    providerId: omlx
    model: gemma
    dims: 1
''');
      final cfg = SubstrateConfigLoader.loadFromFile(
        file.path,
        envVars: const {'OMLX_URL': 'http://gpu-host:8000/v1/'},
      );
      expect(
        cfg.providers.single.baseUrl,
        equals(Uri.parse('http://gpu-host:8000/v1/')),
      );
    });

    test('an absolute providersDir resolves without a base path', () async {
      await writeAspect('providers', 'p.yaml', '''
providers:
  - id: s
    kind: stub
''');
      final absDir = '${tmp.path}/providers';
      final cfg = SubstrateConfigLoader.parse('''
substrate:
  providersDir: $absDir
  roleRoutes:
    analyser:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
''');
      expect(cfg.providers.single.id, equals('s'));
    });

    test('a relative providersDir with no base path is an error', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providersDir: providers
  roleRoutes:
    analyser:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('providersDir'), contains('relative')),
          ),
        ),
      );
    });

    test('a missing aspect directory is a clear error', () async {
      final file = await writeConfig('''
substrate:
  providersDir: does_not_exist
  roleRoutes:
    analyser:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
''');
      expect(
        () => SubstrateConfigLoader.loadFromFile(file.path),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('providersDir'), contains('not found')),
          ),
        ),
      );
    });
  });
}
