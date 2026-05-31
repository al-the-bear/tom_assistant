// A.43 — bootstrap stacks installer + delete-immutability tests.
//
// Covers the contract added by Plan step A.43:
//
//   * `installBootstrapStacks` mints the six reserved stacks from
//     `memory_specification.md` § 5.4 on first call, with the exact
//     policies in the spec table and `is_bootstrap = 1` on every
//     row.
//   * The installer is idempotent — a second call against the same
//     DB is a no-op (no inserts, no events).
//   * Each bootstrap stack rejects `delete()` with
//     `BootstrapStackImmutable`.
//   * Each bootstrap stack still rejects `create()` with
//     `BootstrapStackImmutable` (the spec § 5.4 reservation pre-
//     existed at A.40 — A.43 verifies it stays true after the
//     installer ran).
//   * Non-bootstrap stacks can be created and deleted normally;
//     `delete()` on a missing stack throws `StackNotFound`;
//     `delete()` cascades the stack's `stack_entries` rows and the
//     canonical `Stack` node.
//   * The canonical bootstrap-spec list and the rejection set agree
//     on names (assertion baked into the installer; this test
//     reaches it via the first call).

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

void main() {
  group('A.43 installBootstrapStacks', () {
    late Database db;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int nodeIdSeed;

    NodeId mintStackNodeId() {
      nodeIdSeed += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (nodeIdSeed * 13 + i) & 31),
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 16, 0, 0);
      nodeIdSeed = 0;
    });

    tearDown(() => db.dispose());

    // ─── Spec list shape ─────────────────────────────────────────

    test('bootstrapStackSpecs has exactly six entries with unique names',
        () {
      expect(bootstrapStackSpecs, hasLength(6));
      final names = bootstrapStackSpecs.map((s) => s.name).toSet();
      expect(names, hasLength(6));
      expect(
        names,
        equals(<String>{
          'questions_open',
          'automation_ideas',
          'interests',
          'inflight',
          'recent_runs',
          'restructure_backlog',
        }),
      );
    });

    test('spec policies match memory_specification.md § 5.4', () {
      final byName = <String, BootstrapStackSpec>{
        for (final s in bootstrapStackSpecs) s.name: s,
      };
      const dayMs = 24 * 60 * 60 * 1000;

      // 1. questions_open: priority / unbounded / Question
      final qo = byName['questions_open']!;
      expect(qo.entryNodeType, equals('Question'));
      expect(qo.policy.priority, equals(PriorityPolicyKind.priority));
      expect(qo.policy.retention, equals(RetentionPolicyKind.unbounded));
      expect(qo.policy.maxCount, isNull);
      expect(qo.policy.halflifeMs, isNull);

      // 2. automation_ideas: timeDecayedPriority(30d) / boundedN(1000)
      final ai = byName['automation_ideas']!;
      expect(ai.entryNodeType, equals('AutomationIdea'));
      expect(
        ai.policy.priority,
        equals(PriorityPolicyKind.timeDecayedPriority),
      );
      expect(ai.policy.retention, equals(RetentionPolicyKind.boundedN));
      expect(ai.policy.maxCount, equals(1000));
      expect(ai.policy.halflifeMs, equals(30 * dayMs));

      // 3. interests: timeDecayedPriority(14d) / boundedN(500)
      final ii = byName['interests']!;
      expect(ii.entryNodeType, equals('InterestItem'));
      expect(
        ii.policy.priority,
        equals(PriorityPolicyKind.timeDecayedPriority),
      );
      expect(ii.policy.retention, equals(RetentionPolicyKind.boundedN));
      expect(ii.policy.maxCount, equals(500));
      expect(ii.policy.halflifeMs, equals(14 * dayMs));

      // 4. inflight: fifo / boundedN(64) / ProcedureRun
      final inf = byName['inflight']!;
      expect(inf.entryNodeType, equals('ProcedureRun'));
      expect(inf.policy.priority, equals(PriorityPolicyKind.fifo));
      expect(inf.policy.retention, equals(RetentionPolicyKind.boundedN));
      expect(inf.policy.maxCount, equals(64));
      expect(inf.policy.halflifeMs, isNull);

      // 5. recent_runs: lifo / boundedN(512) / ProcedureRun
      final rr = byName['recent_runs']!;
      expect(rr.entryNodeType, equals('ProcedureRun'));
      expect(rr.policy.priority, equals(PriorityPolicyKind.lifo));
      expect(rr.policy.retention, equals(RetentionPolicyKind.boundedN));
      expect(rr.policy.maxCount, equals(512));
      expect(rr.policy.halflifeMs, isNull);

      // 6. restructure_backlog: fifo / unbounded / (any)
      final rb = byName['restructure_backlog']!;
      expect(rb.entryNodeType, equals(stackEntryNodeTypeAny));
      expect(rb.policy.priority, equals(PriorityPolicyKind.fifo));
      expect(rb.policy.retention, equals(RetentionPolicyKind.unbounded));
      expect(rb.policy.maxCount, isNull);
      expect(rb.policy.halflifeMs, isNull);
    });

    test('spec name set agrees with sqlite_stack_api rejection set', () {
      // The installer's compile-time guard catches drift; this test
      // confirms it from the consumer side. If they diverge the
      // first installer call would throw `StateError`.
      expect(
        bootstrapStackSpecs.map((s) => s.name).toSet(),
        equals(bootstrapStackNames),
      );
    });

    // ─── Fresh install ───────────────────────────────────────────

    test('first install: all six stacks committed with is_bootstrap=1',
        () async {
      final report = installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );

      expect(report.wasFreshInstall, isTrue);
      expect(report.installed, hasLength(6));
      expect(report.skipped, isEmpty);
      // Installed order mirrors the canonical list.
      expect(
        report.installed,
        equals(<String>[
          'questions_open',
          'automation_ideas',
          'interests',
          'inflight',
          'recent_runs',
          'restructure_backlog',
        ]),
      );

      // Catalogue row check: every name present with is_bootstrap=1.
      final rows = db.select(
        'SELECT name, is_bootstrap FROM stacks ORDER BY name',
      );
      expect(rows, hasLength(6));
      for (final row in rows) {
        expect(row['is_bootstrap'], equals(1));
      }

      // One StackCreated event per stack, all with bootstrap=true.
      final created =
          events.whereType<StackCreated>().toList(growable: false);
      expect(created, hasLength(6));
      for (final ev in created) {
        expect(ev.bootstrap, isTrue);
        expect(bootstrapStackNames, contains(ev.stackName));
      }
    });

    test('first install: canonical Stack nodes minted with bootstrap provenance',
        () async {
      installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );

      // Six Stack nodes, all produced by the bootstrap path with
      // the `stack:<name>` idempotency key.
      final rows = db.select(
        "SELECT id, type_name, produced_by, idempotency_key, attrs_json "
        "FROM nodes WHERE type_name = 'Stack' ORDER BY idempotency_key",
      );
      expect(rows, hasLength(6));
      for (final row in rows) {
        expect(row['produced_by'], equals('memory:stacks.bootstrap'));
        final key = row['idempotency_key'] as String;
        expect(key, startsWith('stack:'));
        final name = key.substring('stack:'.length);
        expect(bootstrapStackNames, contains(name));
        final attrs =
            jsonDecode(row['attrs_json'] as String) as Map<String, Object?>;
        expect(attrs['name'], equals(name));
        expect((attrs['summary'] as String).isNotEmpty, isTrue);
      }
    });

    test('first install: policy attrs JSON round-trips halflife and bounds',
        () async {
      installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
      );

      Map<String, Object?>? decode(String? raw) =>
          raw == null ? null : jsonDecode(raw) as Map<String, Object?>;

      final rows = db.select(
        'SELECT name, priority_policy, priority_policy_attrs_json, '
        'retention_policy, retention_policy_attrs_json FROM stacks',
      );
      final byName = <String, Row>{for (final r in rows) r['name'] as String: r};

      const dayMs = 24 * 60 * 60 * 1000;

      // automation_ideas
      final ai = byName['automation_ideas']!;
      expect(ai['priority_policy'], equals('timeDecayedPriority'));
      expect(
        decode(ai['priority_policy_attrs_json'] as String?),
        equals(<String, Object?>{'halflifeMs': 30 * dayMs}),
      );
      expect(ai['retention_policy'], equals('boundedN'));
      expect(
        decode(ai['retention_policy_attrs_json'] as String?),
        equals(<String, Object?>{'maxCount': 1000}),
      );

      // interests
      final ii = byName['interests']!;
      expect(
        decode(ii['priority_policy_attrs_json'] as String?),
        equals(<String, Object?>{'halflifeMs': 14 * dayMs}),
      );
      expect(
        decode(ii['retention_policy_attrs_json'] as String?),
        equals(<String, Object?>{'maxCount': 500}),
      );

      // questions_open (unbounded: no attrs)
      final qo = byName['questions_open']!;
      expect(qo['priority_policy_attrs_json'], isNull);
      expect(qo['retention_policy_attrs_json'], isNull);

      // restructure_backlog: any-type sentinel persisted verbatim
      final rb = byName['restructure_backlog']!;
      expect(rb['priority_policy'], equals('fifo'));
      expect(rb['retention_policy'], equals('unbounded'));
    });

    // ─── Idempotency ─────────────────────────────────────────────

    test('second install on the same DB is a no-op', () async {
      installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      events.clear();

      final report2 = installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );

      expect(report2.wasNoOp, isTrue);
      expect(report2.installed, isEmpty);
      expect(report2.skipped, hasLength(6));
      expect(events, isEmpty);

      // Catalogue still has exactly six rows.
      final count = db.select('SELECT COUNT(*) AS c FROM stacks').first;
      expect(count['c'], equals(6));
      // Canonical Stack nodes also still exactly six — no duplicates.
      final nodeCount = db
          .select("SELECT COUNT(*) AS c FROM nodes WHERE type_name = 'Stack'")
          .first;
      expect(nodeCount['c'], equals(6));
    });

    test('partial install self-heals on next call', () async {
      // Simulate a crash mid-install: only `inflight` made it in.
      installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
      );
      // Remove five of the six rows to mimic a partial state.
      db.execute(
        "DELETE FROM stacks WHERE name != 'inflight'",
      );
      db.execute(
        "DELETE FROM nodes WHERE type_name = 'Stack' "
        "AND idempotency_key != 'stack:inflight'",
      );

      final report = installBootstrapStacks(
        db,
        stackNodeIdMint: mintStackNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );

      expect(report.installed, hasLength(5));
      expect(report.skipped, equals(<String>['inflight']));
      expect(events.whereType<StackCreated>(), hasLength(5));

      final all = db.select('SELECT name FROM stacks ORDER BY name');
      expect(all, hasLength(6));
    });
  });

  // ─── delete() — bootstrap immutability + non-bootstrap path ────

  group('A.43 SqliteStackApi.delete', () {
    late Database db;
    late DateTime fakeNow;
    late int seed;

    SqliteStackApi buildApi() {
      var entrySeed = 1000;
      var stackNodeSeed = 2000;
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
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      fakeNow = DateTime.utc(2026, 5, 30, 17, 0, 0);
      seed = 0;
      // Install bootstrap stacks for the immutability tests.
      installBootstrapStacks(
        db,
        stackNodeIdMint: () {
          seed += 1;
          return NodeId.generate(
            at: fakeNow,
            randomness: List<int>.generate(16, (i) => (seed * 7 + i) & 31),
          );
        },
        now: () => fakeNow,
      );
    });

    tearDown(() => db.dispose());

    test('delete on every bootstrap stack → BootstrapStackImmutable',
        () async {
      final api = buildApi();
      for (final name in bootstrapStackNames) {
        await expectLater(
          () => api.delete(name),
          throwsA(isA<BootstrapStackImmutable>()
              .having((e) => e.stackName, 'stackName', name)),
        );
      }
      // Catalogue still intact.
      final count = db.select('SELECT COUNT(*) AS c FROM stacks').first;
      expect(count['c'], equals(6));
    });

    test('create on every bootstrap name still rejected after install',
        () async {
      final api = buildApi();
      for (final name in bootstrapStackNames) {
        await expectLater(
          () => api.create(
            StackDecl(
              name: name,
              summary: 'should not be allowed',
              policy: const StackPolicy(
                priority: PriorityPolicyKind.fifo,
                retention: RetentionPolicyKind.unbounded,
              ),
              entryNodeType: 'Question',
            ),
          ),
          throwsA(isA<BootstrapStackImmutable>()
              .having((e) => e.stackName, 'stackName', name)),
        );
      }
    });

    test('delete on unknown stack → StackNotFound', () async {
      final api = buildApi();
      await expectLater(
        () => api.delete('not_a_real_stack'),
        throwsA(isA<StackNotFound>()
            .having((e) => e.stackName, 'stackName', 'not_a_real_stack')),
      );
    });

    test('delete on a non-bootstrap stack removes catalogue row, '
        'canonical node, and entries', () async {
      final api = buildApi();
      await api.create(
        StackDecl(
          name: 'user_workbench',
          summary: 'a user-created stack',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.priority,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ),
      );
      // Push a couple of entries; they should be deleted alongside
      // the stack catalogue row.
      final node1 = NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (i + 1) & 31),
      );
      final node2 = NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (i + 2) & 31),
      );
      await api.push('user_workbench', node1);
      await api.push('user_workbench', node2);

      // Find the canonical Stack node id before deletion so we can
      // verify it is gone afterwards.
      final stackNodeRow = db
          .select(
            "SELECT id FROM nodes WHERE type_name = 'Stack' "
            "AND idempotency_key = 'stack:user_workbench'",
          )
          .first;
      final stackNodeId = stackNodeRow['id'] as String;

      await api.delete('user_workbench');

      expect(
        db.select(
          'SELECT 1 FROM stacks WHERE name = ?',
          <Object?>['user_workbench'],
        ),
        isEmpty,
      );
      expect(
        db.select(
          'SELECT 1 FROM stack_entries WHERE stack_name = ?',
          <Object?>['user_workbench'],
        ),
        isEmpty,
      );
      expect(
        db.select(
          'SELECT 1 FROM nodes WHERE id = ?',
          <Object?>[stackNodeId],
        ),
        isEmpty,
      );
      // Bootstrap rows untouched.
      final remaining =
          db.select('SELECT COUNT(*) AS c FROM stacks').first;
      expect(remaining['c'], equals(6));
    });

    test('delete twice → second call throws StackNotFound', () async {
      final api = buildApi();
      await api.create(
        StackDecl(
          name: 'transient',
          summary: 'short-lived',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ),
      );
      await api.delete('transient');
      await expectLater(
        () => api.delete('transient'),
        throwsA(isA<StackNotFound>()),
      );
    });
  });
}

