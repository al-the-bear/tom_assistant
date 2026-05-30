// A.45 — Stack invariants integration test.
//
// `prototype_implementation_plan.md` step A.45 bundles four invariants
// that span A.40–A.44 and must hold together as one contract:
//
//   1. **Atomic push/pop.** A push that triggers retention enforcement
//      commits the INSERT *and* the demotion together — no observer
//      sees `size > maxCount` between the two. A pop is a single
//      read-then-delete transaction — a concurrent peeker either sees
//      the top entry or sees it gone, never a half-consumed row.
//      Interleaved concurrent push/pop sequences leave the catalogue
//      consistent (every popped row was, at some prior point in time,
//      the top of the stack per the policy ordering, and the surviving
//      set is the input set minus the popped set).
//
//   2. **Policy ordering correctness.** Every `peek` ordering through
//      `StackApi` agrees with the pure-function `sortByPolicy` from
//      `priority_policy.dart` on the same input set, for all four
//      `PriorityPolicyKind` variants. This is the bridge test that
//      pins the SQL `ORDER BY` clauses inside `SqliteStackApi` to the
//      canonical evaluator A.41 ships — a future re-implementation of
//      either side must keep both in agreement.
//
//   3. **Overflow demotion does not delete underlying node.** Holds
//      for *every* retention policy that can demote (`bounded_n` and
//      `bounded_age`), across *every* priority policy that drives the
//      victim selection. After demotion the `stack_entries` row is
//      flipped to `archived` (not deleted) and the referenced `nodes`
//      row is byte-identical to its pre-demotion state.
//
//   4. **Bootstrap immutability.** Every one of the six bootstrap
//      stacks (`memory_specification.md` § 5.4) rejects `create` and
//      `delete` with `BootstrapStackImmutable`, while still accepting
//      `push` / `peek` / `pop` / `update` / `remove` (membership ops
//      do not threaten the catalogue invariant — only structural ops
//      do). The bundling property pins what bootstrap immutability
//      *means*: the catalogue identity is fixed, the contents are not.
//
// These properties are individually exercised by A.40–A.44 but A.45
// pins them as a single integration contract — a future refactor that
// satisfies the per-step tests in isolation but breaks the bundle
// would still be caught here.

