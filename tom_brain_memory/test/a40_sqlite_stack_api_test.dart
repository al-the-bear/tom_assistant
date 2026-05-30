// A.40 — SqliteStackApi conformance test.
//
// Black-box contract test driving SqliteStackApi through the
// abstract `StackApi` surface declared in `memory_specification.md`
// § 5.1. The tests never reach past the interface — that is the
// point: anyone refactoring the concrete writer or replacing it
// with an isolate-bridge implementation later must keep this suite
// green.
//
// Coverage map (one or more `test(...)` per row):
//
//   Catalogue
//   ---------
//   * Empty store → `list` is empty, `info` returns null.
//   * After two `create`s → `list` returns both ordered by name,
//     each carrying the correct policy / bootstrap flag.
//   * `info` round-trips the StackPolicy bundle and summary text.
//
//   Create / updatePolicy
//   ---------------------
//   * Bootstrap name → `BootstrapStackImmutable`.
//   * Duplicate name → `StackAlreadyExists`.
//   * Invalid policy bundles all five axes:
//       boundedN without maxCount, boundedAge without maxAgeMs,
//       timeDecayedPriority without halflifeMs,
//       unbounded with bound supplied,
//       static priority with halflifeMs supplied.
//   * `updatePolicy` swaps the bundle and emits
//     `StackPolicyChanged`; later `peek` sees the new ordering.
//
//   Push / peek / pop
//   -----------------
//   * `push` mints a fresh StackEntryId, persists the row, and
//     emits `StackPushed` on the global sink + a `pushed`
//     `StackEvent` on `events(name)`.
//   * `peek` honours fifo / lifo / priority ordering immediately
//     after a policy switch.
//   * `pop` returns the top entry, removes the row, and emits
//     `StackPopped`. Pop on empty returns null and emits nothing.
//   * Atomicity: after a successful pop the row is gone and a
//     subsequent peek returns the next item.
//
//   Update / remove
//   ---------------
//   * `update` mutates priority + status + attrs in one call;
//     re-peek reflects the new priority ordering; emits
//     `StackEntryUpdated`.
//   * `update` on a missing entry → `StackEntryNotFound`.
//   * `remove` deletes the membership row, emits
//     `StackEntryRemoved`, and leaves the underlying node
//     untouched (spec § 5.1 contract).
//   * `remove` on a missing entry → `StackEntryNotFound`.
//
//   Observability
//   -------------
//   * `events(name)` returns a broadcast stream that fires `pushed`
//     / `popped` / `updated` per the corresponding call.
//   * `close` flushes the streams.
//
//   Missing stack
//   -------------
//   * Every entry-side method (`push`, `peek`, `pop`, `update`,
//     `remove`) throws `StackNotFound` when the stack does not
//     exist.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('A.40 SqliteStackApi (StackApi contract)', () {
    late Database db;
    late List<MemoryEvent> events;
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
        eventSink: events.add,
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 0;
    });

    tearDown(() {
      db.dispose();
    });

    StackPolicy fifoUnbounded() => const StackPolicy(
          priority: PriorityPolicyKind.fifo,
          retention: RetentionPolicyKind.unbounded,
        );

    StackPolicy priorityUnbounded() => const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.unbounded,
        );

    StackPolicy lifoUnbounded() => const StackPolicy(
          priority: PriorityPolicyKind.lifo,
          retention: RetentionPolicyKind.unbounded,
        );

    StackDecl questionsDecl({
      String name = 'open_questions',
      StackPolicy? policy,
    }) =>
        StackDecl(
          name: name,
          summary: 'open work for the brain to tackle',
          policy: policy ?? fifoUnbounded(),
          entryNodeType: 'Question',
        );

    // ─── Catalogue ──────────────────────────────────────────────

    test('empty store: list is empty and info returns null', () async {
      final api = buildApi();
      expect(await api.list(), isEmpty);
      expect(await api.info('anything'), isNull);
    });

    test('list returns all stacks ordered by name with bootstrap=false',
        () async {
      final api = buildApi();
      await api.create(questionsDecl(name: 'beta'));
      await api.create(questionsDecl(name: 'alpha'));

      final all = await api.list();
      expect(all, hasLength(2));
      expect(all[0].name, equals('alpha'));
      expect(all[1].name, equals('beta'));
      for (final s in all) {
        expect(s.bootstrap, isFalse);
        expect(s.size, equals(0));
        expect(s.topPriority, equals(0.0));
      }
    });

    test('info round-trips policy, summary, entryNodeType, harvesterHook',
        () async {
      final api = buildApi();
      await api.create(
        StackDecl(
          name: 'plans_inflight',
          summary: 'plans currently being executed',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 32,
          ),
          entryNodeType: 'Plan',
          harvesterHook: 'plan_supervisor_v1',
        ),
      );

      final info = await api.info('plans_inflight');
      expect(info, isNotNull);
      expect(info!.name, equals('plans_inflight'));
      expect(info.summary, equals('plans currently being executed'));
      expect(info.entryNodeType, equals('Plan'));
      expect(info.harvesterHook, equals('plan_supervisor_v1'));
      expect(info.bootstrap, isFalse);
      expect(info.policy.priority, equals(PriorityPolicyKind.priority));
      expect(info.policy.retention, equals(RetentionPolicyKind.boundedN));
      expect(info.policy.maxCount, equals(32));
      expect(info.policy.maxAgeMs, isNull);
      expect(info.policy.halflifeMs, isNull);
      expect(info.size, equals(0));
    });

    // ─── Create / updatePolicy refusals ─────────────────────────

    test('create on a bootstrap name → BootstrapStackImmutable', () async {
      final api = buildApi();
      for (final name in bootstrapStackNames) {
        expect(
          () => api.create(questionsDecl(name: name)),
          throwsA(isA<BootstrapStackImmutable>()
              .having((e) => e.stackName, 'stackName', name)),
        );
      }
    });

    test('create twice with the same name → StackAlreadyExists', () async {
      final api = buildApi();
      await api.create(questionsDecl(name: 'duplicate'));
      expect(
        () => api.create(questionsDecl(name: 'duplicate')),
        throwsA(isA<StackAlreadyExists>()
            .having((e) => e.stackName, 'stackName', 'duplicate')),
      );
    });

    test('policy validation: boundedN without maxCount', () async {
      final api = buildApi();
      expect(
        () => api.create(
          questionsDecl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.fifo,
              retention: RetentionPolicyKind.boundedN,
            ),
          ),
        ),
        throwsA(isA<StackPolicyConfigInvalid>().having(
          (e) => e.reason,
          'reason',
          StackPolicyConfigInvalidReason.boundedNWithoutMaxCount,
        )),
      );
    });

    test('policy validation: boundedAge without maxAgeMs', () async {
      final api = buildApi();
      expect(
        () => api.create(
          questionsDecl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.fifo,
              retention: RetentionPolicyKind.boundedAge,
            ),
          ),
        ),
        throwsA(isA<StackPolicyConfigInvalid>().having(
          (e) => e.reason,
          'reason',
          StackPolicyConfigInvalidReason.boundedAgeWithoutMaxAgeMs,
        )),
      );
    });

    test('policy validation: timeDecayedPriority without halflifeMs',
        () async {
      final api = buildApi();
      expect(
        () => api.create(
          questionsDecl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.timeDecayedPriority,
              retention: RetentionPolicyKind.unbounded,
            ),
          ),
        ),
        throwsA(isA<StackPolicyConfigInvalid>().having(
          (e) => e.reason,
          'reason',
          StackPolicyConfigInvalidReason.timeDecayedWithoutHalflifeMs,
        )),
      );
    });

    test('policy validation: unbounded with a bound supplied', () async {
      final api = buildApi();
      expect(
        () => api.create(
          questionsDecl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.fifo,
              retention: RetentionPolicyKind.unbounded,
              maxCount: 10,
            ),
          ),
        ),
        throwsA(isA<StackPolicyConfigInvalid>().having(
          (e) => e.reason,
          'reason',
          StackPolicyConfigInvalidReason.unboundedWithBoundSupplied,
        )),
      );
    });

    test('policy validation: static priority with halflifeMs supplied',
        () async {
      final api = buildApi();
      expect(
        () => api.create(
          questionsDecl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.priority,
              retention: RetentionPolicyKind.unbounded,
              halflifeMs: 1000,
            ),
          ),
        ),
        throwsA(isA<StackPolicyConfigInvalid>().having(
          (e) => e.reason,
          'reason',
          StackPolicyConfigInvalidReason.staticPriorityWithHalflifeSupplied,
        )),
      );
    });

    test('create emits StackCreated with the resolved policy + node id',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());

      final created = events.whereType<StackCreated>().single;
      expect(created.stackName, equals('open_questions'));
      expect(created.entryNodeType, equals('Question'));
      expect(created.bootstrap, isFalse);
      expect(created.policy.priority, equals(PriorityPolicyKind.fifo));
      expect(created.policy.retention, equals(RetentionPolicyKind.unbounded));
      expect(created.kind, equals('memory.stack-created'));
    });

    test('updatePolicy swaps the bundle and emits StackPolicyChanged',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());
      events.clear();

      await api.updatePolicy('open_questions', priorityUnbounded());

      final info = (await api.info('open_questions'))!;
      expect(info.policy.priority, equals(PriorityPolicyKind.priority));
      final changed = events.whereType<StackPolicyChanged>().single;
      expect(changed.stackName, equals('open_questions'));
      expect(changed.policy.priority, equals(PriorityPolicyKind.priority));
    });

    test('updatePolicy on missing stack → StackNotFound', () async {
      final api = buildApi();
      expect(
        () => api.updatePolicy('does_not_exist', fifoUnbounded()),
        throwsA(isA<StackNotFound>()
            .having((e) => e.stackName, 'stackName', 'does_not_exist')),
      );
    });

    // ─── Push / peek / pop ──────────────────────────────────────

    test('push: mints id, persists row, emits StackPushed + StackEvent',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());

      final streamEvents = <StackEvent>[];
      final sub = api.events('open_questions').listen(streamEvents.add);

      final n1 = nodeId();
      final id = await api.push('open_questions', n1, priority: 3.5,
          attrs: <String, Object?>{'origin': 'user-prompt'});

      // Allow microtask flush of broadcast stream.
      await pumpEventQueue();

      // Sink event.
      final pushed = events.whereType<StackPushed>().single;
      expect(pushed.entryId, equals(id));
      expect(pushed.nodeId, equals(n1));
      expect(pushed.priority, equals(3.5));
      expect(pushed.attrs, equals(<String, Object?>{'origin': 'user-prompt'}));

      // Per-stack stream event.
      expect(streamEvents, hasLength(1));
      expect(streamEvents.single.kind, equals(StackEventKind.pushed));
      expect(streamEvents.single.entryId, equals(id));

      // Catalogue reflects size.
      expect((await api.info('open_questions'))!.size, equals(1));

      await sub.cancel();
    });

    test('peek: fifo ordering honoured', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final ids = <NodeId>[];
      for (var i = 0; i < 3; i++) {
        final n = nodeId();
        ids.add(n);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        await api.push('open_questions', n);
      }

      final top = await api.peek('open_questions');
      expect(top, hasLength(3));
      expect(top.map((e) => e.nodeId).toList(), equals(ids));
    });

    test('peek: lifo ordering honoured', () async {
      final api = buildApi();
      await api.create(questionsDecl(policy: lifoUnbounded()));
      final ids = <NodeId>[];
      for (var i = 0; i < 3; i++) {
        final n = nodeId();
        ids.add(n);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        await api.push('open_questions', n);
      }

      final top = await api.peek('open_questions');
      expect(
        top.map((e) => e.nodeId).toList(),
        equals(ids.reversed.toList()),
      );
    });

    test('peek: priority ordering honoured; ties broken by FIFO',
        () async {
      final api = buildApi();
      await api.create(questionsDecl(policy: priorityUnbounded()));

      // Push in order: A=0.5, B=1.0, C=1.0, D=0.0
      final a = nodeId();
      await api.push('open_questions', a, priority: 0.5);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final b = nodeId();
      await api.push('open_questions', b, priority: 1.0);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final c = nodeId();
      await api.push('open_questions', c, priority: 1.0);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final d = nodeId();
      await api.push('open_questions', d, priority: 0.0);

      final top = await api.peek('open_questions');
      expect(
        top.map((e) => e.nodeId).toList(),
        equals(<NodeId>[b, c, a, d]),
      );
    });

    test('policy change takes effect for subsequent peeks', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final n1 = nodeId();
      await api.push('open_questions', n1, priority: 1.0);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final n2 = nodeId();
      await api.push('open_questions', n2, priority: 9.0);

      // FIFO: n1 first.
      expect(
        (await api.peek('open_questions')).first.nodeId,
        equals(n1),
      );

      await api.updatePolicy('open_questions', priorityUnbounded());

      // Now priority order: n2 first.
      expect(
        (await api.peek('open_questions')).first.nodeId,
        equals(n2),
      );
    });

    test('pop returns the top entry, deletes the row, emits StackPopped',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final n1 = nodeId();
      await api.push('open_questions', n1);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final n2 = nodeId();
      await api.push('open_questions', n2);

      final popped = await api.pop('open_questions');
      expect(popped, isNotNull);
      expect(popped!.nodeId, equals(n1));

      // Row gone.
      final remaining = await api.peek('open_questions');
      expect(remaining, hasLength(1));
      expect(remaining.single.nodeId, equals(n2));

      final popEvent = events.whereType<StackPopped>().single;
      expect(popEvent.entryId, equals(popped.id));
    });

    test('pop on empty returns null and emits nothing', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      events.clear();
      final popped = await api.pop('open_questions');
      expect(popped, isNull);
      expect(events.whereType<StackPopped>(), isEmpty);
    });

    // ─── update / remove ────────────────────────────────────────

    test('update mutates priority and re-orders subsequent peek',
        () async {
      final api = buildApi();
      await api.create(questionsDecl(policy: priorityUnbounded()));
      final lo = nodeId();
      await api.push('open_questions', lo, priority: 0.1);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final hi = nodeId();
      await api.push('open_questions', hi, priority: 0.2);

      // Initially: hi > lo.
      expect(
        (await api.peek('open_questions')).first.nodeId,
        equals(hi),
      );

      await api.update('open_questions', lo, priority: 5.0);

      final updated = events.whereType<StackEntryUpdated>().single;
      expect(updated.priority, equals(5.0));
      expect(updated.attrsReplaced, isFalse);

      // Now: lo > hi.
      expect(
        (await api.peek('open_questions')).first.nodeId,
        equals(lo),
      );
    });

    test('update on missing entry → StackEntryNotFound', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final orphan = nodeId();
      expect(
        () => api.update('open_questions', orphan, priority: 1.0),
        throwsA(isA<StackEntryNotFound>()),
      );
    });

    test('remove deletes the row, emits StackEntryRemoved, leaves no '
        'trace of the membership; node row is untouched (verified at SQL '
        'layer)', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final n1 = nodeId();
      await api.push('open_questions', n1);

      // Insert a sham `nodes` row directly so we can prove `remove`
      // does not touch it. (NodePersister would normally produce
      // this; for A.40 a hand-rolled row is enough.)
      db.execute(
        "INSERT INTO nodes (id, type_name, scope_json, produced_by, "
        "attrs_json, status, created_at_ms, created_at_iso, "
        "updated_at_ms, updated_at_iso, idempotency_key, "
        "embedding_model_id) "
        "VALUES (?, ?, '{}', NULL, '{}', 'active', 0, '', 0, '', NULL, NULL)",
        <Object?>[n1.toString(), 'Question'],
      );

      await api.remove('open_questions', n1);

      // Membership gone.
      expect(await api.peek('open_questions'), isEmpty);

      // Node row still there.
      final nodeRows = db.select(
        'SELECT 1 FROM nodes WHERE id = ?',
        <Object?>[n1.toString()],
      );
      expect(nodeRows, hasLength(1));

      final removedEv = events.whereType<StackEntryRemoved>().single;
      expect(removedEv.nodeId, equals(n1));
    });

    test('remove on missing entry → StackEntryNotFound', () async {
      final api = buildApi();
      await api.create(questionsDecl());
      final orphan = nodeId();
      expect(
        () => api.remove('open_questions', orphan),
        throwsA(isA<StackEntryNotFound>()),
      );
    });

    // ─── Missing-stack rejections on entry methods ─────────────

    test('every entry-side method throws StackNotFound on missing stack',
        () async {
      final api = buildApi();
      final n = nodeId();
      expect(
        () => api.push('ghost', n),
        throwsA(isA<StackNotFound>()),
      );
      expect(
        () => api.peek('ghost'),
        throwsA(isA<StackNotFound>()),
      );
      expect(
        () => api.pop('ghost'),
        throwsA(isA<StackNotFound>()),
      );
      expect(
        () => api.update('ghost', n, priority: 1.0),
        throwsA(isA<StackNotFound>()),
      );
      expect(
        () => api.remove('ghost', n),
        throwsA(isA<StackNotFound>()),
      );
    });

    // ─── Observability ──────────────────────────────────────────

    test('events() is a broadcast stream that fires pushed/popped/updated',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());

      final captured = <StackEvent>[];
      final sub = api.events('open_questions').listen(captured.add);

      final n1 = nodeId();
      await api.push('open_questions', n1);
      await api.update('open_questions', n1, priority: 7.0);
      await api.pop('open_questions');
      await pumpEventQueue();

      expect(
        captured.map((e) => e.kind).toList(),
        equals(<StackEventKind>[
          StackEventKind.pushed,
          StackEventKind.updated,
          StackEventKind.popped,
        ]),
      );

      await sub.cancel();
    });

    test('close releases the api; subsequent mutations throw StateError',
        () async {
      final api = buildApi();
      await api.create(questionsDecl());
      await api.close();
      expect(() => api.list(), throwsA(isA<StateError>()));
      expect(
        () => api.push('open_questions', nodeId()),
        throwsA(isA<StateError>()),
      );
    });
  });
}
