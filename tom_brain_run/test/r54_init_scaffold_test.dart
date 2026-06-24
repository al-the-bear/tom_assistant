// R54 — `tom_brain init <dir>` scaffolding (`tom_brain_cli.md` § 5.4; CLI plan
// step #11). `init` writes the `<dir>/agent/` convention skeleton — three
// `*.example.yaml` aspect templates (`providers` / `models` / `profiles`, the
// last carrying a `default` + one custom profile per `session_configuration.md`
// § 3.8) and an empty `mcp/` — and, when the binary carries a bundle, extracts
// the bundled prompts into `<agent>/prompts/` and scripts into
// `<agent>/scripts/` for editing (`--no-extract` skips). The native sqlite-vec
// library is NOT extracted here (it materialises lazily at first boot, § 4.2).
//
// Three layers under test:
//   * the pure [scaffoldAgentSkeleton] — skeleton written; extract vs
//     `--no-extract`; refuse to clobber a non-empty agent dir.
//   * the [InitCommandExecutor] driven through a real [ToolRunner] — the
//     `<dir>` positional, the `--no-extract` flag, and the injected bundle.
//   * an `init`'d dir BOOTS under `serve` — the scaffolded aspect files
//     assemble into a valid `BrainRunConfig` and flow through `runBrainServe`'s
//     boot seam.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:test/test.dart';

/// A populated bundle: two prompts (one nested under `roles/`) and one script,
/// keyed exactly as the codegen would (`_readPrompts` → cognition-root-relative
/// POSIX path; `_readScripts` → filename stem).
BundleManifest _populatedBundle() => BundleManifest(
      prompts: const <String, String>{
        'cognition.md': 'cognition registry body',
        'roles/analyser.persona.md': 'analyser persona prose',
      },
      scripts: const <String, String>{
        'answer_with_memory_v1': 'void main() {}',
      },
      sqliteVec: const <String, String>{},
      buildHash: 'sha256:test',
    );

/// A `memory:` block carrying only the sqlite-vec root — the `--home`
/// convention fills `memory.root`.
const String _memorySqliteOnly = '''
memory:
  sqliteVec:
    binariesRoot: /opt/vec''';

/// The mandatory `access:` block (the convention scaffolds no access aspect).
const String _accessInline = '''
access:
  openai:
    port: 8080
    basePath: /v1
  apiKeys:
    - key: run-token
      principal: owner
      displayName: Owner
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000''';

/// A fake serve session — the boot seam returns it without touching the config.
class _FakeSession implements BrainServeSession {
  @override
  int get openAiPort => 9999;
  @override
  bool get telegramEnabled => false;
  @override
  String? get memoryMcpUrl => null;
  @override
  String? get observatoryUrl => null;
  @override
  Future<int> get completed async => 0;
  @override
  Future<void> stop() async {}
}

