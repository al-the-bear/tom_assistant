// DreamConfig + DreamConfigLoader (item b) — the `dream:` section of the
// whole-process config: whether the scheduled dream cadence runs at boot, the
// daily windows it runs in, and an optional heartbeat override.
//
// These tests mirror the sibling section-loader discipline: an absent block
// resolves to `null` (no dream loop at boot), a present block parses into a
// typed `DreamConfig`, and every malformed shape surfaces a located
// `DreamConfigException`.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  group('DreamConfigLoader.parse', () {
    test('an absent dream block resolves to null', () {
      expect(DreamConfigLoader.parse('memory: {}\n'), isNull);
    });

    test('an empty dream block defaults to disabled, always-active, no '
        'heartbeat', () {
      final config = DreamConfigLoader.parse('dream: {}\n');
      expect(config, isNotNull);
      expect(config!.enabled, isFalse);
      expect(config.schedule.isAlwaysActive, isTrue);
      expect(config.heartbeat, isNull);
    });

    test('a full dream block parses enabled, windows, and heartbeat', () {
      const yaml = '''
dream:
  enabled: true
  windows:
    - {start: '02:00', end: '05:00'}
    - {start: '13:00', end: '14:00'}
  heartbeatSeconds: 30
''';
      final config = DreamConfigLoader.parse(yaml)!;
      expect(config.enabled, isTrue);
      expect(config.schedule.windows, hasLength(2));
      expect(config.schedule.isActiveAt(DateTime(2026, 6, 10, 3, 0)), isTrue);
      expect(config.schedule.isActiveAt(DateTime(2026, 6, 10, 13, 30)), isTrue);
      expect(config.schedule.isActiveAt(DateTime(2026, 6, 10, 8, 0)), isFalse);
      expect(config.heartbeat, const Duration(seconds: 30));
    });

    test('enabled with no windows is enabled and always-active', () {
      const yaml = 'dream:\n  enabled: true\n';
      final config = DreamConfigLoader.parse(yaml)!;
      expect(config.enabled, isTrue);
      expect(config.schedule.isAlwaysActive, isTrue);
    });

    test('an unknown key under dream is a located error', () {
      expect(
        () => DreamConfigLoader.parse('dream:\n  bogus: 1\n'),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('bogus'),
        )),
      );
    });

    test('a malformed window bound is a located error naming the slot', () {
      const yaml = '''
dream:
  windows:
    - {start: '02:00', end: '99:99'}
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.windows[0]'),
        )),
      );
    });

    test('a window missing its end bound is a located error', () {
      const yaml = '''
dream:
  windows:
    - {start: '02:00'}
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.windows[0].end'),
        )),
      );
    });

    test('a non-positive heartbeat is a located error', () {
      const yaml = 'dream:\n  heartbeatSeconds: 0\n';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('heartbeatSeconds'),
        )),
      );
    });
  });

  // Parts b + e — the configurable, named dream lanes. An absent `lanes:`
  // block leaves `cadence` null (the driver falls back to
  // `CadenceSchedule.defaults`); a present block replaces the lane set
  // wholesale (HP1) and is validated by the `CadenceSchedule` constructor.
  group('DreamConfigLoader.parse — dream.lanes (parts b + e)', () {
    test('an absent lanes block leaves cadence null', () {
      final config = DreamConfigLoader.parse('dream: {}\n')!;
      expect(config.cadence, isNull);
    });

    test('a lanes block parses into a CadenceSchedule with the given ids, '
        'intervals, and agents', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
      agents: [dream_extract_v1, dream_connect_v1]
    - id: nightly
      intervalSeconds: 86400
      agents: [research_v1]
      maxLlmCallsPerWindow: 5
''';
      final config = DreamConfigLoader.parse(yaml)!;
      final cadence = config.cadence!;
      expect(cadence.lanes, hasLength(2));

      final fast = cadence.laneById('fast')!;
      expect(fast.interval, const Duration(seconds: 300));
      expect(fast.agents, <String>['dream_extract_v1', 'dream_connect_v1']);
      expect(fast.maxLlmCallsPerWindow, isNull);

      final nightly = cadence.laneById('nightly')!;
      expect(nightly.interval, const Duration(seconds: 86400));
      expect(nightly.agents, <String>['research_v1']);
      expect(nightly.maxLlmCallsPerWindow, 5);
    });

    test('a lane missing its id is a located error', () {
      const yaml = '''
dream:
  lanes:
    - intervalSeconds: 300
      agents: [dream_extract_v1]
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].id'),
        )),
      );
    });

    test('a lane missing its intervalSeconds is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      agents: [dream_extract_v1]
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].intervalSeconds'),
        )),
      );
    });

    test('a non-positive lane interval is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 0
      agents: [dream_extract_v1]
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].intervalSeconds'),
        )),
      );
    });

    test('a lane missing its agents is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].agents'),
        )),
      );
    });

    test('an empty agent id inside a lane is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
      agents: ['']
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].agents[0]'),
        )),
      );
    });

    test('a non-positive maxLlmCallsPerWindow is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
      agents: [dream_extract_v1]
      maxLlmCallsPerWindow: 0
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes[0].maxLlmCallsPerWindow'),
        )),
      );
    });

    test('an unknown key under a lane is a located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
      agents: [dream_extract_v1]
      bogus: 1
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('bogus'),
        )),
      );
    });

    test('duplicate lane ids surface the CadenceSchedule validation as a '
        'located error', () {
      const yaml = '''
dream:
  lanes:
    - id: fast
      intervalSeconds: 300
      agents: [dream_extract_v1]
    - id: fast
      intervalSeconds: 600
      agents: [dream_connect_v1]
''';
      expect(
        () => DreamConfigLoader.parse(yaml),
        throwsA(isA<DreamConfigException>().having(
          (e) => e.message,
          'message',
          contains('dream.lanes is invalid'),
        )),
      );
    });
  });
}
