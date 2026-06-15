// MemoryRecallNotice — the per-recall trace line the dispatch route turns into
// out-of-band Telegram messages when `/trace_memory` is ON (access spec § 6.5).
//
// What is proven:
//   1. `fromCall` ignores non-recall primitives (returns null) so persist/edge/
//      stack calls never surface a trace line.
//   2. `fromCall` lifts the per-mode candidate counts, the returned-node count,
//      and the degraded flag off a `recall` / `recallMulti` result map.
//   3. `noticeLines` renders one line per retrieval mode plus a closing summary,
//      with the degraded marker appended only when the recall ran degraded.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('MemoryRecallNotice.fromCall', () {
    test('returns null for a non-recall primitive', () {
      expect(MemoryRecallNotice.fromCall('persistNote', const {}), isNull);
      expect(MemoryRecallNotice.fromCall('addEdge', const {}), isNull);
      expect(MemoryRecallNotice.fromCall('stackPush', const {}), isNull);
    });

    test('lifts per-mode counts, node count, and degraded off a recall result',
        () {
      final notice = MemoryRecallNotice.fromCall('recall', <String, Object?>{
        'nodes': [
          {'id': 'n1'},
          {'id': 'n2'},
        ],
        'report': <String, Object?>{
          'candidatesPerMode': <String, Object?>{'bm25': 4, 'vector': 7},
          'degraded': false,
        },
      });

      expect(notice, isNotNull);
      expect(notice!.primitive, 'recall');
      expect(notice.candidatesPerMode, {'bm25': 4, 'vector': 7});
      expect(notice.nodesReturned, 2);
      expect(notice.degraded, isFalse);
    });

    test('tolerates a missing report (zero modes, zero nodes)', () {
      final notice =
          MemoryRecallNotice.fromCall('recallMulti', const <String, Object?>{});
      expect(notice, isNotNull);
      expect(notice!.candidatesPerMode, isEmpty);
      expect(notice.nodesReturned, 0);
      expect(notice.degraded, isFalse);
    });
  });

  group('MemoryRecallNotice.noticeLines', () {
    test('renders one line per mode then a summary line', () {
      final notice = MemoryRecallNotice.fromCall('recall', <String, Object?>{
        'nodes': [
          {'id': 'n1'},
          {'id': 'n2'},
          {'id': 'n3'},
        ],
        'report': <String, Object?>{
          'candidatesPerMode': <String, Object?>{'bm25': 1, 'vector': 5},
        },
      })!;

      final lines = notice.noticeLines();
      expect(lines, hasLength(3)); // two modes + summary
      expect(lines[0], contains('bm25 search'));
      expect(lines[0], contains('1 candidate'));
      expect(lines[1], contains('vector search'));
      expect(lines[1], contains('5 candidates'));
      expect(lines.last, contains('recall'));
      expect(lines.last, contains('3 results'));
    });

    test('appends the degraded marker only when the recall ran degraded', () {
      final degraded = MemoryRecallNotice.fromCall('recall', <String, Object?>{
        'nodes': const [],
        'report': <String, Object?>{
          'candidatesPerMode': <String, Object?>{},
          'degraded': true,
        },
      })!;
      expect(degraded.noticeLines().single, contains('(degraded)'));

      final healthy = MemoryRecallNotice.fromCall('recall', <String, Object?>{
        'nodes': const [],
        'report': <String, Object?>{'candidatesPerMode': <String, Object?>{}},
      })!;
      expect(healthy.noticeLines().single, isNot(contains('(degraded)')));
    });
  });
}
