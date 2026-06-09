// HistoryStore — durable backing for the session manager's conversation
// histories (persistence of history; umbrella Hard principle 6).
//
// What this file locks:
//
//   1. `MapHistoryStore` round-trips a snapshot document in memory and isolates
//      the caller from internal state (returned maps are copies; saved maps are
//      copied in).
//   2. `JsonFileHistoryStore` returns an empty map for a missing file (first
//      boot), round-trips the document through the file, overwrites on re-save,
//      and creates a missing parent directory.
//   3. A corrupt existing file makes `load()` throw `HistoryStoreException`
//      rather than silently returning empty — refusing to reset is the whole
//      point (a silently-reset history is the restart amnesia the persistence
//      exists to prevent).

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';

void main() {
  group('MapHistoryStore', () {
    test('a fresh store loads empty', () {
      expect(MapHistoryStore().load(), isEmpty);
    });

    test('save then load round-trips the snapshot', () {
      final store = MapHistoryStore();
      store.save({
        'globals': [
          {'user': 'owner', 'channel': 'telegram'},
        ],
        'sessions': {'s1': {}},
      });
      final loaded = store.load();
      expect((loaded['globals'] as List).length, 1);
      expect((loaded['sessions'] as Map).keys, contains('s1'));
    });

    test('load() returns a copy — mutating it does not affect the store', () {
      final store = MapHistoryStore();
      store.save({
        'sessions': {'s1': {}},
      });
      (store.load()['sessions'] as Map)['s2'] = <String, Object?>{};
      expect((store.load()['sessions'] as Map).keys, isNot(contains('s2')));
    });

    test('save() copies in — mutating the source afterwards is ignored', () {
      final store = MapHistoryStore();
      final source = <String, Object?>{
        'sessions': {'s1': {}},
      };
      store.save(source);
      (source['sessions'] as Map)['s2'] = <String, Object?>{};
      expect((store.load()['sessions'] as Map).keys, isNot(contains('s2')));
    });
  });

  group('JsonFileHistoryStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('history_store_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String pathIn(String name) => '${dir.path}/$name';

    test('a missing file loads empty (first boot)', () {
      final store = JsonFileHistoryStore(pathIn('histories.json'));
      expect(store.load(), isEmpty);
    });

    test('save then load round-trips the snapshot through the file', () {
      final store = JsonFileHistoryStore(pathIn('histories.json'));
      store.save({
        'globals': [
          {'user': 'owner', 'channel': 'telegram'},
        ],
        'sessions': {'s1': {}},
      });

      // A brand-new store over the same path (as after a restart) sees it.
      final reopened = JsonFileHistoryStore(pathIn('histories.json'));
      final loaded = reopened.load();
      expect((loaded['globals'] as List).length, 1);
      expect((loaded['sessions'] as Map).keys, contains('s1'));
    });

    test('save() overwrites a prior file', () {
      final store = JsonFileHistoryStore(pathIn('histories.json'));
      store.save({
        'sessions': {'s1': {}},
      });
      store.save({
        'sessions': {'s2': {}},
      });
      expect((store.load()['sessions'] as Map).keys, {'s2'});
    });

    test('save() creates a missing parent directory', () {
      final store = JsonFileHistoryStore(pathIn('nested/sub/histories.json'));
      store.save({
        'sessions': {'s1': {}},
      });
      expect(File(pathIn('nested/sub/histories.json')).existsSync(), isTrue);
      expect((store.load()['sessions'] as Map).keys, contains('s1'));
    });

    test('a corrupt file makes load() throw, not silently reset', () {
      final path = pathIn('histories.json');
      File(path).writeAsStringSync('}{ not json');
      final store = JsonFileHistoryStore(path);
      expect(store.load, throwsA(isA<HistoryStoreException>()));
    });

    test('a non-object root makes load() throw', () {
      final path = pathIn('histories.json');
      File(path).writeAsStringSync('[1, 2, 3]');
      final store = JsonFileHistoryStore(path);
      expect(store.load, throwsA(isA<HistoryStoreException>()));
    });

    test('HistoryStoreException toString carries the path', () {
      const e = HistoryStoreException('bad', '/some/path.json');
      expect(e.toString(), contains('/some/path.json'));
      expect(e.toString(), contains('bad'));
    });
  });
}
