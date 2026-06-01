// C.42 — EngineConfig YAML loader acceptance suite.
//
// Pins the four engine knobs the loader owns (spec § 13): the
// `scripts/system/` + `scripts/user/` paths, the sandbox switches, and
// the hard per-step deadline. Covers defaults, a full document, the
// section-by-section optionality, the string→object→string round-trip,
// `loadFromFile` (present + absent), and the malformed-input rejections
// funnelled through `EngineConfigInvalid`.

import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

void main() {
  group('C.42-1 defaults', () {
    test('const EngineConfig() is the all-defaults configuration', () {
      final config = EngineConfig();
      expect(config.systemScriptsPath, 'scripts/system');
      expect(config.userScriptsPath, isNull);
      expect(config.sandbox, const SandboxConfig.locked());
      expect(config.stepDeadline, const Duration(seconds: 60));
    });

    test('an empty document yields the all-defaults configuration', () {
      expect(EngineConfig.fromYamlString(''), EngineConfig());
      expect(EngineConfig.fromYamlString('   \n  \n'), EngineConfig());
    });

    test('a non-positive stepDeadline is rejected at construction', () {
      expect(
        () => EngineConfig(stepDeadline: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => EngineConfig(stepDeadline: const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('C.42-2 full document', () {
    test('every section parses into the matching field', () {
      const yaml = '''
scripts:
  system: scripts/system
  user: scripts/user
sandbox:
  enableUnixCommands: true
  enableVsCodeIntegration: true
deadline:
  stepMs: 30000
''';
      final config = EngineConfig.fromYamlString(yaml);
      expect(config.systemScriptsPath, 'scripts/system');
      expect(config.userScriptsPath, 'scripts/user');
      expect(config.sandbox.enableUnixCommands, isTrue);
      expect(config.sandbox.enableVsCodeIntegration, isTrue);
      expect(config.stepDeadline, const Duration(milliseconds: 30000));
    });

    test('a custom absolute system path overrides the default', () {
      final config = EngineConfig.fromYamlString(
        'scripts:\n  system: /opt/brain/system\n',
      );
      expect(config.systemScriptsPath, '/opt/brain/system');
      expect(config.userScriptsPath, isNull);
    });
  });

  group('C.42-3 section optionality', () {
    test('an omitted scripts section keeps the default system path', () {
      final config = EngineConfig.fromYamlString('deadline:\n  stepMs: 1000\n');
      expect(config.systemScriptsPath, 'scripts/system');
      expect(config.userScriptsPath, isNull);
      expect(config.stepDeadline, const Duration(milliseconds: 1000));
    });

    test('an omitted sandbox section is the locked default', () {
      final config = EngineConfig.fromYamlString('scripts:\n  user: u\n');
      expect(config.sandbox, const SandboxConfig.locked());
      expect(config.userScriptsPath, 'u');
    });

    test('a partial sandbox section defaults the missing switch', () {
      final config = EngineConfig.fromYamlString(
        'sandbox:\n  enableUnixCommands: true\n',
      );
      expect(config.sandbox.enableUnixCommands, isTrue);
      expect(config.sandbox.enableVsCodeIntegration, isFalse);
    });

    test('an omitted deadline section keeps the 60 s default', () {
      final config = EngineConfig.fromYamlString('scripts:\n  user: u\n');
      expect(config.stepDeadline, const Duration(seconds: 60));
    });
  });

  group('C.42-4 round-trip (string → object → string)', () {
    test('the all-defaults config round-trips', () {
      final config = EngineConfig();
      final reparsed = EngineConfig.fromYamlString(config.toYamlString());
      expect(reparsed, config);
    });

    test('a fully-populated config round-trips', () {
      final config = EngineConfig(
        systemScriptsPath: 'a/system',
        userScriptsPath: 'a/user',
        sandbox: const SandboxConfig(
          enableUnixCommands: true,
          enableVsCodeIntegration: false,
        ),
        stepDeadline: const Duration(milliseconds: 12345),
      );
      final reparsed = EngineConfig.fromYamlString(config.toYamlString());
      expect(reparsed, config);
    });

    test('a path needing quoting round-trips intact', () {
      final config = EngineConfig(systemScriptsPath: 'weird: path #1');
      final reparsed = EngineConfig.fromYamlString(config.toYamlString());
      expect(reparsed.systemScriptsPath, 'weird: path #1');
      expect(reparsed, config);
    });

    test('toYamlString omits the user line when userScriptsPath is null', () {
      expect(EngineConfig().toYamlString(), isNot(contains('user:')));
    });
  });

  group('C.42-5 loadFromFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('engine_config_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('reads and parses an existing config file', () async {
      final file = File('${tempDir.path}/engine.yaml');
      await file.writeAsString(
        'scripts:\n  system: s\n  user: u\ndeadline:\n  stepMs: 5000\n',
      );
      final config = await EngineConfig.loadFromFile(file);
      expect(config.systemScriptsPath, 's');
      expect(config.userScriptsPath, 'u');
      expect(config.stepDeadline, const Duration(milliseconds: 5000));
    });

    test('a non-existent config file yields the all-defaults config', () async {
      final file = File('${tempDir.path}/absent.yaml');
      expect(await EngineConfig.loadFromFile(file), EngineConfig());
    });
  });

  group('C.42-6 malformed-input rejection', () {
    test('a top-level non-mapping document is rejected', () {
      expect(
        () => EngineConfig.fromYamlString('- just\n- a\n- list\n'),
        throwsA(isA<EngineConfigInvalid>()),
      );
    });

    test('invalid YAML is rejected as EngineConfigInvalid', () {
      expect(
        () => EngineConfig.fromYamlString('scripts: : :\n'),
        throwsA(isA<EngineConfigInvalid>()),
      );
    });

    test('a non-mapping scripts section is rejected with the path', () {
      expect(
        () => EngineConfig.fromYamlString('scripts: notamap\n'),
        throwsA(
          isA<EngineConfigInvalid>()
              .having((e) => e.path, 'path', 'scripts'),
        ),
      );
    });

    test('an empty system path is rejected', () {
      expect(
        () => EngineConfig.fromYamlString('scripts:\n  system: "  "\n'),
        throwsA(
          isA<EngineConfigInvalid>()
              .having((e) => e.path, 'path', 'scripts.system'),
        ),
      );
    });

    test('a non-boolean sandbox switch is rejected with the path', () {
      expect(
        () => EngineConfig.fromYamlString(
          'sandbox:\n  enableUnixCommands: yes-please\n',
        ),
        throwsA(
          isA<EngineConfigInvalid>().having(
            (e) => e.path,
            'path',
            'sandbox.enableUnixCommands',
          ),
        ),
      );
    });

    test('a non-integer deadline is rejected with the path', () {
      expect(
        () => EngineConfig.fromYamlString('deadline:\n  stepMs: soon\n'),
        throwsA(
          isA<EngineConfigInvalid>()
              .having((e) => e.path, 'path', 'deadline.stepMs'),
        ),
      );
    });

    test('a non-positive deadline is rejected with the path', () {
      expect(
        () => EngineConfig.fromYamlString('deadline:\n  stepMs: 0\n'),
        throwsA(
          isA<EngineConfigInvalid>()
              .having((e) => e.path, 'path', 'deadline.stepMs'),
        ),
      );
    });

    test('EngineConfigInvalid.toString carries the failure class + path', () {
      const error = EngineConfigInvalid('boom', path: 'deadline.stepMs');
      expect(error.toString(), contains('engine.config.invalid:'));
      expect(error.toString(), contains('deadline.stepMs'));
    });
  });
}
