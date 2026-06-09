// EdgeStateStore — durable backing for the edge limiters' per-principal state.
//
// What this file locks:
//
//   1. `MapEdgeStateStore` round-trips rows in memory and isolates the caller
//      from internal state (returned maps are copies; saved maps are copied in).
//   2. `JsonFileEdgeStateStore` returns an empty map for a missing file (first
//      boot), round-trips rows through the file (preserving JSON scalar types),
//      overwrites on re-save, and creates a missing parent directory.
//   3. A corrupt existing file makes `load()` throw `EdgeStateStoreException`
//      rather than silently returning empty — refusing to reset is the whole
//      point (a silently-reset quota is the restart-near-midnight bypass the
//      persistence exists to prevent).

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

void main() {
  group('MapEdgeStateStore', () {
    test('a fresh store loads empty', () {
      expect(MapEdgeStateStore().load(), isEmpty);
    });

    test('save then load round-trips the rows', () {
      final store = MapEdgeStateStore();
      store.save({
        'p1': {'calls': 2, 'dayStart': '2026-06-02T00:00:00.000'},
        'p2': {'tokens': 1.5, 'lastRefill': '2026-06-02T09:00:00.000Z'},
      });
      final loaded = store.load();
      expect(loaded.keys.toSet(), {'p1', 'p2'});
      expect(loaded['p1']!['calls'], 2);
      expect(loaded['p2']!['tokens'], 1.5);
    });

    test('load() returns a copy — mutating it does not affect the store', () {
      final store = MapEdgeStateStore();
      store.save({
        'p1': {'calls': 1},
      });
      store.load()['p1']!['calls'] = 99;
      expect(store.load()['p1']!['calls'], 1);
    });

    test('save() copies in — mutating the source afterwards is ignored', () {
      final store = MapEdgeStateStore();
      final source = <String, Map<String, Object?>>{
        'p1': {'calls': 1},
      };
      store.save(source);
      source['p1']!['calls'] = 99;
      expect(store.load()['p1']!['calls'], 1);
    });
  });

  group('JsonFileEdgeStateStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('edge_state_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String pathIn(String name) => '${dir.path}/$name';

    test('a missing file loads empty (first boot)', () {
      final store = JsonFileEdgeStateStore(pathIn('quota_state.json'));
      expect(store.load(), isEmpty);
    });

    test('save then load round-trips rows through the file', () {
      final store = JsonFileEdgeStateStore(pathIn('quota_state.json'));
      store.save({
        'p1': {'calls': 2, 'dayStart': '2026-06-02T00:00:00.000'},
        'p2': {'tokens': 1.5, 'lastRefill': '2026-06-02T09:00:00.000Z'},
      });

      // A brand-new store over the same path (as after a restart) sees it.
      final reopened = JsonFileEdgeStateStore(pathIn('quota_state.json'));
      final loaded = reopened.load();
      expect(loaded['p1']!['calls'], 2);
      expect(loaded['p2']!['tokens'], 1.5);
      expect(loaded['p1']!['dayStart'], '2026-06-02T00:00:00.000');
    });

    test('save() overwrites a prior file', () {
      final store = JsonFileEdgeStateStore(pathIn('quota_state.json'));
      store.save({
        'p1': {'calls': 5},
      });
      store.save({
        'p2': {'calls': 1},
      });
      final loaded = store.load();
      expect(loaded.keys.toSet(), {'p2'});
    });

    test('save() creates a missing parent directory', () {
      final store = JsonFileEdgeStateStore(pathIn('nested/sub/quota.json'));
      store.save({
        'p1': {'calls': 1},
      });
      expect(File(pathIn('nested/sub/quota.json')).existsSync(), isTrue);
      expect(store.load()['p1']!['calls'], 1);
    });

    test('a corrupt file makes load() throw, not silently reset', () {
      final path = pathIn('quota_state.json');
      File(path).writeAsStringSync('}{ not json');
      final store = JsonFileEdgeStateStore(path);
      expect(store.load, throwsA(isA<EdgeStateStoreException>()));
    });

    test('a JSON file whose rows are not objects makes load() throw', () {
      final path = pathIn('quota_state.json');
      File(path).writeAsStringSync(jsonEncode({'p1': 42}));
      final store = JsonFileEdgeStateStore(path);
      expect(store.load, throwsA(isA<EdgeStateStoreException>()));
    });

    test('EdgeStateStoreException toString carries the path', () {
      const e = EdgeStateStoreException('bad', '/some/path.json');
      expect(e.toString(), contains('/some/path.json'));
      expect(e.toString(), contains('bad'));
    });
  });
}