import 'dart:async';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('A.45 stack invariants (push/pop atomicity, policy ordering, '
      'non-deleting demotion, bootstrap immutability)', () {
    late Database db;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int idCounter;

    NodeId nodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (idCounter * 7 + i) & 31),
      );
    }

    SqliteStackApi buildApi() {
      var entrySeed = 5000;
      var stackNodeSeed = 9000;
      return SqliteStackApi(
        memoryDb: db,
        entryIdMint: () {
          entrySeed += 1;
          return StackEntryId.generate(
            at: fakeNow,
            randomness:
                List<int>.generate(16, (i) => (entrySeed * 11 + i) & 31),
          );
        },
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
      fakeNow = DateTime.utc(2026, 5, 30, 18, 0, 0);
      idCounter = 0;
    });

    tearDown(() {
      db.dispose();
    });

    StackDecl decl({
      String name = 'work',
      required StackPolicy policy,
      String entryNodeType = 'Question',
    }) =>
        StackDecl(
          name: name,
          summary: 'A.45 fixture stack',
          policy: policy,
          entryNodeType: entryNodeType,
        );

    // ─── 1. Atomic push / pop ────────────────────────────────────

    test('atomic push: a push that triggers overflow never leaves the '
        'stack with size > maxCount between INSERT and demotion',
        () async {
      // Strategy: subscribe to the per-stack stream, push past the
      // bound, then snapshot the catalogue size after each completed
      // push. Because push runs inside one synchronous transaction
      // (BEGIN → INSERT → enforce-retention → COMMIT) the observed
      // size after the awaited push must be ≤ maxCount.
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 3,
          ),
        ),
      );

      for (var i = 0; i < 20; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        await api.push('work', nodeId(), priority: i.toDouble());
        final info = (await api.info('work'))!;
        expect(
          info.size,
          lessThanOrEqualTo(3),
          reason: 'push #$i: active size must respect maxCount',
        );
      }

      // Surviving set = top-3 priorities pushed (17, 18, 19).
      final survivors = await api.peek('work', k: 10);
      expect(
        survivors.map((e) => e.priority).toList(),
        equals(<double>[19.0, 18.0, 17.0]),
      );
    });

    test('atomic pop: after a pop the row is gone in the same '
        'transaction — the next peek/pop sees the next entry, never the '
        'same one twice', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      final pushed = <NodeId>[];
      for (var i = 0; i < 10; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        final n = nodeId();
        pushed.add(n);
        await api.push('work', n);
      }

      // Drain the stack by sequential pops. Each pop must return a
      // *new* node id — the read+delete is atomic so no two pops can
      // see the same row.
      final popped = <NodeId>[];
      while (true) {
        final entry = await api.pop('work');
        if (entry == null) break;
        popped.add(entry.nodeId);
      }
      expect(popped, equals(pushed));
      expect(popped.toSet(), hasLength(popped.length),
          reason: 'no duplicate pops');
      expect(await api.peek('work'), isEmpty);
    });

    test('concurrent pops on the same stack drain it without '
        'double-popping any row', () async {
      // Fire many concurrent `pop` futures via `Future.wait`. Even
      // though Dart is single-isolate, each `pop` interleaves at
      // every `await` boundary with the others — if the read+delete
      // were not atomic, two pops could each read the same top row
      // and one would crash on the second DELETE or both would
      // return the same entry. The transactional implementation
      // serialises them via SQLite's connection lock.
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.lifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      final pushed = <NodeId>[];
      for (var i = 0; i < 30; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        final n = nodeId();
        pushed.add(n);
        await api.push('work', n);
      }

      final futures =
          List<Future<StackEntry?>>.generate(40, (_) => api.pop('work'));
      final results = await Future.wait(futures);
      final popped = results
          .whereType<StackEntry>()
          .map((e) => e.nodeId)
          .toList();
      final nulls = results.where((r) => r == null).length;

      expect(popped, hasLength(30));
      expect(nulls, equals(10),
          reason: 'extra pops past the available count return null');
      expect(popped.toSet(), hasLength(30),
          reason: 'no row was popped twice');
      expect(popped.toSet(), equals(pushed.toSet()),
          reason: 'every pushed row was popped exactly once');
      expect(await api.peek('work'), isEmpty);
    });

    test('interleaved concurrent push + pop on the same stack '
        'preserves the conservation invariant (final_active = pushed − popped)',
        () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );

      // Pre-seed so early pops have something to take.
      for (var i = 0; i < 10; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        await api.push('work', nodeId());
      }

      // Mix pushes and pops in a single Future.wait so the event
      // loop interleaves them. Each push advances `fakeNow` so id
      // generation stays unique.
      final ops = <Future<Object?>>[];
      for (var i = 0; i < 40; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        ops.add(api.push('work', nodeId()));
      }
      for (var i = 0; i < 25; i++) {
        ops.add(api.pop('work'));
      }
      final results = await Future.wait(ops);

      final poppedNonNull =
          results.whereType<StackEntry>().toList();
      expect(poppedNonNull, hasLength(25),
          reason:
              '10 pre-seeded + 40 pushed = 50 ≥ 25 pops, all should return a row');

      // Conservation: 10 pre-seeded + 40 pushed − 25 popped = 25.
      final survivors = await api.peek('work', k: 1000);
      expect(survivors, hasLength(25));
      expect(events.whereType<StackPushed>(), hasLength(50));
      expect(events.whereType<StackPopped>(), hasLength(25));
    });

    // ─── 2. Policy ordering correctness ──────────────────────────

    test('peek ordering matches sortByPolicy for fifo / lifo / priority / '
        'timeDecayedPriority on the same data set', () async {
      // Build one stack per policy, push the same logical set of
      // entries, then assert that `peek(k=all)` returns the same id
      // sequence as `sortByPolicy(<all entries>, <policy>)`.

      final basePushes = <_PushSpec>[];
      // Vary both priorities and pushed-at timestamps so all four
      // policies have something to discriminate on.
      for (var i = 0; i < 12; i++) {
        basePushes.add(
          _PushSpec(
            offsetMs: i * 17, // unique pushed-at per entry
            priority: ((i * 7) % 9).toDouble(),
          ),
        );
      }

      Future<void> runOne(StackPolicy policy, String stackName) async {
        final api = buildApi();
        await api.create(decl(name: stackName, policy: policy));
        final localStartNow = fakeNow;
        final apiEntries = <StackEntry>[];
        for (final spec in basePushes) {
          fakeNow = localStartNow.add(Duration(milliseconds: spec.offsetMs));
          final node = nodeId();
          final id = await api.push(
            stackName,
            node,
            priority: spec.priority,
          );
          apiEntries.add(
            StackEntry(
              id: id,
              stackName: stackName,
              nodeId: node,
              priority: spec.priority,
              pushedAt: fakeNow,
            ),
          );
        }

        // Use a fixed "now" for the comparison so the
        // time-decayed evaluator sees the same Δt as the api will.
        // Advance fakeNow so any decay actually bites.
        fakeNow = localStartNow.add(const Duration(seconds: 5));
        final apiOrder = await api.peek(stackName, k: 100);
        final expected = sortByPolicy(apiEntries, policy, now: fakeNow);

        expect(
          apiOrder.map((e) => e.id.toString()).toList(),
          equals(expected.map((e) => e.id.toString()).toList()),
          reason: 'peek ordering disagrees with sortByPolicy for ${policy.priority.name}',
        );
        await api.close();
      }

      await runOne(
        const StackPolicy(
          priority: PriorityPolicyKind.fifo,
          retention: RetentionPolicyKind.unbounded,
        ),
        'fifo_stack',
      );
      await runOne(
        const StackPolicy(
          priority: PriorityPolicyKind.lifo,
          retention: RetentionPolicyKind.unbounded,
        ),
        'lifo_stack',
      );
      await runOne(
        const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.unbounded,
        ),
        'priority_stack',
      );
      await runOne(
        const StackPolicy(
          priority: PriorityPolicyKind.timeDecayedPriority,
          retention: RetentionPolicyKind.unbounded,
          halflifeMs: 500,
        ),
        'decayed_stack',
      );
    });

    test('mid-life policy change: ordering switches on the next peek '
        'without any push/pop in between', () async {
      // The spec says policy changes "take effect for subsequent
      // peek / pop calls". Pin that property: change the policy, do
      // nothing else, then verify the read order flipped.
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      final old = nodeId();
      await api.push('work', old, priority: 1.0);
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final young = nodeId();
      await api.push('work', young, priority: 9.0);

      // FIFO: old comes first.
      expect((await api.peek('work')).first.nodeId, equals(old));
      // LIFO: young comes first.
      await api.updatePolicy(
        'work',
        const StackPolicy(
          priority: PriorityPolicyKind.lifo,
          retention: RetentionPolicyKind.unbounded,
        ),
      );
      expect((await api.peek('work')).first.nodeId, equals(young));
      // Priority: young (9.0) outranks old (1.0).
      await api.updatePolicy(
        'work',
        const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.unbounded,
        ),
      );
      expect((await api.peek('work')).first.nodeId, equals(young));
    });

    // ─── 3. Overflow demotion does not delete underlying node ────

    test('bounded_n overflow under every priority policy: archived '
        'entry stays as an `archived` membership row and its referenced '
        'nodes row is byte-identical to the pre-demotion state', () async {
      // Run the invariant under all four priority policies. For each
      // policy:
      //   - Pre-insert `nodes` rows so we can snapshot the column
      //     values before any push.
      //   - Push past the bound; one entry is archived per overflow.
      //   - Assert: the membership row exists with status='archived'
      //     and the `nodes` row column-by-column matches the
      //     pre-push snapshot.
      Future<void> runFor(StackPolicy policy, String stackName) async {
        final api = buildApi();
        await api.create(decl(name: stackName, policy: policy));

        final winner = nodeId();
        final loser = nodeId();

        // Insert `nodes` rows for both so we can snapshot.
        for (final nid in <NodeId>[winner, loser]) {
          db.execute(
            "INSERT INTO nodes (id, type_name, scope_json, "
            "produced_by, attrs_json, status, created_at_ms, "
            "created_at_iso, updated_at_ms, updated_at_iso, "
            "idempotency_key, embedding_model_id) "
            "VALUES (?, 'Question', '{}', NULL, "
            "'{\"k\":\"v\"}', 'active', 12345, '2026-05-30T18:00:00Z', "
            "12345, '2026-05-30T18:00:00Z', NULL, NULL)",
            <Object?>[nid.toString()],
          );
        }

        // Snapshot both nodes rows pre-push.
        Map<String, Object?> snap(NodeId nid) => Map<String, Object?>.from(
              db.select(
                'SELECT * FROM nodes WHERE id = ?',
                <Object?>[nid.toString()],
              ).first,
            );
        final winnerSnap = snap(winner);
        final loserSnap = snap(loser);

        // For static priority policies the lower-priority entry
        // loses. For fifo, the just-pushed second entry is the
        // newest = lowest fifo rank, so it loses. For lifo, the
        // first entry is now the oldest = lowest lifo rank, so it
        // loses. For time-decayed, the older raw-equal entry has
        // a smaller effective score and loses.
        switch (policy.priority) {
          case PriorityPolicyKind.fifo:
            // First pushed survives (oldest = top of FIFO). Second
            // pushed is the loser (newest = bottom of FIFO).
            await api.push(stackName, winner);
            fakeNow = fakeNow.add(const Duration(milliseconds: 1));
            await api.push(stackName, loser);
          case PriorityPolicyKind.lifo:
            // Newest = top of LIFO survives. Loser pushed first.
            await api.push(stackName, loser);
            fakeNow = fakeNow.add(const Duration(milliseconds: 1));
            await api.push(stackName, winner);
          case PriorityPolicyKind.priority:
            await api.push(stackName, winner, priority: 10.0);
            fakeNow = fakeNow.add(const Duration(milliseconds: 1));
            await api.push(stackName, loser, priority: 1.0);
          case PriorityPolicyKind.timeDecayedPriority:
            // Push loser first with a small raw priority, then
            // advance well past the halflife and push winner with
            // higher raw. Loser's effective ≪ winner's.
            await api.push(stackName, loser, priority: 1.0);
            fakeNow = fakeNow.add(const Duration(milliseconds: 1000));
            await api.push(stackName, winner, priority: 5.0);
        }

        // The surviving entry should be the winner.
        final peek = await api.peek(stackName, k: 10);
        expect(peek.map((e) => e.nodeId).toList(), equals(<NodeId>[winner]),
            reason:
                'survivor mismatch for ${policy.priority.name}: peek=$peek');

        // The archived entry should be the loser; membership row
        // present with status='archived' (NOT deleted).
        final archivedRows = db.select(
          "SELECT entry_node, status FROM stack_entries "
          "WHERE stack_name = ? AND status = 'archived'",
          <Object?>[stackName],
        );
        expect(archivedRows, hasLength(1));
        expect(
          archivedRows.single['entry_node'],
          equals(loser.toString()),
          reason:
              'archived membership row missing for ${policy.priority.name}',
        );

        // Both `nodes` rows are byte-identical to their pre-push
        // snapshot. Demotion is a membership-only operation.
        expect(snap(winner), equals(winnerSnap));
        expect(snap(loser), equals(loserSnap));

        await api.close();
      }

      await runFor(
        const StackPolicy(
          priority: PriorityPolicyKind.fifo,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 1,
        ),
        'fifo_bn',
      );
      await runFor(
        const StackPolicy(
          priority: PriorityPolicyKind.lifo,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 1,
        ),
        'lifo_bn',
      );
      await runFor(
        const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 1,
        ),
        'pri_bn',
      );
      await runFor(
        const StackPolicy(
          priority: PriorityPolicyKind.timeDecayedPriority,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 1,
          halflifeMs: 100,
        ),
        'dec_bn',
      );
    });

    test('bounded_age overflow: archived entry stays as an `archived` '
        'membership row and its referenced nodes row is byte-identical '
        'to the pre-demotion state', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.boundedAge,
            maxAgeMs: 1000,
          ),
        ),
      );
      final stale = nodeId();
      final fresh = nodeId();

      // Real nodes rows for both.
      for (final nid in <NodeId>[stale, fresh]) {
        db.execute(
          "INSERT INTO nodes (id, type_name, scope_json, "
          "produced_by, attrs_json, status, created_at_ms, "
          "created_at_iso, updated_at_ms, updated_at_iso, "
          "idempotency_key, embedding_model_id) "
          "VALUES (?, 'Question', '{}', NULL, "
          "'{\"k\":\"v\"}', 'active', 12345, '2026-05-30T18:00:00Z', "
          "12345, '2026-05-30T18:00:00Z', NULL, NULL)",
          <Object?>[nid.toString()],
        );
      }
      Map<String, Object?> snap(NodeId nid) => Map<String, Object?>.from(
            db.select(
              'SELECT * FROM nodes WHERE id = ?',
              <Object?>[nid.toString()],
            ).first,
          );
      final staleSnap = snap(stale);
      final freshSnap = snap(fresh);

      await api.push('work', stale);
      fakeNow = fakeNow.add(const Duration(milliseconds: 2000));
      await api.push('work', fresh);

      // `stale` is now archived; `fresh` survives.
      expect(
        (await api.peek('work', k: 10)).map((e) => e.nodeId).toList(),
        equals(<NodeId>[fresh]),
      );

      final archivedRows = db.select(
        "SELECT entry_node, status FROM stack_entries "
        "WHERE stack_name = 'work' AND status = 'archived'",
      );
      expect(archivedRows, hasLength(1));
      expect(
        archivedRows.single['entry_node'],
        equals(stale.toString()),
      );

      // Both nodes byte-identical.
      expect(snap(stale), equals(staleSnap));
      expect(snap(fresh), equals(freshSnap));
    });

    test('archived membership row count matches StackOverflowDemoted '
        'event totals across a bounded_n burst', () async {
      // Cross-check the typed event stream against the SQL truth.
      // The two must agree or downstream consumers (operator UI,
      // run recorder) will get a different picture from each.
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 3,
          ),
        ),
      );

      for (var i = 0; i < 20; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        await api.push('work', nodeId(), priority: i.toDouble());
      }

      final emittedDemoted = events
          .whereType<StackOverflowDemoted>()
          .expand((e) => e.demotedIds)
          .toSet();

      final archivedFromDb = db
          .select(
            "SELECT id FROM stack_entries "
            "WHERE stack_name = 'work' AND status = 'archived'",
          )
          .map((r) => r['id'] as String)
          .toSet();

      expect(
        emittedDemoted.map((id) => id.toString()).toSet(),
        equals(archivedFromDb),
        reason:
            'StackOverflowDemoted event ids must equal archived '
            'membership row ids; otherwise observers and SQL truth '
            'disagree',
      );
    });

    // ─── 4. Bootstrap immutability ───────────────────────────────

    test('every bootstrap stack rejects create AND delete, but accepts '
        'push / peek / pop / update / remove', () async {
      // Install the bootstrap catalogue first.
      var stackNodeSeed = 10000;
      installBootstrapStacks(
        db,
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
      final api = buildApi();

      for (final name in bootstrapStackNames) {
        // 4a. create rejected.
        await expectLater(
          () => api.create(
            StackDecl(
              name: name,
              summary: 'illegal',
              policy: const StackPolicy(
                priority: PriorityPolicyKind.fifo,
                retention: RetentionPolicyKind.unbounded,
              ),
              entryNodeType: 'Question',
            ),
          ),
          throwsA(isA<BootstrapStackImmutable>()
              .having((e) => e.stackName, 'stackName', name)),
          reason: 'bootstrap "$name" must reject create',
        );

        // 4b. delete rejected.
        await expectLater(
          () => api.delete(name),
          throwsA(isA<BootstrapStackImmutable>()
              .having((e) => e.stackName, 'stackName', name)),
          reason: 'bootstrap "$name" must reject delete',
        );

        // 4c. content-mutating ops still work — the immutability is
        // about the catalogue identity, not the contents.
        final n = nodeId();
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        await api.push(name, n, priority: 1.0);
        final peek = await api.peek(name, k: 10);
        expect(peek.map((e) => e.nodeId), contains(n),
            reason: 'bootstrap "$name" must accept push + peek');

        await api.update(name, n, priority: 7.0);
        await api.remove(name, n);
        // After remove the entry is gone — no exception either way.
        final after = await api.peek(name, k: 10);
        expect(after.map((e) => e.nodeId), isNot(contains(n)));
      }

      // Catalogue intact — six bootstrap rows, none were deleted by
      // any of the rejected delete calls.
      final count =
          db.select('SELECT COUNT(*) AS c FROM stacks').first;
      expect(count['c'], equals(6),
          reason: 'no bootstrap row was deleted by a rejected call');
    });

    test('rejected create / delete on a bootstrap stack leaves the '
        'catalogue exactly as the installer left it (no partial writes)',
        () async {
      // Capture a complete snapshot of the catalogue + canonical Stack
      // nodes after install, attempt every illegal mutation on every
      // bootstrap name, and confirm the snapshot is unchanged.
      var stackNodeSeed = 22000;
      installBootstrapStacks(
        db,
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
      final stacksBefore = db
          .select('SELECT * FROM stacks ORDER BY name')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final stackNodesBefore = db
          .select(
            "SELECT * FROM nodes WHERE type_name = 'Stack' "
            "ORDER BY idempotency_key",
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList();

      final api = buildApi();
      for (final name in bootstrapStackNames) {
        await expectLater(
          () => api.create(
            StackDecl(
              name: name,
              summary: 'illegal',
              policy: const StackPolicy(
                priority: PriorityPolicyKind.priority,
                retention: RetentionPolicyKind.unbounded,
              ),
              entryNodeType: 'Question',
            ),
          ),
          throwsA(isA<BootstrapStackImmutable>()),
        );
        await expectLater(
          () => api.delete(name),
          throwsA(isA<BootstrapStackImmutable>()),
        );
      }

      final stacksAfter = db
          .select('SELECT * FROM stacks ORDER BY name')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final stackNodesAfter = db
          .select(
            "SELECT * FROM nodes WHERE type_name = 'Stack' "
            "ORDER BY idempotency_key",
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList();

      expect(stacksAfter, equals(stacksBefore),
          reason: 'stacks catalogue must be untouched');
      expect(stackNodesAfter, equals(stackNodesBefore),
          reason: 'canonical Stack nodes must be untouched');
    });
  });
}

/// One push spec used by the `peek == sortByPolicy` test. Bundles
/// the fields that determine an entry's ordering position so the
/// fixture is readable in one glance.
class _PushSpec {
  final int offsetMs;
  final double priority;

  const _PushSpec({required this.offsetMs, required this.priority});
}
