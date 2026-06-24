// r8_tom_brain_cli_test.dart — the unified `tom_brain` CLI binary (CLI plan
// step #8; `tom_brain_cli.md` § 5).
//
// One `tom_build_base`-based executable with subcommands `serve` / `memory-mcp`
// / `observatory` / `init` / `bundle`, uniform `--help` / `--version`. The
// global + `serve` flags of § 5.2–5.3 resolve through the same `${env:…}`
// expander (step 7) and the `--home`/agent convention (step 6); `serve`
// co-hosts brain + memory-MCP + Observatory in ONE process by default, split by
// `--no-memory-mcp` / `--no-observatory`.
//
// These tests cover the four plan-mandated areas:
//   1. subcommand dispatch  — the tool registers the five commands, the factory
//      returns an executor per command, and `normalizeSubcommand` promotes a
//      leading bare subcommand token to its `:`-prefixed form (the
//      tom_build_base parser only treats `:`-prefixed tokens as commands).
//   2. flag→config wiring   — `assembleServeConfig` turns `--config` + `--home`
//      + env-expanded channel/path/`--set` overrides into a `BrainRunConfig`
//      plus `ServeRuntimeOptions`.
//   3. one-process serve smoke — `runBrainServe` drives an injected `ServeBoot`
//      and honours the co-host defaults / `--no-*` flips.
//   4. help/version          — driven through a `ToolRunner` test output sink.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:test/test.dart';

/// A valid inline `substrate:` block (oMLX LLM + Ollama embeddings); inline
/// providers mean the convention does NOT need a `providers/` directory.
const String _substrateInline = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - gemma-4-26b-a4b-it-4bit
    - id: ollama
      kind: ollama
      baseUrl: http://10.8.0.9:11434
      models:
        - nomic-embed-text
  roleRoutes:
    analyser:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    assistant_to_user:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

/// A minimal valid `access:` block carrying the mandatory OpenAI edge.
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

/// A `memory:` block with an explicit root (for the single-file path).
const String _memoryRooted = '''
memory:
  root: /tmp/r8-brain-mem
  sqliteVec:
    binariesRoot: /opt/vec''';

/// A `memory:` block WITHOUT a root — the convention fills it (home mode).
const String _memorySqliteOnly = '''
memory:
  sqliteVec:
    binariesRoot: /opt/vec''';

/// A complete single-file config (no `--home` convention needed).
const String _singleFileConfig = '$_substrateInline\n$_memoryRooted\n$_accessInline\n';

/// A thin config that leans on the `--home` convention for writable paths.
const String _homeLeaningConfig = '$_substrateInline\n$_memorySqliteOnly\n$_accessInline\n';

/// A complete `BrainRunConfig` for the serve smoke (the fake boot ignores its
/// contents; it only needs to be a valid instance to pass through).
BrainRunConfig _sampleConfig() => BrainRunConfigLoader.parse(_singleFileConfig);

/// A fake serve session that reports its co-host state from the [runtime] it
/// was booted with, so the smoke test can assert the defaults / flips.
class _FakeSession implements BrainServeSession {
  _FakeSession(this.runtime);
  final ServeRuntimeOptions runtime;
  @override
  int get openAiPort => 9999;
  @override
  bool get telegramEnabled => false;
  @override
  String? get memoryMcpUrl =>
      runtime.memoryMcpEnabled ? 'http://127.0.0.1:1/' : null;
  @override
  String? get observatoryUrl =>
      runtime.observatoryEnabled ? 'http://127.0.0.1:2/' : null;
  @override
  Future<int> get completed async => 0;
  @override
  Future<void> stop() async {}
}

