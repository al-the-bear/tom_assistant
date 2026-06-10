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
}
