// r6_project_home_test.dart — the `--home`/`agent` resolver (CLI plan step #6;
// `tom_brain_cli.md` § 2 / § 6 / § 8).
//
// `ProjectHome` turns `--home` (default CWD) + `--agent-dir` (default
// `<home>/agent`) + per-aspect/per-path overrides into a fully-pathed
// `BrainRunConfig`. The convention defaults every brain directory under
// `<agent>/`; an explicit override beats the convention; the file-tool scopes
// default `writeScope: [<agent>/scratchpad]` / `readScope: [<home>]`; writable
// dirs are created on demand while config aspects stay un-created (a missing
// *required* aspect surfaces as the owning loader's boot error).
//
// These tests exercise the layers `ProjectHome` owns (convention vs flag) plus
// the `buildConfig` overlay that deep-merges the convention under the user's
// base config (the file layer wins over convention, § 9).

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfigException;
import 'package:test/test.dart';

/// A valid inline `substrate:` block (oMLX LLM + Ollama embeddings) — the
/// providers are inline, so the convention does NOT inject a `providersDir`.
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

/// The same substrate but WITHOUT an inline `providers:` block — only
/// `roleRoutes` + `embedding`. With no inline providers and no `providersDir`,
/// the convention injects `substrate.providersDir: <agent>/providers`, which
/// does not exist ⇒ a located directory-not-found boot error.
const String _substrateNoProviders = '''
substrate:
  roleRoutes:
    analyser:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

/// A minimal valid `access:` block.
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

/// A `memory:` block carrying only the required `sqliteVec` content (no
/// `root` — the convention fills it).
const String _memorySqliteOnly = '''
memory:
  sqliteVec:
    binariesRoot: /opt/vec''';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r6_project_home_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('#6 ProjectHome — convention path resolution', () {
    test('convention defaults land every brain dir under <home>/agent/', () {
      final home = ProjectHome(home: tmp.path);

      final agent = '${tmp.path}/agent';
      expect(home.agentRoot, agent);
      expect(home.memoryRoot, '$agent/memory');
      expect(home.trailRoot, '$agent/trail');
      expect(home.historyDir, '$agent/history');
      expect(home.edgeDir, '$agent/edge');
      expect(home.scratchpadDir, '$agent/scratchpad');
      expect(home.providersDir, '$agent/providers');
      expect(home.modelsDir, '$agent/models');
      expect(home.profilesDir, '$agent/profiles');
      expect(home.promptsDir, '$agent/prompts');
      expect(home.scriptsSystemDir, '$agent/scripts');
      expect(home.sqliteVecBinariesRoot, '$agent/bin/sqlite_vec');
    });

    test('--agent-dir relocates the agent root independently of --home', () {
      final relocated = '${tmp.path}/elsewhere/brain';
      final home = ProjectHome(home: tmp.path, agentDir: relocated);

      expect(home.agentRoot, relocated);
      expect(home.memoryRoot, '$relocated/memory');
      expect(home.trailRoot, '$relocated/trail');
      // --home still anchors the read scope (the host project).
      expect(home.readScope, <String>[tmp.path]);
    });

    test('a per-path override beats the convention; siblings stay convention',
        () {
      final home = ProjectHome(
        home: tmp.path,
        overrides: HomeOverrides(
          memoryRoot: '/srv/shared/memory',
          trailRoot: '/srv/shared/trail',
        ),
      );

      final agent = '${tmp.path}/agent';
      expect(home.memoryRoot, '/srv/shared/memory');
      expect(home.trailRoot, '/srv/shared/trail');
      // Untouched aspects keep the convention.
      expect(home.historyDir, '$agent/history');
      expect(home.edgeDir, '$agent/edge');

      // The resolution log records which layer won for each path.
      final mem = home.resolutionLog.firstWhere((r) => r.aspect == 'memory.root');
      expect(mem.layer, PathLayer.flag);
      expect(mem.value, '/srv/shared/memory');
      final hist =
          home.resolutionLog.firstWhere((r) => r.aspect == 'history.directory');
      expect(hist.layer, PathLayer.convention);
    });

    test('file-tool scopes default to scratchpad (write) + home (read)', () {
      final home = ProjectHome(home: tmp.path);
      expect(home.writeScope, <String>['${tmp.path}/agent/scratchpad']);
      expect(home.readScope, <String>[tmp.path]);
    });

    test('explicit --write-scope / --read-scope override the convention', () {
      final home = ProjectHome(
        home: tmp.path,
        overrides: HomeOverrides(
          writeScope: <String>['/work/out'],
          readScope: <String>['/work/in', '/work/ref'],
        ),
      );
      expect(home.writeScope, <String>['/work/out']);
      expect(home.readScope, <String>['/work/in', '/work/ref']);
    });
  });

  group('#6 ProjectHome — writable-dir creation', () {
    test('ensureWritableDirs creates writable dirs, leaves config aspects '
        'un-created', () {
      final home = ProjectHome(home: tmp.path);
      home.ensureWritableDirs();

      final agent = '${tmp.path}/agent';
      // Writable directories created on demand.
      expect(Directory('$agent/memory').existsSync(), isTrue);
      expect(Directory('$agent/trail').existsSync(), isTrue);
      expect(Directory('$agent/history').existsSync(), isTrue);
      expect(Directory('$agent/edge').existsSync(), isTrue);
      expect(Directory('$agent/scratchpad').existsSync(), isTrue);

      // Config aspects are NOT auto-created.
      expect(Directory('$agent/providers').existsSync(), isFalse);
      expect(Directory('$agent/models').existsSync(), isFalse);
      expect(Directory('$agent/prompts').existsSync(), isFalse);
      expect(Directory('$agent/scripts').existsSync(), isFalse);
      expect(Directory('$agent/profiles').existsSync(), isFalse);
    });
  });

  group('#6 ProjectHome — buildConfig', () {
    test('convention defaults flow into the built BrainRunConfig (inline '
        'substrate; unset paths filled under agent/)', () {
      final home = ProjectHome(home: tmp.path);
      final base = '$_substrateInline\n$_memorySqliteOnly\n$_accessInline\n';

      final cfg = home.buildConfig(base);

      final agent = '${tmp.path}/agent';
      expect(cfg.memory.root, '$agent/memory');
      expect(cfg.memory.sqliteVec.binariesRoot, '/opt/vec');
      expect(cfg.access.historyDirectory, '$agent/history');
      expect(cfg.access.edgeStateDirectory, '$agent/edge');
      expect(cfg.trail?.root, '$agent/trail');
      expect(cfg.cognition?.root, '$agent/prompts');
      expect(cfg.scripts?.systemDir.path, '$agent/scripts');
      expect(cfg.tools?.writeScope, <String>['$agent/scratchpad']);
      expect(cfg.tools?.readScope, <String>[tmp.path]);
      // Inline substrate is untouched by the convention.
      expect(cfg.substrate.providers.map((p) => p.id),
          containsAll(<String>['omlx', 'ollama']));
    });

    test('an explicit value in the base config beats the convention', () {
      final home = ProjectHome(home: tmp.path);
      final base = '$_substrateInline\n'
          'memory:\n'
          '  root: /srv/explicit/memory\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessInline\n';

      final cfg = home.buildConfig(base);

      // The file's explicit memory.root wins over the <agent>/memory default.
      expect(cfg.memory.root, '/srv/explicit/memory');
      // …while the unset trail root still falls to the convention.
      expect(cfg.trail?.root, '${tmp.path}/agent/trail');
    });

    test('a flag override beats an explicit value in the base config', () {
      final home = ProjectHome(
        home: tmp.path,
        overrides: HomeOverrides(memoryRoot: '/flag/memory'),
      );
      final base = '$_substrateInline\n'
          'memory:\n'
          '  root: /srv/explicit/memory\n'
          '  sqliteVec:\n'
          '    binariesRoot: /opt/vec\n'
          '$_accessInline\n';

      final cfg = home.buildConfig(base);

      expect(cfg.memory.root, '/flag/memory');
    });

    test('a missing required aspect (no inline providers, providers/ absent) '
        'is a located boot error', () {
      final home = ProjectHome(home: tmp.path);
      // No inline `providers:` ⇒ convention injects providersDir under
      // <agent>/providers, which does not exist.
      final base =
          '$_substrateNoProviders\n$_memorySqliteOnly\n$_accessInline\n';

      expect(
        () => home.buildConfig(base),
        throwsA(isA<SubstrateConfigException>()),
      );
    });
  });
}
