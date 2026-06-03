// Q-A.87.9 — Stack* events bridge to BOTH observability streams.
//
// `memory_specification.md` § 16 lists `StackPushed`, `StackPopped`,
// and `StackOverflowDemoted` as `MemoryEvent` subtypes — i.e. they
// must appear on the global `events()` stream (the operator's single
// "what is happening inside memory" feed). The per-stack
// `events(name)` stream additionally carries the narrower
// `StackEvent` shape for subscribers that only care about one stack.
//
// Both audiences exist, so a single push / pop / overflow emits
// twice: once as a typed `MemoryEvent` on the global sink, once as a
// `StackEvent` on the per-stack broadcast. A40 / A42 / A44 exercise
// each emission point in isolation; this file pins the *bridge
// contract* — that one call lands on both streams at once, with the
// same identifying payload — in one place, so a future refactor that
// drops either side fails here.
//
// The per-stack `StackEvent` is only added when the stream has a
// listener (`_emitStackEvent` gates on `hasListener`); the global
// sink is unconditional. Each test therefore subscribes first.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('Q-A.87.9 Stack* events bridge to both streams', () {
    late Database db;
    late List<MemoryEvent> globalEvents;
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
      var entrySeed = 5000;
      var stackNodeSeed = 9000;
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
        eventSink: globalEvents.add,
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      globalEvents = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 0;
    });

    tearDown(() {
      db.dispose();
    });

    StackDecl decl({
      String name = 'open_questions',
      required StackPolicy policy,
    }) =>
        StackDecl(
          name: name,
          summary: 'Q-A.87.9 fixture stack',
          policy: policy,
          entryNodeType: 'Question',
        );

    const fifoUnbounded = StackPolicy(
      priority: PriorityPolicyKind.fifo,
      retention: RetentionPolicyKind.unbounded,
    );

    test('push lands StackPushed on the global sink AND a pushed '
        'StackEvent on the per-stack stream, keyed to the same entry',
        () async {
      final api = buildApi();
      await api.create(decl(policy: fifoUnbounded));

      final perStack = <StackEvent>[];
      final sub = api.events('open_questions').listen(perStack.add);

      final node = nodeId();
      final id = await api.push('open_questions', node, priority: 2.0);
      await pumpEventQueue();

      // Global stream: exactly one StackPushed for this entry.
      final pushed = globalEvents.whereType<StackPushed>().single;
      expect(pushed.stackName, equals('open_questions'));
      expect(pushed.entryId, equals(id));
      expect(pushed.nodeId, equals(node));

      // Per-stack stream: exactly one pushed StackEvent for the same
      // entry — the two streams agree.
      expect(perStack, hasLength(1));
      expect(perStack.single.kind, equals(StackEventKind.pushed));
      expect(perStack.single.stackName, equals('open_questions'));
      expect(perStack.single.entryId, equals(id));

      await sub.cancel();
    });

    test('pop lands StackPopped on the global sink AND a popped '
        'StackEvent on the per-stack stream, keyed to the same entry',
        () async {
      final api = buildApi();
      await api.create(decl(policy: fifoUnbounded));
      final node = nodeId();
      final pushedId = await api.push('open_questions', node);

      // Subscribe after the push so only the pop event is observed on
      // the per-stack stream (broadcast: no replay of history).
      final perStack = <StackEvent>[];
      final sub = api.events('open_questions').listen(perStack.add);
      globalEvents.clear();

      final popped = await api.pop('open_questions');
      await pumpEventQueue();

      expect(popped, isNotNull);
      expect(popped!.id, equals(pushedId));

      // Global stream.
      final popEvent = globalEvents.whereType<StackPopped>().single;
      expect(popEvent.stackName, equals('open_questions'));
      expect(popEvent.entryId, equals(pushedId));
      expect(popEvent.nodeId, equals(node));

      // Per-stack stream.
      expect(perStack, hasLength(1));
      expect(perStack.single.kind, equals(StackEventKind.popped));
      expect(perStack.single.entryId, equals(pushedId));

      await sub.cancel();
    });

    test('a retention overflow lands StackOverflowDemoted on the global '
        'sink AND an overflowDemoted StackEvent on the per-stack stream, '
        'carrying the same demoted ids', () async {
      final api = buildApi();
      // bounded_n, maxCount 1, priority policy: the second push drives
      // the active count to 2 and demotes one entry.
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 1,
          ),
        ),
      );

      final perStack = <StackEvent>[];
      final sub = api.events('open_questions').listen(perStack.add);

      // First push fits under the bound — no overflow.
      await api.push('open_questions', nodeId(), priority: 5.0);
      await pumpEventQueue();
      expect(globalEvents.whereType<StackOverflowDemoted>(), isEmpty);
      expect(
        perStack.where((e) => e.kind == StackEventKind.overflowDemoted),
        isEmpty,
      );

      // Second push overflows the bound (active 2 > maxCount 1).
      await api.push('open_questions', nodeId(), priority: 1.0);
      await pumpEventQueue();

      // Global stream: exactly one StackOverflowDemoted with a
      // non-empty victim list.
      final demoted =
          globalEvents.whereType<StackOverflowDemoted>().single;
      expect(demoted.stackName, equals('open_questions'));
      expect(demoted.demotedIds, isNotEmpty);

      // Per-stack stream: exactly one overflowDemoted StackEvent
      // carrying the identical victim list.
      final perStackOverflow = perStack
          .where((e) => e.kind == StackEventKind.overflowDemoted)
          .toList();
      expect(perStackOverflow, hasLength(1));
      expect(
        perStackOverflow.single.demotedIds,
        equals(demoted.demotedIds),
      );

      await sub.cancel();
    });

    test('the same push reaches a global observer and a per-stack '
        'observer simultaneously (no either-or routing)', () async {
      final api = buildApi();
      await api.create(decl(policy: fifoUnbounded));

      final perStack = <StackEvent>[];
      final sub = api.events('open_questions').listen(perStack.add);

      final id = await api.push('open_questions', nodeId());
      await pumpEventQueue();

      final globalPushed = globalEvents.whereType<StackPushed>().single;
      expect(perStack, hasLength(1));
      // Both streams reference the one entry the single call produced.
      expect(globalPushed.entryId, equals(id));
      expect(perStack.single.entryId, equals(id));

      await sub.cancel();
    });
  });
}
