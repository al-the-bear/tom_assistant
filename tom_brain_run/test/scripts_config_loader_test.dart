// Step 3 (tom_brain_cli_plan.md) — the `scripts:` section of the whole-process
// config.
//
// The standalone `tom_brain` CLI resolves its `scripts/system/` procedures
// from a configured disk directory (`<agent>/scripts/system/`) rather than a
// package-relative path. This step lands the typed `ScriptsConfig`, its pure
// `ScriptsConfigLoader`, and the wiring through `BrainRunConfigLoader` so the
// run assembly can thread the directory into `standUpBrainProcessFromConfig`.
//
// Contract under test (mirrors the sibling `tools:` / `trail:` loaders):
//
//   * No `scripts:` block            → returns `null` (the boot path keeps its
//     package-relative fallback — CLP decision).
//   * A `scripts:` block present     → `systemDir` is required; `userDir` is
//     optional.
//   * `${env:NAME}` tokens in either directory are expanded.
//   * An unknown key, a missing `systemDir`, or a non-map block surfaces a
//     located `ScriptsConfigException`.
//   * The whole-process loader threads the section onto `BrainRunConfig.scripts`.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// Minimal sibling sections so `BrainRunConfigLoader.parse` can assemble a
/// whole `BrainRunConfig` in the wiring test (mirrors `trail_config_test.dart`).
const String _substrateSection = '''
substrate:
  providers:
    - id: stub
      kind: stub
  roleRoutes:
    analyser:
      - {providerId: stub, model: x}
    assistant_to_user:
      - {providerId: stub, model: x}
  embedding:
    providerId: stub
    model: x
    dims: 1''';

const String _memorySection = '''
memory:
  root: "/var/tmp/brain-mem"
  sqliteVec:
    binariesRoot: "/var/tmp/sqlite-vec"''';

const String _accessSection = '''
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

void main() {
  group('A · ScriptsConfigLoader.parse (pure)', () {
    test('absent scripts: block → null', () {
      expect(ScriptsConfigLoader.parse(_memorySection), isNull);
    });

    test('systemDir only → userDir is null', () {
      final ScriptsConfig? scripts =
          ScriptsConfigLoader.parse('scripts:\n  systemDir: /agent/scripts/system');
      expect(scripts, isNotNull);
      expect(scripts!.systemDir.path, equals('/agent/scripts/system'));
      expect(scripts.userDir, isNull);
    });

    test('systemDir + userDir → both directories', () {
      final ScriptsConfig? scripts = ScriptsConfigLoader.parse('''
scripts:
  systemDir: /agent/scripts/system
  userDir: /agent/scripts/user''');
      expect(scripts, isNotNull);
      expect(scripts!.systemDir.path, equals('/agent/scripts/system'));
      expect(scripts.userDir, isNotNull);
      expect(scripts.userDir!.path, equals('/agent/scripts/user'));
    });

    test('\${env:NAME} in directories is expanded', () {
      final ScriptsConfig? scripts = ScriptsConfigLoader.parse(
        'scripts:\n  systemDir: \${env:AGENT}/scripts/system',
        envVars: const {'AGENT': '/srv/agent'},
      );
      expect(scripts, isNotNull);
      expect(scripts!.systemDir.path, equals('/srv/agent/scripts/system'));
    });

    test('present block missing systemDir → located error', () {
      expect(
        () => ScriptsConfigLoader.parse('scripts:\n  userDir: /agent/scripts/user'),
        throwsA(
          isA<ScriptsConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('scripts.systemDir'),
          ),
        ),
      );
    });

    test('unknown key under scripts: → located error', () {
      expect(
        () => ScriptsConfigLoader.parse(
            'scripts:\n  systemDir: /a/s\n  bogus: 1'),
        throwsA(
          isA<ScriptsConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('bogus'),
          ),
        ),
      );
    });

    test('non-map scripts: block → located error', () {
      expect(
        () => ScriptsConfigLoader.parse('scripts: a-string'),
        throwsA(isA<ScriptsConfigException>()),
      );
    });
  });

  group('B · whole-process wiring', () {
    test('an absent scripts: block leaves BrainRunConfig.scripts null', () {
      final BrainRunConfig cfg = BrainRunConfigLoader.parse(
        '$_substrateSection\n$_memorySection\n$_accessSection',
      );
      expect(cfg.scripts, isNull);
    });

    test('a present scripts: block is threaded onto BrainRunConfig.scripts', () {
      const String scriptsSection = '''
scripts:
  systemDir: /agent/scripts/system
  userDir: /agent/scripts/user''';
      final BrainRunConfig cfg = BrainRunConfigLoader.parse(
        '$_substrateSection\n$_memorySection\n$_accessSection\n$scriptsSection',
      );
      expect(cfg.scripts, isNotNull);
      expect(cfg.scripts!.systemDir.path, equals('/agent/scripts/system'));
      expect(cfg.scripts!.userDir!.path, equals('/agent/scripts/user'));
    });
  });
}
