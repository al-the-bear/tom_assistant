// D.47 — DispatcherConfig YAML loader acceptance suite.
//
// Pins the four dispatcher knobs the loader owns (spec § 13): the
// `scripts/system/` + `scripts/user/` paths, the foreground queue depth, the
// coordinator hard step deadline, and the free-time-scheduler enabled flag.
// Covers defaults, a full document, section-by-section optionality, the
// string→object→string round-trip, `loadFromFile` (present + absent), the
// malformed-input rejections funnelled through `DispatcherConfigInvalid`, and
// a drift guard tying the default hard step deadline to the engine + grace
// constants it mirrors.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  group('D.47-1 defaults', () {
    test('DispatcherConfig() is the all-defaults configuration', () {
      final config = DispatcherConfig();
      expect(config.systemScriptsPath, 'scripts/system');
      expect(config.userScriptsPath, isNull);
      expect(config.foregroundQueueDepth, 1000000);
      expect(config.hardStepDeadline, const Duration(hours: 24, seconds: 5));
      expect(config.schedulerEnabled, isFalse);
    });

    test('an empty/whitespace document yields the all-defaults config', () {
      expect(DispatcherConfig.fromYamlString(''), DispatcherConfig());
      expect(DispatcherConfig.fromYamlString('   \n  \n'), DispatcherConfig());
    });

    test('the named defaults match the constructor defaults', () {
      expect(defaultForegroundQueueDepth, 1000000);
      expect(
        defaultDispatcherHardStepDeadline,
        const Duration(hours: 24, seconds: 5),
      );
      expect(defaultSchedulerEnabled, isFalse);
    });

    test('default hard step deadline = step deadline + coordinator grace', () {
      // Drift guard: the const is hardcoded (the addition is not a const
      // expression), so this ties it to the two source constants it mirrors.
      expect(
        defaultDispatcherHardStepDeadline,
        defaultStepDeadline + defaultCoordinatorDeadlineGrace,
      );
    });
  });

  group('D.47-2 construction guards', () {
    test('a negative foregroundQueueDepth is rejected at construction', () {
      expect(
        () => DispatcherConfig(foregroundQueueDepth: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a zero foregroundQueueDepth is accepted (queueing disabled)', () {
      expect(DispatcherConfig(foregroundQueueDepth: 0).foregroundQueueDepth, 0);
    });

    test('a non-positive hardStepDeadline is rejected at construction', () {
      expect(
        () => DispatcherConfig(hardStepDeadline: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => DispatcherConfig(hardStepDeadline: const Duration(seconds: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('D.47-3 full document', () {
    test('parses every section', () {
      const yaml = '''
scripts:
  system: custom/system
  user: custom/user
queue:
  foregroundDepth: 8
deadline:
  hardStepMs: 90000
scheduler:
  enabled: true
''';
      final config = DispatcherConfig.fromYamlString(yaml);
      expect(config.systemScriptsPath, 'custom/system');
      expect(config.userScriptsPath, 'custom/user');
      expect(config.foregroundQueueDepth, 8);
      expect(config.hardStepDeadline, const Duration(milliseconds: 90000));
      expect(config.schedulerEnabled, isTrue);
    });
  });

  group('D.47-4 section optionality', () {
    test('omitting scripts.user yields a null user path', () {
      final config = DispatcherConfig.fromYamlString('scripts:\n  system: a/b');
      expect(config.systemScriptsPath, 'a/b');
      expect(config.userScriptsPath, isNull);
    });

    test('omitting the queue section uses the default depth', () {
      final config =
          DispatcherConfig.fromYamlString('scheduler:\n  enabled: true');
      expect(config.foregroundQueueDepth, 1000000);
      expect(config.schedulerEnabled, isTrue);
    });

    test('omitting the deadline section uses the default deadline', () {
      final config = DispatcherConfig.fromYamlString('queue:\n  foregroundDepth: 2');
      expect(config.hardStepDeadline, const Duration(hours: 24, seconds: 5));
      expect(config.foregroundQueueDepth, 2);
    });

    test('omitting the scheduler section leaves it disabled', () {
      final config = DispatcherConfig.fromYamlString('queue:\n  foregroundDepth: 1');
      expect(config.schedulerEnabled, isFalse);
    });

    test('a present-but-null field falls back to the default', () {
      const yaml = '''
queue:
  foregroundDepth:
scheduler:
  enabled:
''';
      final config = DispatcherConfig.fromYamlString(yaml);
      expect(config.foregroundQueueDepth, 1000000);
      expect(config.schedulerEnabled, isFalse);
    });
  });

  group('D.47-5 round-trip', () {
    test('toYamlString → fromYamlString is identity (all defaults)', () {
      final original = DispatcherConfig();
      expect(DispatcherConfig.fromYamlString(original.toYamlString()), original);
    });

    test('toYamlString → fromYamlString is identity (full config)', () {
      final original = DispatcherConfig(
        systemScriptsPath: 'sys/path',
        userScriptsPath: 'usr/path',
        foregroundQueueDepth: 6,
        hardStepDeadline: const Duration(seconds: 120),
        schedulerEnabled: true,
      );
      expect(DispatcherConfig.fromYamlString(original.toYamlString()), original);
    });

    test('toYamlString omits scripts.user when absent', () {
      expect(DispatcherConfig().toYamlString(), isNot(contains('user:')));
    });

    test('a path that could be misread as a scalar is quoted on emit', () {
      final original = DispatcherConfig(systemScriptsPath: 'true');
      expect(original.toYamlString(), contains('system: "true"'));
      expect(DispatcherConfig.fromYamlString(original.toYamlString()), original);
    });
  });

  group('D.47-6 loadFromFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('d47_dispatcher_config');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a present file is parsed', () async {
      final file = File('${tempDir.path}/dispatcher.yaml');
      await file.writeAsString('queue:\n  foregroundDepth: 9\n');
      final config = await DispatcherConfig.loadFromFile(file);
      expect(config.foregroundQueueDepth, 9);
    });

    test('an absent file yields the all-defaults config', () async {
      final file = File('${tempDir.path}/missing.yaml');
      expect(await DispatcherConfig.loadFromFile(file), DispatcherConfig());
    });
  });

  group('D.47-7 malformed input → DispatcherConfigInvalid', () {
    test('a non-mapping document is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('- a\n- b'),
        throwsA(isA<DispatcherConfigInvalid>()),
      );
    });

    test('a non-mapping section is rejected with its path', () {
      expect(
        () => DispatcherConfig.fromYamlString('queue: 4'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'queue'),
        ),
      );
    });

    test('a non-integer foregroundDepth is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('queue:\n  foregroundDepth: nope'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'queue.foregroundDepth'),
        ),
      );
    });

    test('a negative foregroundDepth is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('queue:\n  foregroundDepth: -2'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'queue.foregroundDepth'),
        ),
      );
    });

    test('a non-positive hardStepMs is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('deadline:\n  hardStepMs: 0'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'deadline.hardStepMs'),
        ),
      );
    });

    test('a non-boolean scheduler.enabled is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('scheduler:\n  enabled: 1'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'scheduler.enabled'),
        ),
      );
    });

    test('an empty scripts.system is rejected', () {
      expect(
        () => DispatcherConfig.fromYamlString('scripts:\n  system: ""'),
        throwsA(
          isA<DispatcherConfigInvalid>()
              .having((e) => e.path, 'path', 'scripts.system'),
        ),
      );
    });

    test('invalid YAML is wrapped, not surfaced as a YamlException', () {
      expect(
        () => DispatcherConfig.fromYamlString('foo: : :'),
        throwsA(isA<DispatcherConfigInvalid>()),
      );
    });

    test('toString carries the dispatcher.config.invalid prefix + path', () {
      const error = DispatcherConfigInvalid('must be an integer', path: 'queue.foregroundDepth');
      expect(
        error.toString(),
        'dispatcher.config.invalid: must be an integer (at "queue.foregroundDepth")',
      );
    });
  });

  group('D.47-8 copyWith + equality', () {
    test('copyWith overrides only the named fields', () {
      final base = DispatcherConfig();
      final copy = base.copyWith(foregroundQueueDepth: 7, schedulerEnabled: true);
      expect(copy.foregroundQueueDepth, 7);
      expect(copy.schedulerEnabled, isTrue);
      expect(copy.systemScriptsPath, base.systemScriptsPath);
      expect(copy.hardStepDeadline, base.hardStepDeadline);
    });

    test('value equality + hashCode hold for equal configs', () {
      final a = DispatcherConfig(foregroundQueueDepth: 3, schedulerEnabled: true);
      final b = DispatcherConfig(foregroundQueueDepth: 3, schedulerEnabled: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing configs are unequal', () {
      expect(
        DispatcherConfig(foregroundQueueDepth: 3),
        isNot(DispatcherConfig(foregroundQueueDepth: 4)),
      );
    });
  });
}
