// A.42 — retention policy conformance test for SqliteStackApi.
//
// Tests `unbounded`, `bounded_n`, and `bounded_age` retention per
// `memory_specification.md` § 5.3, exercised through the abstract
// `StackApi` surface (anyone re-implementing the api must keep this
// suite green).
//
// Coverage map:
//
//   Unbounded
//   ---------
//   * Pushing many entries never archives; `streamArchived` stays
//     empty; no `StackOverflowDemoted` event ever fires.
//
//   bounded_n (FIFO priority)
//   -------------------------
//   * Pushing the (N+1)th entry archives one — under FIFO the
//     just-pushed entry is the lowest priority, so the new entry is
//     itself archived. `peek` still returns the original N.
//
//   bounded_n (priority policy)
//   ---------------------------
//   * After filling above N, the lowest-priority entries are
//     archived; `peek` returns the top N by priority; ties broken
//     by FIFO (older survives) per the inverse of the peek order.
//   * Multiple pushes that each cross the bound each emit one
//     `StackOverflowDemoted` event carrying the demoted ids.
//   * The membership row is flipped to `archived` (not deleted) and
//     the referenced `nodes` row is untouched.
//
//   bounded_n (time_decayed_priority)
//   ----------------------------------
//   * Demotion picks the entry with the lowest effective score
//     (raw × decay), proving the bottom selector uses the same
//     evaluator as the peek path.
//
//   bounded_age
//   -----------
//   * Pushing past `maxAgeMs` archives every active entry older
//     than `at − maxAgeMs`; `peek` returns only the survivors.
//   * Sweep runs on every push, not on a timer: a stack that is
//     never pushed-to keeps stale active entries.
//
//   streamArchived
//   --------------
//   * Returns archived entries ordered by archival time descending.
//   * `limit` caps the row count.
//   * `StackNotFound` for an unknown stack.
//   * Empty stream when no archivals have happened.
//
//   Per-stack overflow StackEvent
//   -----------------------------
//   * `events(name)` carries a `overflowDemoted` event after the
//     `pushed` event for the same push, with the demoted ids
//     populated (single batch).
//
//   Invariant: demotion never deletes
//   ---------------------------------
//   * After a `bounded_n` overflow archives an entry, the
//     underlying `nodes` row is untouched (verified by hand-rolled
//     `nodes` rows and a direct SQL select).
//   * `update(..., status: active)` re-activates an archived entry
//     and it re-appears in `peek`.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('A.42 SqliteStackApi retention policies', () {
    late Database db;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int idCounter;

    NodeId nodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter * 7 + i) & 31),
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
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 0;
    });

    tearDown(() {
      db.dispose();
    });

    StackDecl decl({
      String name = 'workbench',
      required StackPolicy policy,
      String entryNodeType = 'Question',
    }) =>
        StackDecl(
          name: name,
          summary: 'A.42 test stack',
          policy: policy,
          entryNodeType: entryNodeType,
        );

    // ─── Unbounded ──────────────────────────────────────────────

    test('unbounded never archives, never emits overflow', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      for (var i = 0; i < 50; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 5));
        await api.push('workbench', nodeId(), priority: i.toDouble());
      }
      expect(await api.peek('workbench', k: 1000), hasLength(50));
      expect(events.whereType<StackOverflowDemoted>(), isEmpty);
      expect(await api.streamArchived('workbench').toList(), isEmpty);
    });

    // ─── bounded_n + FIFO ────────────────────────────────────────

    test('bounded_n + fifo: the (N+1)th push archives itself', () async {
      // FIFO ranks oldest = highest priority. The "lowest priority"
      // entry is therefore the newest — i.e. the entry we just
      // pushed. This is the spec's literal reading; § 5.3 archives
      // "lowest-priority entries" without exempting fresh arrivals.
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 3,
          ),
        ),
      );
      final originals = <NodeId>[];
      for (var i = 0; i < 3; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        final n = nodeId();
        originals.add(n);
        await api.push('workbench', n);
      }
      // Stack is at capacity; the next push overflows.
      fakeNow = fakeNow.add(const Duration(milliseconds: 10));
      final overflow = nodeId();
      await api.push('workbench', overflow);

      final peek = await api.peek('workbench', k: 10);
      expect(
        peek.map((e) => e.nodeId).toList(),
        equals(originals),
        reason: 'FIFO survivors are the three oldest',
      );

      final archived =
          await api.streamArchived('workbench').toList();
      expect(archived, hasLength(1));
      expect(archived.single.nodeId, equals(overflow));
      expect(archived.single.status, equals(StackEntryStatus.archived));

      final overflowEv =
          events.whereType<StackOverflowDemoted>().single;
      expect(overflowEv.stackName, equals('workbench'));
      expect(overflowEv.demotedIds, hasLength(1));
      expect(overflowEv.kind, equals('memory.stack-overflow-demoted'));
    });

    // ─── bounded_n + priority ────────────────────────────────────

    test(
      'bounded_n + priority: lowest-priority entries are archived',
      () async {
        final api = buildApi();
        await api.create(
          decl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.priority,
              retention: RetentionPolicyKind.boundedN,
              maxCount: 2,
            ),
          ),
        );
        // Push priorities 9, 1, 5, 3. Survivors should be 9 and 5.
        final highest = nodeId();
        await api.push('workbench', highest, priority: 9.0);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        final lowest = nodeId();
        await api.push('workbench', lowest, priority: 1.0);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        // First overflow: stack now {9, 1, 5} → archive priority 1.
        final mid = nodeId();
        await api.push('workbench', mid, priority: 5.0);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        // Second overflow: stack now {9, 5, 3} → archive priority 3.
        final loMid = nodeId();
        await api.push('workbench', loMid, priority: 3.0);

        final peek = await api.peek('workbench', k: 10);
        expect(
          peek.map((e) => e.nodeId).toList(),
          equals(<NodeId>[highest, mid]),
        );

        final archived =
            await api.streamArchived('workbench').toList();
        // Archived ordered most-recent first: loMid (priority 3),
        // then lowest (priority 1).
        expect(
          archived.map((e) => e.nodeId).toList(),
          equals(<NodeId>[loMid, lowest]),
        );

        // Two overflow events — one per push that crossed the bound.
        final overflowEvents =
            events.whereType<StackOverflowDemoted>().toList();
        expect(overflowEvents, hasLength(2));
        for (final ev in overflowEvents) {
          expect(ev.demotedIds, hasLength(1));
        }
      },
    );

    test(
      'bounded_n + priority: tied-lowest priority — newer goes first',
      () async {
        // Spec § 5.3 says "lowest-priority". Among ties at the same
        // raw priority, the peek order prefers the older entry, so
        // the newer entry is "below" it in peek ordering and gets
        // archived first.
        final api = buildApi();
        await api.create(
          decl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.priority,
              retention: RetentionPolicyKind.boundedN,
              maxCount: 2,
            ),
          ),
        );
        final highA = nodeId();
        await api.push('workbench', highA, priority: 5.0);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        final lowOlder = nodeId();
        await api.push('workbench', lowOlder, priority: 1.0);
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        // Pushing a tied-low entry: stack is {high=5, lowOlder=1,
        // lowNewer=1} → archive lowNewer (newer of the two ties).
        final lowNewer = nodeId();
        await api.push('workbench', lowNewer, priority: 1.0);

        final peek = await api.peek('workbench', k: 10);
        expect(
          peek.map((e) => e.nodeId).toList(),
          equals(<NodeId>[highA, lowOlder]),
        );

        final archived =
            await api.streamArchived('workbench').toList();
        expect(archived.map((e) => e.nodeId).toList(),
            equals(<NodeId>[lowNewer]));
      },
    );

    test(
      'bounded_n + time_decayed_priority: lowest effective score archived',
      () async {
        // halflife 100ms. older = decayed harder; raw 10 pushed at
        // t=0 should be worth ~10*exp(-200/100) = 1.35 at t=200ms,
        // smaller than a freshly-pushed raw 2.0 worth ~2.0.
        final api = buildApi();
        await api.create(
          decl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.timeDecayedPriority,
              retention: RetentionPolicyKind.boundedN,
              maxCount: 1,
              halflifeMs: 100,
            ),
          ),
        );
        final oldHighRaw = nodeId();
        await api.push('workbench', oldHighRaw, priority: 10.0);
        // Advance well past the halflife so decay dominates.
        fakeNow = fakeNow.add(const Duration(milliseconds: 200));
        final freshLowRaw = nodeId();
        await api.push('workbench', freshLowRaw, priority: 2.0);

        // Survivor = entry with higher effective score.
        // oldHighRaw effective = 10 * exp(-2) ≈ 1.35
        // freshLowRaw effective = 2.0 * exp(0) = 2.0 → survivor.
        final peek = await api.peek('workbench', k: 10);
        expect(peek.single.nodeId, equals(freshLowRaw));
        final archived =
            await api.streamArchived('workbench').toList();
        expect(archived.single.nodeId, equals(oldHighRaw));
      },
    );

    // ─── bounded_age ────────────────────────────────────────────

    test('bounded_age: entries older than maxAge are archived on push',
        () async {
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
      final stale1 = nodeId();
      await api.push('workbench', stale1);
      fakeNow = fakeNow.add(const Duration(milliseconds: 200));
      final stale2 = nodeId();
      await api.push('workbench', stale2);
      // Advance past the age bound; both above are now stale.
      fakeNow = fakeNow.add(const Duration(milliseconds: 1500));
      final fresh = nodeId();
      await api.push('workbench', fresh);

      final peek = await api.peek('workbench', k: 10);
      expect(peek.map((e) => e.nodeId).toList(), equals(<NodeId>[fresh]));

      final archived =
          await api.streamArchived('workbench').toList();
      // Both stale entries archived in a single sweep — ordered by
      // archival time DESC then id ASC; same archival timestamp so
      // id ASC determines order.
      expect(archived.map((e) => e.nodeId).toSet(),
          equals(<NodeId>{stale1, stale2}));

      final overflowEv =
          events.whereType<StackOverflowDemoted>().single;
      expect(overflowEv.demotedIds, hasLength(2));
    });

    test('bounded_age: no push, no sweep — stale entries stay active',
        () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.boundedAge,
            maxAgeMs: 100,
          ),
        ),
      );
      final n = nodeId();
      await api.push('workbench', n);
      fakeNow = fakeNow.add(const Duration(milliseconds: 5000));
      // Despite time advancing past maxAge, no push has run so no
      // sweep has happened. The active row is still there.
      expect(await api.peek('workbench', k: 10), hasLength(1));
      expect(await api.streamArchived('workbench').toList(), isEmpty);
    });

    // ─── streamArchived ─────────────────────────────────────────

    test('streamArchived: limit caps the row count', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 1,
          ),
        ),
      );
      // Push 5 entries; 4 of them get archived.
      for (var i = 0; i < 5; i++) {
        fakeNow = fakeNow.add(const Duration(milliseconds: 10));
        await api.push('workbench', nodeId(),
            priority: (10 - i).toDouble());
      }
      final all = await api.streamArchived('workbench').toList();
      expect(all, hasLength(4));
      final limited = await api.streamArchived('workbench', limit: 2)
          .toList();
      expect(limited, hasLength(2));
      // Limit-0 is honoured as empty (defensive).
      expect(
        await api.streamArchived('workbench', limit: 0).toList(),
        isEmpty,
      );
    });

    test('streamArchived: missing stack → StackNotFound', () async {
      final api = buildApi();
      expect(
        () => api.streamArchived('ghost').toList(),
        throwsA(isA<StackNotFound>()),
      );
    });

    test('streamArchived: empty when nothing was archived', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      await api.push('workbench', nodeId());
      expect(await api.streamArchived('workbench').toList(), isEmpty);
    });

    // ─── Per-stack overflowDemoted event ────────────────────────

    test('events(name) carries pushed then overflowDemoted for the same '
        'push that crosses the bound', () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 1,
          ),
        ),
      );
      final captured = <StackEvent>[];
      final sub = api.events('workbench').listen(captured.add);

      await api.push('workbench', nodeId(), priority: 5.0);
      await api.push('workbench', nodeId(), priority: 1.0);
      await pumpEventQueue();

      // First push: pushed only (no overflow yet).
      // Second push: pushed + overflowDemoted (the just-pushed
      // priority-1 entry is the lowest and gets archived).
      expect(
        captured.map((e) => e.kind).toList(),
        equals(<StackEventKind>[
          StackEventKind.pushed,
          StackEventKind.pushed,
          StackEventKind.overflowDemoted,
        ]),
      );
      final overflow = captured.last;
      expect(overflow.entryId, isNull);
      expect(overflow.demotedIds, hasLength(1));

      await sub.cancel();
    });

    // ─── Non-deleting invariant ─────────────────────────────────

    test(
      'bounded_n overflow archives the membership but leaves the '
      'referenced node row untouched',
      () async {
        final api = buildApi();
        await api.create(
          decl(
            policy: const StackPolicy(
              priority: PriorityPolicyKind.priority,
              retention: RetentionPolicyKind.boundedN,
              maxCount: 1,
            ),
          ),
        );
        final survivor = nodeId();
        final victim = nodeId();

        // Insert real `nodes` rows for both so we can verify the
        // post-archive node count exactly.
        for (final nid in <NodeId>[survivor, victim]) {
          db.execute(
            "INSERT INTO nodes (id, type_name, scope_json, "
            "produced_by, attrs_json, status, created_at_ms, "
            "created_at_iso, updated_at_ms, updated_at_iso, "
            "idempotency_key, embedding_model_id) "
            "VALUES (?, ?, '{}', NULL, '{}', 'active', 0, '', 0, '', "
            "NULL, NULL)",
            <Object?>[nid.toString(), 'Question'],
          );
        }

        await api.push('workbench', survivor, priority: 10.0);
        await api.push('workbench', victim, priority: 1.0);

        // Active peek: only the survivor.
        final peek = await api.peek('workbench', k: 10);
        expect(peek.single.nodeId, equals(survivor));

        // Archive: contains the victim entry.
        final archived =
            await api.streamArchived('workbench').toList();
        expect(archived.single.nodeId, equals(victim));
        expect(
          archived.single.status,
          equals(StackEntryStatus.archived),
        );

        // The `stack_entries` row is still there with status flipped
        // — not deleted.
        final entryRows = db.select(
          'SELECT status FROM stack_entries WHERE entry_node = ?',
          <Object?>[victim.toString()],
        );
        expect(entryRows.single['status'], equals('archived'));

        // The `nodes` row for the victim is unchanged — same row
        // count, same status.
        final nodeRows = db.select(
          'SELECT status FROM nodes WHERE id = ?',
          <Object?>[victim.toString()],
        );
        expect(nodeRows, hasLength(1));
        expect(nodeRows.single['status'], equals('active'));
      },
    );

    test('archived entry can be re-activated via update; peek sees it again',
        () async {
      final api = buildApi();
      await api.create(
        decl(
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.boundedN,
            maxCount: 1,
          ),
        ),
      );
      final survivor = nodeId();
      final victim = nodeId();
      await api.push('workbench', survivor, priority: 10.0);
      await api.push('workbench', victim, priority: 1.0);

      // Confirm archived.
      expect(
        (await api.streamArchived('workbench').toList()).single.nodeId,
        equals(victim),
      );

      // Re-activate. Bump priority so it tops the peek for a clean
      // observation.
      await api.update(
        'workbench',
        victim,
        status: StackEntryStatus.active,
        priority: 20.0,
      );

      final peek = await api.peek('workbench', k: 10);
      expect(peek.map((e) => e.nodeId).toList(),
          equals(<NodeId>[victim, survivor]));
      // Now nothing left in the archive.
      expect(await api.streamArchived('workbench').toList(), isEmpty);
    });
  });
}