String _sep(String base, String name) =>
    '$base${Platform.pathSeparator}$name';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r54_init_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('R54 — scaffoldAgentSkeleton (pure)', () {
    test('INIT-01: writes the three example templates + an empty mcp/', () {
      final result = scaffoldAgentSkeleton(
        home: tmp,
        bundle: BundleManifest.empty,
      );

      final agent = _sep(tmp.path, 'agent');
      expect(result.agentRoot, agent);
      expect(result.created,
          containsAll(<String>['providers.example.yaml', 'models.example.yaml',
              'profiles.example.yaml', 'mcp/']));

      expect(File(_sep(agent, 'providers.example.yaml')).existsSync(), isTrue);
      expect(File(_sep(agent, 'models.example.yaml')).existsSync(), isTrue);
      expect(Directory(_sep(agent, 'mcp')).existsSync(), isTrue);

      // The profiles template carries a `default` + one custom profile (§ 3.8).
      final profiles = File(_sep(agent, 'profiles.example.yaml'))
          .readAsStringSync();
      expect(profiles, contains('default:'));
      expect(profiles, contains('research:'));
      expect(profiles, contains('mode: cognitive'));

      // An empty bundle extracts nothing: no prompts/scripts trees.
      expect(result.extracted, isFalse);
      expect(Directory(_sep(agent, 'prompts')).existsSync(), isFalse);
      expect(Directory(_sep(agent, 'scripts')).existsSync(), isFalse);
    });

    test('INIT-02: extracts bundled prompts/scripts onto disk', () {
      final result = scaffoldAgentSkeleton(
        home: tmp,
        bundle: _populatedBundle(),
      );

      final agent = _sep(tmp.path, 'agent');
      expect(result.extracted, isTrue);
      expect(result.extractedPrompts, 2);
      expect(result.extractedScripts, 1);

      // Prompts keep their cognition-root-relative path; nested dirs created.
      expect(File(_sep(_sep(agent, 'prompts'), 'cognition.md'))
          .readAsStringSync(), 'cognition registry body');
      expect(
          File('${_sep(agent, 'prompts')}${Platform.pathSeparator}'
                  'roles${Platform.pathSeparator}analyser.persona.md')
              .readAsStringSync(),
          'analyser persona prose');

      // Scripts get the `.dart` extension reattached to the bundle locator.
      expect(
          File('${_sep(agent, 'scripts')}${Platform.pathSeparator}'
                  'answer_with_memory_v1.dart')
              .readAsStringSync(),
          'void main() {}');
    });

    test('INIT-03: --no-extract leaves the project running off the bundle', () {
      final result = scaffoldAgentSkeleton(
        home: tmp,
        bundle: _populatedBundle(),
        extract: false,
      );

      final agent = _sep(tmp.path, 'agent');
      expect(result.extracted, isFalse);
      expect(Directory(_sep(agent, 'prompts')).existsSync(), isFalse);
      expect(Directory(_sep(agent, 'scripts')).existsSync(), isFalse);
      // The example templates are still written.
      expect(File(_sep(agent, 'providers.example.yaml')).existsSync(), isTrue);
    });

    test('INIT-04: refuses to clobber a non-empty agent directory', () {
      Directory(_sep(tmp.path, 'agent')).createSync(recursive: true);
      File(_sep(_sep(tmp.path, 'agent'), 'keep.yaml'))
          .writeAsStringSync('mine');

      expect(
        () => scaffoldAgentSkeleton(home: tmp, bundle: BundleManifest.empty),
        throwsA(isA<InitScaffoldException>()),
      );
    });
  });

  group('R54 — InitCommandExecutor (via ToolRunner)', () {
    test('INIT-05: `init <dir>` extracts; `--no-extract` skips', () async {
      final extractDir = _sep(tmp.path, 'with_extract');
      final argv = normalizeSubcommand(['init', extractDir]);
      final runner = ToolRunner(
        tool: tomBrainTool,
        executors: createTomBrainExecutors(
          rawArgs: argv,
          env: const {},
          bundle: _populatedBundle(),
        ),
      );
      final result = await runner.run(argv);
      expect(result.success, isTrue);
      expect(
          File('${_sep(_sep(extractDir, 'agent'), 'scripts')}'
                  '${Platform.pathSeparator}answer_with_memory_v1.dart')
              .existsSync(),
          isTrue);

      final skipDir = _sep(tmp.path, 'no_extract');
      final skipArgv = normalizeSubcommand(['init', skipDir, '--no-extract']);
      final skipRunner = ToolRunner(
        tool: tomBrainTool,
        executors: createTomBrainExecutors(
          rawArgs: skipArgv,
          env: const {},
          bundle: _populatedBundle(),
        ),
      );
      expect((await skipRunner.run(skipArgv)).success, isTrue);
      expect(Directory(_sep(_sep(skipDir, 'agent'), 'scripts')).existsSync(),
          isFalse);
      expect(File(_sep(_sep(skipDir, 'agent'), 'profiles.example.yaml'))
          .existsSync(), isTrue);
    });

    test('INIT-06: a missing target directory argument is a clear error',
        () async {
      final argv = normalizeSubcommand(['init']);
      final runner = ToolRunner(
        tool: tomBrainTool,
        executors:
            createTomBrainExecutors(rawArgs: argv, env: const {}),
      );
      expect((await runner.run(argv)).success, isFalse);
    });
  });

  group('R54 — an init\'d dir boots under serve', () {
    test('INIT-07: the scaffolded aspects assemble + flow through the boot seam',
        () async {
      // Scaffold with extraction so prompts/scripts trees exist on disk.
      scaffoldAgentSkeleton(home: tmp, bundle: _populatedBundle());
      final agent = _sep(tmp.path, 'agent');

      // Promote the example templates into their aspect directories (the step
      // a user takes after `init`), so the `--home` convention sources them.
      Directory(_sep(agent, 'providers')).createSync();
      File(_sep(_sep(agent, 'providers'), 'local.yaml')).writeAsStringSync(
          File(_sep(agent, 'providers.example.yaml')).readAsStringSync());
      Directory(_sep(agent, 'models')).createSync();
      File(_sep(_sep(agent, 'models'), 'models.yaml')).writeAsStringSync(
          File(_sep(agent, 'models.example.yaml')).readAsStringSync());
      Directory(_sep(agent, 'profiles')).createSync();
      File(_sep(_sep(agent, 'profiles'), 'profiles.yaml')).writeAsStringSync(
          File(_sep(agent, 'profiles.example.yaml')).readAsStringSync());

      // The thin brain.yaml supplies the access edge + sqlite-vec root.
      final brainYaml = _sep(agent, 'brain.yaml');
      File(brainYaml).writeAsStringSync('$_memorySqliteOnly\n$_accessInline\n');

      // The scaffolded aspect files assemble into a valid config.
      final asm = assembleServeConfig(
        [':serve', '--config', brainYaml, '--home', tmp.path],
        env: const {},
      );
      expect(asm.config.substrate.providers.any((p) => p.id == 'local'),
          isTrue);
      expect(asm.config.profiles.contains('research'), isTrue);
      expect(asm.config.profiles.profile('research')!.role, 'researcher');

      // …and flows all the way through serve's boot seam.
      final code = await runBrainServe(
        asm.config,
        asm.runtime,
        runConfigPath: asm.runConfigPath,
        boot: (config, runtime, {required runConfigPath, required narrate}) async =>
            _FakeSession(),
        narrate: (_) {},
      );
      expect(code, 0);
    });
  });
}