void main() {
  group('#8 subcommand dispatch', () {
    test('tomBrainTool registers the five subcommands + serve default', () {
      final names = tomBrainTool.commands.map((c) => c.name).toSet();
      expect(names,
          {'serve', 'memory-mcp', 'observatory', 'init', 'bundle'});
      expect(tomBrainTool.defaultCommand, 'serve');
      expect(tomBrainTool.mode, ToolMode.multiCommand);
    });

    test('tomBrainCommandNames mirrors the registered command set', () {
      expect(tomBrainCommandNames,
          {'serve', 'memory-mcp', 'observatory', 'init', 'bundle'});
    });

    test('createTomBrainExecutors returns one executor per command', () {
      final execs = createTomBrainExecutors(rawArgs: const [], env: const {});
      expect(execs.keys.toSet(),
          {'serve', 'memory-mcp', 'observatory', 'init', 'bundle'});
    });

    test('normalizeSubcommand promotes a leading bare subcommand to :form', () {
      expect(normalizeSubcommand(['serve', '--home', '/x']),
          [':serve', '--home', '/x']);
      expect(normalizeSubcommand(['memory-mcp']), [':memory-mcp']);
      expect(normalizeSubcommand(['bundle', '--out', 'b.g.dart']),
          [':bundle', '--out', 'b.g.dart']);
    });

    test('normalizeSubcommand leaves empty / flags / help / :form untouched',
        () {
      expect(normalizeSubcommand([]), <String>[]);
      expect(normalizeSubcommand(['--help']), ['--help']);
      expect(normalizeSubcommand(['--version']), ['--version']);
      expect(normalizeSubcommand([':serve', '--home', '/x']),
          [':serve', '--home', '/x']);
      // A non-command leading token (e.g. a stray positional) is untouched.
      expect(normalizeSubcommand(['wibble']), ['wibble']);
    });
  });

  group('#8 flag→config wiring (assembleServeConfig)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('r8_tom_brain_cli_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String writeConfig(String body) {
      final path = '${tmp.path}/brain.yaml';
      File(path).writeAsStringSync(body);
      return path;
    }

    test('single-file mode parses the file unchanged + applies serve defaults',
        () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath],
        env: const {},
      );
      expect(asm.config.access.openAiPort, 8080);
      expect(asm.config.memory.root, '/tmp/r8-brain-mem');
      expect(asm.runConfigPath, cfgPath);
      // Co-host defaults: both the memory MCP server and the Observatory on.
      expect(asm.runtime.observatoryEnabled, isTrue);
      expect(asm.runtime.memoryMcpEnabled, isTrue);
    });

    test('--openai overrides the file port; --set overrides a scalar', () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--openai=9091', '--set',
            'memory.root=/srv/over'],
        env: const {},
      );
      expect(asm.config.access.openAiPort, 9091);
      expect(asm.config.memory.root, '/srv/over');
    });

    test('a bare --openai keeps the default OpenAI port', () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--openai'],
        env: const {},
      );
      expect(asm.config.access.openAiPort, defaultServeOpenAiPort);
    });

    test('--telegram-token expands \${env:…} from the environment', () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--telegram', '--telegram-token',
            r'${env:TG}'],
        env: const {'TG': 'super-secret'},
      );
      expect(asm.config.access.hasTelegram, isTrue);
      expect(asm.config.access.telegramBotToken, 'super-secret');
    });

    test('--home turns on the convention; the file still wins where set', () {
      final cfgPath = writeConfig(_homeLeaningConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--home', tmp.path],
        env: const {},
      );
      // The convention fills the unset memory root under <home>/agent.
      expect(asm.config.memory.root, '${tmp.path}/agent/memory');
      // The on-disk run-config path is the supplied --config file.
      expect(asm.runConfigPath, cfgPath);
    });

    test('--no-observatory / --no-memory-mcp flip the co-host runtime', () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--no-observatory', '--no-memory-mcp'],
        env: const {},
      );
      expect(asm.runtime.observatoryEnabled, isFalse);
      expect(asm.runtime.memoryMcpEnabled, isFalse);
    });

    test('--observatory-port / --observatory-host / --memory-mcp pin ports', () {
      final cfgPath = writeConfig(_singleFileConfig);
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--observatory-port=9000',
            '--observatory-host=0.0.0.0', '--memory-mcp=9100'],
        env: const {},
      );
      expect(asm.runtime.observatoryPort, 9000);
      expect(asm.runtime.observatoryHost, '0.0.0.0');
      expect(asm.runtime.memoryMcpPort, 9100);
    });

    test('--mcp sources external MCP servers from a directory (CLP-41 lifted)',
        () {
      final cfgPath = writeConfig(_homeLeaningConfig);
      final mcpDir = '${tmp.path}/external_mcp';
      Directory(mcpDir).createSync(recursive: true);
      File('$mcpDir/s.yaml').writeAsStringSync('''
mcpServers:
  - id: flagged
    transport: http
    url: http://localhost:9500
''');
      final asm = assembleServeConfig(
        [':serve', '--config', cfgPath, '--home', tmp.path, '--mcp', mcpDir],
        env: const {},
      );
      expect(
        asm.config.mcpServers.servers.map((s) => s.id),
        <String>['flagged'],
      );
    });

    test('an unknown flag is a clear startup error', () {
      final cfgPath = writeConfig(_singleFileConfig);
      expect(
        () => assembleServeConfig(
          [':serve', '--config', cfgPath, '--wat'],
          env: const {},
        ),
        throwsA(isA<ServeConfigException>()),
      );
    });
  });

  group('#8 one-process serve smoke (runBrainServe)', () {
    test('drives the injected boot and returns its exit code', () async {
      ServeRuntimeOptions? seen;
      Future<BrainServeSession> fakeBoot(
        BrainRunConfig config,
        ServeRuntimeOptions runtime, {
        required String runConfigPath,
        required ServeNarrate narrate,
      }) async {
        seen = runtime;
        return _FakeSession(runtime);
      }

      final code = await runBrainServe(
        _sampleConfig(),
        const ServeRuntimeOptions(),
        runConfigPath: '/x/brain.yaml',
        boot: fakeBoot,
        narrate: (_) {},
      );
      expect(code, 0);
      // Co-host defaults reach the boot seam.
      expect(seen!.observatoryEnabled, isTrue);
      expect(seen!.memoryMcpEnabled, isTrue);
    });

    test('honours --no-* flips down to the boot seam', () async {
      ServeRuntimeOptions? seen;
      Future<BrainServeSession> fakeBoot(
        BrainRunConfig config,
        ServeRuntimeOptions runtime, {
        required String runConfigPath,
        required ServeNarrate narrate,
      }) async {
        seen = runtime;
        return _FakeSession(runtime);
      }

      await runBrainServe(
        _sampleConfig(),
        const ServeRuntimeOptions(
          observatoryEnabled: false,
          memoryMcpEnabled: false,
        ),
        runConfigPath: '/x/brain.yaml',
        boot: fakeBoot,
        narrate: (_) {},
      );
      expect(seen!.observatoryEnabled, isFalse);
      expect(seen!.memoryMcpEnabled, isFalse);
    });
  });

  group('#8 help / version', () {
    test('--version writes the tom_brain version banner', () async {
      final buf = StringBuffer();
      final runner = ToolRunner(
        tool: tomBrainTool,
        executors: createTomBrainExecutors(rawArgs: const [], env: const {}),
        output: buf,
      );
      await runner.run(['--version']);
      expect(buf.toString(), contains(tomBrainVersion));
    });

    test('--help lists the serve subcommand', () async {
      final buf = StringBuffer();
      final runner = ToolRunner(
        tool: tomBrainTool,
        executors: createTomBrainExecutors(rawArgs: const [], env: const {}),
        output: buf,
      );
      await runner.run(['--help']);
      expect(buf.toString(), contains('serve'));
    });
  });
}
