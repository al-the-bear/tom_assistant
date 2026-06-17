// Tests for the `history:` config-block parser (history-compaction quest,
// todo #5; hub spec § 22.6b/c; decisions HC-1 / HC-2).
//
// Surface under test (pure value types in `tom_brain_shared`):
//   * `HistoryConfig` — the parsed block: a `defaults` sizing plus per-lane
//     overrides keyed by laneId, with the lane → defaults → code-default
//     resolution and the rawCount >= 10 floor.
//   * `HistoryConfig.fromConfigMap` — the parser, including the fail-fast
//     `HistoryConfigError` on a below-floor value.
//   * `HistoryConfig.sizingFor` — the per-lane resolver (override else
//     defaults).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('HistoryConfig.fromConfigMap — defaults only', () {
    test('a defaults block sizes every lane without overrides', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{
          'rawCount': 20,
          'compactionThreshold': 50,
          'maxCompactedTokens': 2048,
          'maxCompactedChars': 8000,
        },
      });

      expect(config.defaults.rawCount, 20);
      expect(config.defaults.compactionThreshold, 50);
      expect(config.defaults.maxCompactedTokens, 2048);
      expect(config.defaults.maxCompactedChars, 8000);
      expect(config.lanes, isEmpty);
      // A lane with no override inherits the resolved defaults.
      expect(config.sizingFor('foreground'), config.defaults);
    });

    test('a partial defaults block inherits unspecified knobs from the code '
        'default', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{'rawCount': 15},
      });

      expect(config.defaults.rawCount, 15);
      // The three unset knobs fall back to the code defaults.
      expect(config.defaults.compactionThreshold, 40);
      expect(config.defaults.maxCompactedTokens, 1024);
      expect(config.defaults.maxCompactedChars, 6000);
    });

    test('compactionThreshold defaults to 40 when the block omits it', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{'rawCount': 10},
      });

      expect(config.defaults.compactionThreshold, 40);
    });
  });

  group('HistoryConfig.fromConfigMap — per-lane override', () {
    test('a lane override resolves its knobs over the resolved defaults', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{
          'rawCount': 12,
          'compactionThreshold': 30,
        },
        'lanes': <String, Object?>{
          'dream_slow': <String, Object?>{
            'rawCount': 25,
            'maxCompactedChars': 9000,
          },
        },
      });

      final lane = config.sizingFor('dream_slow');
      // Overridden knobs take the lane value.
      expect(lane.rawCount, 25);
      expect(lane.maxCompactedChars, 9000);
      // Knobs the lane omits inherit the resolved defaults, not the code
      // default — compactionThreshold 30 came from the defaults block.
      expect(lane.compactionThreshold, 30);
      // maxCompactedTokens was set nowhere → code default.
      expect(lane.maxCompactedTokens, 1024);
    });

    test('a lane absent from the block resolves to defaults', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{'rawCount': 18},
        'lanes': <String, Object?>{
          'foreground': <String, Object?>{'rawCount': 22},
        },
      });

      expect(config.sizingFor('foreground').rawCount, 22);
      // A lane with no entry inherits the defaults.
      expect(config.sizingFor('dream_fast'), config.defaults);
      expect(config.sizingFor('dream_fast').rawCount, 18);
    });
  });

  group('HistoryConfig.fromConfigMap — missing block', () {
    test('a null block yields the code defaults', () {
      final config = HistoryConfig.fromConfigMap(null);

      expect(config.defaults, const HistorySizing.standard());
      expect(config.defaults.rawCount, 10);
      expect(config.defaults.compactionThreshold, 40);
      expect(config.lanes, isEmpty);
      expect(config, equals(const HistoryConfig.standard()));
    });

    test('an empty block yields the code defaults', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{});

      expect(config.defaults, const HistorySizing.standard());
      expect(config.lanes, isEmpty);
    });
  });

  // Todo #6: the lane-aware resolver `sizingFor(laneId)` returns
  // `lane override ?? defaults ?? HistorySizing.standard()`. These tests prove
  // the three resolution arms directly on the resolver (the parser-resolution
  // tests above exercise it incidentally; this group is its dedicated proof).
  group('HistoryConfig.sizingFor — lane resolution', () {
    test('a set lane wins over the defaults', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{'rawCount': 12},
        'lanes': <String, Object?>{
          'foreground': <String, Object?>{'rawCount': 30},
        },
      });

      expect(config.sizingFor('foreground').rawCount, 30);
    });

    test('an unset lane inherits the defaults', () {
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'defaults': <String, Object?>{'rawCount': 12},
        'lanes': <String, Object?>{
          'foreground': <String, Object?>{'rawCount': 30},
        },
      });

      // A lane with no override returns the exact defaults sizing.
      expect(config.sizingFor('dream_fast'), same(config.defaults));
      expect(config.sizingFor('dream_fast').rawCount, 12);
    });

    test('with no defaults block, an unset lane resolves to the code default', () {
      // Exercises the `?? HistorySizing.standard()` arm: when the block carries
      // no `defaults`, `defaults` IS the standard sizing, so an unset lane
      // resolves to it.
      final config = HistoryConfig.fromConfigMap(<String, Object?>{
        'lanes': <String, Object?>{
          'foreground': <String, Object?>{'rawCount': 30},
        },
      });

      expect(config.sizingFor('absent'), const HistorySizing.standard());
      expect(config.sizingFor('foreground').rawCount, 30);
    });

    test('resolves over a directly-constructed config (no parse)', () {
      const config = HistoryConfig(
        defaults: HistorySizing(rawCount: 14),
        lanes: <String, HistorySizing>{
          'dream_slow': HistorySizing(rawCount: 40),
        },
      );

      expect(config.sizingFor('dream_slow').rawCount, 40);
      expect(config.sizingFor('foreground'), const HistorySizing(rawCount: 14));
    });
  });

  group('HistoryConfig.fromConfigMap — below-floor rejection', () {
    test('a defaults rawCount below 10 is rejected, not clamped', () {
      expect(
        () => HistoryConfig.fromConfigMap(<String, Object?>{
          'defaults': <String, Object?>{'rawCount': 5},
        }),
        throwsA(
          isA<HistoryConfigError>()
              .having((e) => e.laneId, 'laneId', isNull)
              .having((e) => e.knob, 'knob', 'rawCount')
              .having((e) => e.value, 'value', 5)
              .having((e) => e.minimum, 'minimum', 10),
        ),
      );
    });

    test('a lane rawCount below 10 is rejected and names the lane', () {
      expect(
        () => HistoryConfig.fromConfigMap(<String, Object?>{
          'lanes': <String, Object?>{
            'dream_deep': <String, Object?>{'rawCount': 3},
          },
        }),
        throwsA(
          isA<HistoryConfigError>()
              .having((e) => e.laneId, 'laneId', 'dream_deep')
              .having((e) => e.knob, 'knob', 'rawCount')
              .having((e) => e.value, 'value', 3),
        ),
      );
    });

    test('a non-positive compactionThreshold is rejected', () {
      expect(
        () => HistoryConfig.fromConfigMap(<String, Object?>{
          'defaults': <String, Object?>{
            'rawCount': 10,
            'compactionThreshold': 0,
          },
        }),
        throwsA(
          isA<HistoryConfigError>()
              .having((e) => e.knob, 'knob', 'compactionThreshold')
              .having((e) => e.minimum, 'minimum', 1),
        ),
      );
    });

    test('the error message names the location, knob, value, and minimum', () {
      HistoryConfigError? error;
      try {
        HistoryConfig.fromConfigMap(<String, Object?>{
          'lanes': <String, Object?>{
            'dream_deep': <String, Object?>{'rawCount': 4},
          },
        });
      } on HistoryConfigError catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(error.toString(), contains('history.lanes.dream_deep.rawCount'));
      expect(error.toString(), contains('4'));
      expect(error.toString(), contains('minimum of 10'));
    });
  });

  group('HistoryConfig.toJson — the resolved-sizing wire shape (todo #16)', () {
    test('emits defaults and per-lane overrides as nested sizing maps', () {
      final config = HistoryConfig(
        defaults: const HistorySizing(),
        lanes: const <String, HistorySizing>{
          foregroundAnswerLaneId:
              HistorySizing(rawCount: 20, compactionThreshold: 60),
          'dream_deep': HistorySizing(rawCount: 15),
        },
      );

      final json = config.toJson();
      expect(json['defaults'], const HistorySizing().toJson());
      final lanes = (json['lanes'] as Map).cast<String, Object?>();
      expect(
        lanes[foregroundAnswerLaneId],
        const HistorySizing(rawCount: 20, compactionThreshold: 60).toJson(),
      );
      expect(lanes['dream_deep'],
          const HistorySizing(rawCount: 15).toJson());
    });

    test('a config with no lane overrides emits an empty lanes map', () {
      final json = const HistoryConfig.standard().toJson();
      expect(json['defaults'], const HistorySizing.standard().toJson());
      expect((json['lanes'] as Map), isEmpty);
    });

    test('the JSON round-trips the effective per-lane sizing', () {
      final config = HistoryConfig(
        defaults: const HistorySizing(rawCount: 12),
        lanes: const <String, HistorySizing>{
          'dream_light': HistorySizing(rawCount: 30),
        },
      );

      final json = config.toJson();
      // A consumer (the Observatory) reconstructs `sizingFor` losslessly: a lane
      // present in `lanes` shows its override; any other lane resolves to
      // `defaults`.
      final lanes = (json['lanes'] as Map).cast<String, Object?>();
      expect(
        HistorySizing.fromJson(
            (lanes['dream_light'] as Map).cast<String, Object?>()),
        config.sizingFor('dream_light'),
      );
      expect(
        HistorySizing.fromJson(
            (json['defaults'] as Map).cast<String, Object?>()),
        config.sizingFor('an_unlisted_lane'),
      );
    });
  });
}
