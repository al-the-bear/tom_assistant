// Session-todo durability across a process restart (`SessionTodoStores`
// persistent backend).
//
// A `TodoStore` is loop scratch, and `SessionTodoStores` keeps a conversation's
// working list alive across the runs of that session *within one process*. But
// the user's working todo list must also survive a brain restart: a plan the
// brain wrote down before it was stopped must still be there when it comes back
// up. This suite pins that contract against `SessionTodoStores.persistentAt`,
// the JSON-file backed registry — exactly the precedent set by the brain-mode
// agent-SDK session store (`agent_sdk_sessions.json`).
//
// "Restart" is modelled by constructing a fresh `SessionTodoStores.persistentAt`
// over the same file: the second instance shares no memory with the first, so
// anything it sees came off disk.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SessionTodoStores;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('session_todos_');
    file = File('${dir.path}/session_todos.json');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('SessionTodoStores persistence', () {
    test('a session list survives a restart (fresh instance, same file)', () {
      final first = SessionTodoStores.persistentAt(file);
      final store = first.forSession('session-a');
      store.add('write the spec');
      store.add('write the code');

      // Restart: a brand-new registry over the same file.
      final second = SessionTodoStores.persistentAt(file);
      final reloaded = second.peek('session-a');
      expect(reloaded, isNotNull,
          reason: 'the session list must be rehydrated from disk on restart');
      expect(reloaded!.list().map((e) => e.text),
          equals(<String>['write the spec', 'write the code']));
    });

    test('done state and entry ids survive a restart', () {
      final first = SessionTodoStores.persistentAt(file);
      final store = first.forSession('session-a');
      final firstId = store.add('first');
      store.add('second');
      store.update(firstId, done: true);

      final second = SessionTodoStores.persistentAt(file);
      final reloaded = second.peek('session-a')!;
      final entries = reloaded.list();
      expect(entries[0].id, equals(firstId),
          reason: 'the stable id must be preserved across the restart');
      expect(entries[0].done, isTrue);
      expect(entries[1].done, isFalse);
    });

    test('a rehydrated store never reissues an id a prior entry held', () {
      final first = SessionTodoStores.persistentAt(file);
      final a = first.forSession('session-a');
      final id1 = a.add('one');
      final id2 = a.add('two');

      final second = SessionTodoStores.persistentAt(file);
      final reloaded = second.forSession('session-a');
      final id3 = reloaded.add('three');
      expect(<String>{id1, id2, id3}, hasLength(3),
          reason: 'the id sequence continues past the rehydrated entries');
    });

    test('separate sessions round-trip independently', () {
      final first = SessionTodoStores.persistentAt(file);
      first.forSession('session-a').add('a-item');
      first.forSession('session-b').add('b-item');

      final second = SessionTodoStores.persistentAt(file);
      expect(second.peek('session-a')!.list().single.text, equals('a-item'));
      expect(second.peek('session-b')!.list().single.text, equals('b-item'));
    });

    test('clearing a session persists the empty list across a restart', () {
      final first = SessionTodoStores.persistentAt(file);
      first.forSession('session-a').add('item');
      expect(first.clearSession('session-a'), isTrue);

      final second = SessionTodoStores.persistentAt(file);
      final reloaded = second.peek('session-a');
      // The session is known (it was created) but its list is empty.
      expect(reloaded?.list() ?? const [], isEmpty,
          reason: 'a clear before restart must not resurrect the old items');
    });

    test('a corrupt file degrades to an empty registry rather than throwing',
        () {
      file.writeAsStringSync('}{ not json');
      final stores = SessionTodoStores.persistentAt(file);
      expect(stores.peek('session-a'), isNull);
      // And it recovers: a new write produces a valid file again.
      stores.forSession('session-a').add('fresh');
      final after = SessionTodoStores.persistentAt(file);
      expect(after.peek('session-a')!.list().single.text, equals('fresh'));
    });

    test('a missing file reads as an empty registry', () {
      expect(file.existsSync(), isFalse);
      final stores = SessionTodoStores.persistentAt(file);
      expect(stores.peek('anything'), isNull);
    });

    test('the in-memory registry writes no file', () {
      final stores = SessionTodoStores();
      stores.forSession('session-a').add('item');
      expect(file.existsSync(), isFalse,
          reason: 'the default constructor has no disk backend');
    });

    test('the persisted file is valid JSON keyed by session id', () {
      final stores = SessionTodoStores.persistentAt(file);
      stores.forSession('session-a').add('item');

      final decoded = jsonDecode(file.readAsStringSync());
      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded as Map).keys, contains('session-a'));
    });
  });
}
