// Unit tests for the RuntimeSnapshot wire shape (history-compaction quest,
// todo #16; `prompt_tracing.md` § 6.4, § 8.3(13)).
//
// The snapshot is a pure value (`src/launch/runtime_snapshot.dart` has no
// imports), so these tests exercise its `toJson` shape directly — independent
// of the HTTP harness in `runtime_endpoint_test.dart`, which additionally
// proves the `GET /api/runtime` route serves this map.
//
// Focus of this file: the `history` facet added for todo #16 — the resolved
// per-lane sizing the brain bound, surfaced to the Runtime tab's
// "currently-running" display, omitted byte-stably when standalone.

import 'package:tom_brain_observatory/src/launch/runtime_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('RuntimeSnapshot.toJson — the resolved history sizing (todo #16)', () {
    test('emits the threaded history map under the `history` key', () {
      const snapshot = RuntimeSnapshot(
        openAiPort: 8841,
        openAiBasePath: '/v1',
        history: <String, Object?>{
          'defaults': <String, Object?>{
            'rawCount': 10,
            'compactionThreshold': 40,
            'maxCompactedTokens': 1024,
            'maxCompactedChars': 6000,
          },
          'lanes': <String, Object?>{
            'foreground': <String, Object?>{
              'rawCount': 20,
              'compactionThreshold': 60,
              'maxCompactedTokens': 1024,
              'maxCompactedChars': 6000,
            },
          },
        },
      );

      final json = snapshot.toJson();
      final history = (json['history'] as Map).cast<String, Object?>();
      final defaults = (history['defaults'] as Map).cast<String, Object?>();
      expect(defaults['rawCount'], 10);
      final lanes = (history['lanes'] as Map).cast<String, Object?>();
      final foreground = (lanes['foreground'] as Map).cast<String, Object?>();
      expect(foreground['rawCount'], 20);
      expect(foreground['compactionThreshold'], 60);
    });

    test('omits the `history` key when no sizing was threaded in', () {
      const snapshot =
          RuntimeSnapshot(openAiPort: 9001, openAiBasePath: '/v1');
      expect(snapshot.toJson().containsKey('history'), isFalse);
    });

    test('the history facet is orthogonal to the gateways and roots', () {
      const snapshot = RuntimeSnapshot(
        openAiPort: 8841,
        openAiBasePath: '/v1',
        memoryRoot: '/srv/mem',
        history: <String, Object?>{
          'defaults': <String, Object?>{'rawCount': 10},
          'lanes': <String, Object?>{},
        },
      );
      final json = snapshot.toJson();
      expect((json['roots'] as Map)['memory'], '/srv/mem');
      expect(json.containsKey('history'), isTrue);
    });
  });
}
