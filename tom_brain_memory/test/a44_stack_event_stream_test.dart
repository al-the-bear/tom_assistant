// A.44 — `StackApi.events(name)` stream contract.
//
// A.40 and A.42 already exercise individual emission points (one
// `pushed` / `popped` / `updated` / `overflowDemoted` per call).
// This file pins the *stream-shape* properties of the per-stack
// observability surface that consumers will rely on:
//
//   1. The stream is a broadcast — two concurrent subscribers see
//      the same event sequence.
//   2. Per-stack isolation — events on stack A never leak into the
//      stream of stack B (and vice-versa).
//   3. The four `StackEventKind` values each carry the correct
//      payload fields (`entryId` for pushed/popped/updated,
//      `demotedIds` for overflowDemoted, `at` set to the call's
//      timestamp, `stackName` matching the stack).
//   4. Late subscribers do not receive replayed history (broadcast
//      semantics).
//   5. Subscribing to an unknown name returns an empty, live stream
//      that begins receiving events the moment a stack of that
//      name is created and pushed to. (This is the actual
//      behaviour of the current implementation — `events()` does
//      not validate the name; it lazily mints a controller.)
//   6. `pop` on an empty stack does not emit.
//   7. `delete(name)` closes the per-stack stream — subscribers
//      observe `onDone`.
//   8. `close()` closes every per-stack stream.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('A.44 StackEvent stream contract', () {
    late Database db;
    late DateTime fakeNow;
    late int idCounter;

    NodeId nodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
      );
    }

    StackEntryId entryId(int seed) => StackEntryId.generate(
          at: fakeNow,
          randomness: List<int>.generate(16, (i) => (seed * 11 + i) & 31),
        );

    SqliteStackApi buildApi() {
      var entrySeed = 7000;
      var stackNodeSeed = 11000;
      return SqliteStackApi(
        memoryDb: db,
        entryIdMint: () => entryId(entrySeed++),
        stackNodeIdMint: () {
          stackNodeSeed += 1;
          return NodeId.generate(
            at: fakeNow,
            randomness:
                List<int>.generate(16, (i) => (stackNodeSeed + i) & 31),
          );
        },
        now: () => fakeNow,
      );
    }

    StackPolicy fifoUnbounded() => const StackPolicy(
          priority: PriorityPolicyKind.fifo,
          retention: RetentionPolicyKind.unbounded,
        );

    StackDecl decl(String name) => StackDecl(
          name: name,
          summary: 'A.44 fixture stack: $name',
          policy: fifoUnbounded(),
          entryNodeType: 'Question',
        );

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 0;
    });

    tearDown(() {
      db.dispose();
    });

    // ─── 1. Broadcast ──────────────────────────────────────────────

    test('events(name) is a broadcast stream — two listeners see the '
        'same sequence', () async {
      final api = buildApi();
      await api.create(decl('alpha'));

      final a = <StackEvent>[];
      final b = <StackEvent>[];
      final subA = api.events('alpha').listen(a.add);
      final subB = api.events('alpha').listen(b.add);

      final n1 = nodeId();
      await api.push('alpha', n1, priority: 1.0);
      await api.update('alpha', n1, priority: 2.0);
      await api.pop('alpha');
      await pumpEventQueue();

      final kindsA = a.map((e) => e.kind).toList();
      final kindsB = b.map((e) => e.kind).toList();
      expect(
        kindsA,
        equals(<StackEventKind>[
          StackEventKind.pushed,
          StackEventKind.updated,
          StackEventKind.popped,
        ]),
      );
      expect(kindsB, equals(kindsA));

      await subA.cancel();
      await subB.cancel();
      await api.close();
    });

    // ─── 2. Per-stack isolation ────────────────────────────────────

    test('per-stack streams are isolated — alpha events do not appear '
        'on beta', () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      await api.create(decl('beta'));

      final alphaEvents = <StackEvent>[];
      final betaEvents = <StackEvent>[];
      final subA = api.events('alpha').listen(alphaEvents.add);
      final subB = api.events('beta').listen(betaEvents.add);

      final n1 = nodeId();
      final n2 = nodeId();
      await api.push('alpha', n1);
      await api.push('beta', n2);
      await api.pop('alpha');
      await pumpEventQueue();

      expect(alphaEvents.map((e) => e.stackName).toSet(), equals({'alpha'}));
      expect(betaEvents.map((e) => e.stackName).toSet(), equals({'beta'}));
      expect(
        alphaEvents.map((e) => e.kind).toList(),
        equals(<StackEventKind>[
          StackEventKind.pushed,
          StackEventKind.popped,
        ]),
      );
      expect(
        betaEvents.map((e) => e.kind).toList(),
        equals(<StackEventKind>[StackEventKind.pushed]),
      );

      await subA.cancel();
      await subB.cancel();
      await api.close();
    });

    // ─── 3. Payload shape per kind ─────────────────────────────────

    test('pushed event carries entryId, stackName, and the call timestamp',
        () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      final captured = <StackEvent>[];
      final sub = api.events('alpha').listen(captured.add);

      final n = nodeId();
      final pushAt = DateTime.utc(2026, 5, 30, 14, 0, 1);
      fakeNow = pushAt;
      final id = await api.push('alpha', n, priority: 3.0);
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final evt = captured.single;
      expect(evt.kind, equals(StackEventKind.pushed));
      expect(evt.stackName, equals('alpha'));
      expect(evt.entryId, equals(id));
      expect(evt.at, equals(pushAt));
      expect(evt.demotedIds, isEmpty);

      await sub.cancel();
      await api.close();
    });

    test('popped event carries the popped entryId and the call timestamp',
        () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      final n = nodeId();
      final pushedId = await api.push('alpha', n);

      final captured = <StackEvent>[];
      final sub = api.events('alpha').listen(captured.add);

      final popAt = DateTime.utc(2026, 5, 30, 14, 0, 2);
      fakeNow = popAt;
      await api.pop('alpha');
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final evt = captured.single;
      expect(evt.kind, equals(StackEventKind.popped));
      expect(evt.stackName, equals('alpha'));
      expect(evt.entryId, equals(pushedId));
      expect(evt.at, equals(popAt));

      await sub.cancel();
      await api.close();
    });

    test('updated event carries the updated entryId', () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      final n = nodeId();
      final pushedId = await api.push('alpha', n);

      final captured = <StackEvent>[];
      final sub = api.events('alpha').listen(captured.add);

      await api.update('alpha', n, priority: 5.0);
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final evt = captured.single;
      expect(evt.kind, equals(StackEventKind.updated));
      expect(evt.entryId, equals(pushedId));

      await sub.cancel();
      await api.close();
    });

    test('overflowDemoted event carries demotedIds, no entryId', () async {
      final api = buildApi();
      // bounded_n with maxCount=2 — third push must overflow.
      await api.create(StackDecl(
        name: 'cap',
        summary: 'bounded_n=2 fixture',
        policy: const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 2,
        ),
        entryNodeType: 'Question',
      ));

      final captured = <StackEvent>[];
      final sub = api.events('cap').listen(captured.add);

      final first = await api.push('cap', nodeId(), priority: 1.0);
      await api.push('cap', nodeId(), priority: 2.0);
      // Third push: highest priorities win, so `first` (priority 1.0)
      // becomes the lowest and is demoted.
      await api.push('cap', nodeId(), priority: 3.0);
      await pumpEventQueue();

      final demoted = captured
          .where((e) => e.kind == StackEventKind.overflowDemoted)
          .toList();
      expect(demoted, hasLength(1));
      expect(demoted.single.entryId, isNull);
      expect(demoted.single.demotedIds, equals(<StackEntryId>[first]));
      expect(demoted.single.stackName, equals('cap'));

      await sub.cancel();
      await api.close();
    });

    // ─── 4. Late subscriber gets no history ────────────────────────

    test('late subscribers do not receive previously emitted events',
        () async {
      final api = buildApi();
      await api.create(decl('alpha'));

      // Push before anyone subscribes.
      await api.push('alpha', nodeId());
      await api.push('alpha', nodeId());

      final late = <StackEvent>[];
      final sub = api.events('alpha').listen(late.add);
      await pumpEventQueue();
      expect(late, isEmpty);

      // New activity after subscription is delivered.
      await api.push('alpha', nodeId());
      await pumpEventQueue();
      expect(late.map((e) => e.kind).toList(),
          equals(<StackEventKind>[StackEventKind.pushed]));

      await sub.cancel();
      await api.close();
    });

    // ─── 5. Subscribing before create() works ──────────────────────

    test('events(name) before create(name) returns a live stream that '
        'fires once the stack is created and pushed to', () async {
      final api = buildApi();
      final captured = <StackEvent>[];
      // Subscribe to a name that does not yet exist.
      final sub = api.events('future').listen(captured.add);
      await pumpEventQueue();
      expect(captured, isEmpty);

      await api.create(decl('future'));
      await api.push('future', nodeId());
      await pumpEventQueue();

      expect(captured, hasLength(1));
      expect(captured.single.kind, equals(StackEventKind.pushed));
      expect(captured.single.stackName, equals('future'));

      await sub.cancel();
      await api.close();
    });

    // ─── 6. Empty pop emits nothing ────────────────────────────────

    test('pop on an empty stack does not emit', () async {
      final api = buildApi();
      await api.create(decl('alpha'));

      final captured = <StackEvent>[];
      final sub = api.events('alpha').listen(captured.add);

      final popped = await api.pop('alpha');
      await pumpEventQueue();
      expect(popped, isNull);
      expect(captured, isEmpty);

      await sub.cancel();
      await api.close();
    });

    // ─── 7. delete(name) closes the stream ─────────────────────────

    test('delete(name) closes the per-stack event stream — onDone fires',
        () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      final stream = api.events('alpha');
      var done = false;
      final sub = stream.listen((_) {}, onDone: () => done = true);

      await api.push('alpha', nodeId());
      await pumpEventQueue();

      await api.delete('alpha');
      await pumpEventQueue();
      expect(done, isTrue,
          reason: 'delete must close the per-stack StreamController');

      await sub.cancel();
      await api.close();
    });

    // ─── 8. close() closes all streams ─────────────────────────────

    test('close() closes every per-stack stream — onDone fires for all',
        () async {
      final api = buildApi();
      await api.create(decl('alpha'));
      await api.create(decl('beta'));

      var alphaDone = false;
      var betaDone = false;
      final subA =
          api.events('alpha').listen((_) {}, onDone: () => alphaDone = true);
      final subB =
          api.events('beta').listen((_) {}, onDone: () => betaDone = true);

      // Force the controllers to exist (events() is lazy on
      // putIfAbsent but the subscription above triggered the mint).
      await api.push('alpha', nodeId());
      await api.push('beta', nodeId());
      await pumpEventQueue();

      await api.close();
      await pumpEventQueue();
      expect(alphaDone, isTrue);
      expect(betaDone, isTrue);

      await subA.cancel();
      await subB.cancel();
    });

    // ─── 9. events() after close() throws ──────────────────────────

    test('events() after close() throws StateError', () async {
      final api = buildApi();
      await api.close();
      expect(() => api.events('alpha'), throwsA(isA<StateError>()));
    });
  });
}
