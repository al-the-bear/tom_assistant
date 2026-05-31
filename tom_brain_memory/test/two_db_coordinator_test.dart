// A.30 two-database transaction coordinator contract test.
//
// Locks the crash-resilient two-DB write protocol described in
// `memory_specification.md` § 2.4 and `lib/src/store/two_db_coordinator.dart`:
//
//   1. Happy path: persistNodeWithVector writes the node row, calls the
//      applier exactly once, and clears the pending row.
//   2. Happy path without a vector: no pending row is ever written and
//      the applier is never called.
//   3. Crash between writes (the named A.30 scenario): the applier
//      throws during persistNodeWithVector, leaving the node committed
//      and the pending row in place. A second coordinator with a
//      healthy applier replays the pending row, applies the vector,
//      and clears the row.
//   4. memory.db write-side failure: writeNode throws → rollback,
//      no pending row, applier never called.
//   5. recoverPending on a clean DB is a no-op.
//   6. recoverPending aggregates per-row failures without aborting the
//      pass; failing rows stay pending so the next pass can retry.
//   7. recoverPending is idempotent — running twice on a healthy
//      applier leaves the table empty on both passes (the second pass
//      observes zero scanned rows).
//   8. Recovery after a partial pre-crash apply succeeds because the
//      VectorApplier contract requires idempotency; the in-memory
//      fake demonstrates the upsert behaviour by overwriting.
//   9. PendingVectorWrite ordering: listPending returns rows sorted by
//      enqueued_at_ms ASC, mirroring the original write order.
//  10. Per-node uniqueness: persistNodeWithVector twice for the same
//      node id while a pending row exists raises a SqliteException
//      from the PK constraint (spec § 9.1 invariant at the storage
//      layer).
//
// The test uses `sqlite3.openInMemory()` and an injected fake
// `VectorApplier`, mirroring the A.27 / A.28 / A.29 testing style: no
// filesystem, no sqlite-vec dependency. Every assertion exercises the
// real coordinator against a real SQLite engine.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.30 two-database coordinator', () {
    late Database db;
    late _FakeVectorApplier applier;
    late MutableTestClock clock;
    late TwoDbCoordinator coordinator;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      applier = _FakeVectorApplier();
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: applier,
        clock: clock,
      );
    });

    tearDown(() {
      db.dispose();
    });

    // ─────────────────────────────────────────────────────────────────
    // Happy paths
    // ─────────────────────────────────────────────────────────────────

    test('persistNodeWithVector commits node, applies vector, clears '
        'pending row', () {
      coordinator.persistNodeWithVector(
        nodeId: 'n_one',
        writeNode: (db) => _insertMinimalNode(db, id: 'n_one'),
        vector: _payload(modelId: 'nomic-embed-text', dims: 4),
      );

      // Node row committed.
      final nodes = db.select('SELECT id FROM nodes');
      expect(nodes.length, equals(1));
      expect(nodes.first['id'], equals('n_one'));

      // Applier called exactly once with the matching payload.
      expect(applier.applied.length, equals(1));
      final applied = applier.applied.single;
      expect(applied.nodeId, equals('n_one'));
      expect(applied.embeddingModelId, equals('nomic-embed-text'));
      expect(applied.payloadDims, equals(4));
      expect(applied.payloadBlob.length, equals(16));

      // Pending row cleared.
      expect(coordinator.pendingCount(), equals(0));
      expect(coordinator.listPending(), isEmpty);
    });

    test('persistNodeWithVector without a vector writes no pending row '
        'and never calls the applier', () {
      coordinator.persistNodeWithVector(
        nodeId: 'n_no_vec',
        writeNode: (db) => _insertMinimalNode(db, id: 'n_no_vec'),
        vector: null,
      );

      // Node row committed.
      expect(
        db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
        equals(1),
      );
      // Applier untouched.
      expect(applier.applied, isEmpty);
      // No pending row ever existed.
      expect(coordinator.pendingCount(), equals(0));
    });

    test('persistNodeWithVector stamps enqueued_at from the injected '
        'clock', () {
      final t0 = BrainTime.utc(2026, 6, 1, 9, 30, 0);
      clock.setTo(t0);

      // Use a *failing* applier so the pending row stays observable.
      final failing = _FailingVectorApplier(StateError('boom'));
      final c = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );

      expect(
        () => c.persistNodeWithVector(
          nodeId: 'n_time',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_time'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      final pending = c.listPending();
      expect(pending.length, equals(1));
      expect(pending.single.enqueuedAt.toMs(), equals(t0.toMs()));
    });

    // ─────────────────────────────────────────────────────────────────
    // Crash between writes — the named A.30 scenario
    // ─────────────────────────────────────────────────────────────────

    test(
        'crash between writes: applier throws, node + pending row '
        'survive, a fresh coordinator with a healthy applier replays', () {
      // First coordinator: applier blows up after the memory.db commit.
      final failing = _FailingVectorApplier(StateError('disk full'));
      final crashy = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );

      expect(
        () => crashy.persistNodeWithVector(
          nodeId: 'n_crash',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_crash'),
          vector: _payload(modelId: 'nomic', dims: 3),
        ),
        throwsA(isA<StateError>()),
      );

      // Post-"crash" invariants on memory.db:
      //
      //   * Node row IS committed (we got past memory.db's COMMIT
      //     before the applier failed).
      //   * Pending row IS present (the WAL for the unfinished vector
      //     write).
      //   * vectors.db side never recorded anything.
      expect(
        db.select(
          "SELECT id FROM nodes WHERE id = 'n_crash'",
        ).length,
        equals(1),
      );
      final pending = crashy.listPending();
      expect(pending.length, equals(1));
      expect(pending.single.nodeId, equals('n_crash'));
      expect(pending.single.embeddingModelId, equals('nomic'));
      expect(pending.single.payloadDims, equals(3));
      expect(failing.applyCallCount, equals(1));

      // Simulate process restart: rebuild a fresh coordinator over the
      // same `memory.db`, this time with a healthy applier. Recovery
      // replays the pending row.
      final healthy = _FakeVectorApplier();
      final recovered = TwoDbCoordinator(
        memoryDb: db,
        applier: healthy,
        clock: clock,
      );

      final report = recovered.recoverPending();

      expect(report.scanned, equals(1));
      expect(report.succeeded, equals(1));
      expect(report.hasFailures, isFalse);
      expect(report.failures, isEmpty);

      // The healthy applier received the *same* payload the original
      // coordinator enqueued.
      expect(healthy.applied.length, equals(1));
      expect(healthy.applied.single.nodeId, equals('n_crash'));
      expect(healthy.applied.single.embeddingModelId, equals('nomic'));
      expect(healthy.applied.single.payloadDims, equals(3));

      // Pending row is now gone — both stores are consistent.
      expect(recovered.pendingCount(), equals(0));
    });

    // ─────────────────────────────────────────────────────────────────
    // memory.db rollback path
    // ─────────────────────────────────────────────────────────────────

    test('writeNode throws → memory.db rolled back, no pending row, '
        'applier never called', () {
      expect(
        () => coordinator.persistNodeWithVector(
          nodeId: 'n_rollback',
          writeNode: (db) {
            // Insert a row, then throw mid-transaction. The whole
            // transaction must roll back.
            _insertMinimalNode(db, id: 'n_rollback');
            throw StateError('writer failed');
          },
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      // Row never committed.
      expect(
        db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
        equals(0),
      );
      // Pending row never written.
      expect(coordinator.pendingCount(), equals(0));
      // Applier never reached.
      expect(applier.applied, isEmpty);
    });

    test('writeNode that violates a constraint rolls back cleanly, '
        'leaving the coordinator usable for a subsequent write', () {
      // First write: inserts n_dup.
      coordinator.persistNodeWithVector(
        nodeId: 'n_dup',
        writeNode: (db) => _insertMinimalNode(db, id: 'n_dup'),
        vector: null,
      );

      // Second write: collides on the PK. The whole tx must roll back.
      expect(
        () => coordinator.persistNodeWithVector(
          nodeId: 'n_dup_2',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_dup'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<SqliteException>()),
      );

      // The coordinator's SQLite connection must still be usable —
      // a leaked transaction would make every subsequent write fail.
      coordinator.persistNodeWithVector(
        nodeId: 'n_after_rollback',
        writeNode: (db) => _insertMinimalNode(db, id: 'n_after_rollback'),
        vector: _payload(modelId: 'm', dims: 2),
      );
      expect(
        db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
        equals(2),
      );
      expect(coordinator.pendingCount(), equals(0));
    });

    // ─────────────────────────────────────────────────────────────────
    // recoverPending
    // ─────────────────────────────────────────────────────────────────

    test('recoverPending on a clean DB returns an empty report', () {
      final report = coordinator.recoverPending();

      expect(report.scanned, equals(0));
      expect(report.succeeded, equals(0));
      expect(report.failures, isEmpty);
      expect(report.isEmpty, isTrue);
      expect(report.didProcessAny, isFalse);
      expect(report.hasFailures, isFalse);
      // Even on an empty pass, start/finish timestamps are populated.
      expect(report.startedAt.toMs(), equals(clock.currentTime.toMs()));
      expect(report.finishedAt.toMs(), equals(clock.currentTime.toMs()));
    });

    test('recoverPending aggregates per-row failures without aborting '
        'the pass; failing rows stay pending', () {
      // Seed three pending rows by using a coordinator with a
      // deliberately-failing applier.
      final failing = _FailingVectorApplier(StateError('boom'));
      final seeder = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );
      for (final id in ['n_a', 'n_b', 'n_c']) {
        expect(
          () => seeder.persistNodeWithVector(
            nodeId: id,
            writeNode: (db) => _insertMinimalNode(db, id: id),
            vector: _payload(modelId: 'm', dims: 2),
          ),
          throwsA(isA<StateError>()),
        );
      }
      expect(seeder.pendingCount(), equals(3));

      // Recover with a *selectively*-failing applier: succeed for n_b,
      // fail for n_a and n_c.
      final selective = _SelectiveApplier(
        succeedFor: {'n_b'},
        errorFor: {'n_a': StateError('no'), 'n_c': StateError('nope')},
      );
      final recoverer = TwoDbCoordinator(
        memoryDb: db,
        applier: selective,
        clock: clock,
      );

      final report = recoverer.recoverPending();

      expect(report.scanned, equals(3));
      expect(report.succeeded, equals(1));
      expect(report.failures.length, equals(2));
      expect(report.hasFailures, isTrue);
      // Failures carry the originating node ids and the propagated
      // exceptions.
      final failedIds = report.failures.map((f) => f.nodeId).toSet();
      expect(failedIds, equals({'n_a', 'n_c'}));
      for (final f in report.failures) {
        expect(f.error, isA<StateError>());
        // Stack trace is always present so the failure record is
        // self-contained.
        expect(f.stackTrace, isNotNull);
      }

      // The succeeded row is gone; the two failed rows remain.
      expect(recoverer.pendingCount(), equals(2));
      final remaining =
          recoverer.listPending().map((w) => w.nodeId).toSet();
      expect(remaining, equals({'n_a', 'n_c'}));
    });

    test('recoverPending is idempotent: running twice with a healthy '
        'applier returns an empty report on the second pass', () {
      // Seed one pending row via a failing applier.
      final failing = _FailingVectorApplier(StateError('boom'));
      final seeder = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_idem',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_idem'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      final report1 = coordinator.recoverPending();
      expect(report1.scanned, equals(1));
      expect(report1.succeeded, equals(1));

      final report2 = coordinator.recoverPending();
      expect(report2.scanned, equals(0));
      expect(report2.succeeded, equals(0));
      expect(report2.isEmpty, isTrue);

      // Applier received the row only on the first pass.
      expect(applier.applied.length, equals(1));
      expect(applier.applied.single.nodeId, equals('n_idem'));
    });

    test('recoverPending respects the idempotency contract of the '
        'applier: an upsert-style applier may have already partially '
        'written the vector', () {
      // _UpsertApplier overwrites on every apply — the model A.50+'s
      // sqlite-vec applier will use (REPLACE INTO …). The coordinator
      // re-calls it on recovery; the result is a single live row.
      final upserter = _UpsertApplier();
      final partial = TwoDbCoordinator(
        memoryDb: db,
        applier: upserter,
        clock: clock,
      );

      // Pre-stage: pretend the applier already wrote half before
      // crashing (the upserter "sees" a row at boot time).
      upserter.preStage('n_partial', dims: 2);

      // Seed pending via a separate failing path so we get a pending
      // row to recover.
      final failing = _FailingVectorApplier(StateError('boom'));
      final seeder = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_partial',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_partial'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      final report = partial.recoverPending();

      expect(report.scanned, equals(1));
      expect(report.succeeded, equals(1));
      // The upserter still holds exactly one row for n_partial — the
      // pre-stage was overwritten in place. This is the idempotency
      // contract honoured.
      expect(upserter.live('n_partial'), equals(1));
      expect(partial.pendingCount(), equals(0));
    });

    // ─────────────────────────────────────────────────────────────────
    // Surface invariants
    // ─────────────────────────────────────────────────────────────────

    test('listPending returns rows ordered by enqueued_at_ms ASC, '
        'matching the original write order', () {
      // Use the failing applier so we can observe ordering on a populated
      // table.
      final failing = _FailingVectorApplier(StateError('boom'));
      final seeder = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );

      // Write in deliberately-non-chronological order by advancing the
      // clock between writes.
      clock.setTo(BrainTime.utc(2026, 5, 30, 12, 0, 5));
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_second',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_second'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );
      clock.setTo(BrainTime.utc(2026, 5, 30, 12, 0, 1));
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_first',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_first'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );
      clock.setTo(BrainTime.utc(2026, 5, 30, 12, 0, 10));
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_third',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_third'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      final pending = seeder.listPending();
      expect(
        pending.map((w) => w.nodeId).toList(),
        equals(['n_first', 'n_second', 'n_third']),
      );
    });

    test('per-node uniqueness: two pending rows for the same node id '
        'raises a SqliteException from the primary key constraint', () {
      // Seed one pending row.
      final failing = _FailingVectorApplier(StateError('boom'));
      final seeder = TwoDbCoordinator(
        memoryDb: db,
        applier: failing,
        clock: clock,
      );
      expect(
        () => seeder.persistNodeWithVector(
          nodeId: 'n_unique',
          writeNode: (db) => _insertMinimalNode(db, id: 'n_unique'),
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<StateError>()),
      );

      // Attempting to enqueue a second pending row for the same
      // node id collides on the PRIMARY KEY (node_id).
      expect(
        () => seeder.persistNodeWithVector(
          // Use a different node row id so the nodes.id PK is *not*
          // the collision — we want the pending_vector_writes PK to
          // be the one that fires.
          nodeId: 'n_unique',
          writeNode: (db) {
            // Don't insert a new node; the pending-write PK should
            // fire first because the INSERT-pending statement runs
            // inside the same memory.db transaction.
          },
          vector: _payload(modelId: 'm', dims: 2),
        ),
        throwsA(isA<SqliteException>()),
      );

      // First pending row remains; the second was rolled back.
      expect(seeder.pendingCount(), equals(1));
    });

    test('PendingVectorWrite, PendingVectorWritePayload, '
        'TwoDbReplayReport, TwoDbReplayFailure toString surfaces are '
        'operator-grade (non-empty + carry the discriminating fields)',
        () {
      final payload = _payload(modelId: 'm', dims: 2);
      expect(payload.toString(), contains('model: m'));
      expect(payload.toString(), contains('dims: 2'));

      final write = PendingVectorWrite(
        nodeId: 'n_x',
        embeddingModelId: 'm',
        payloadBlob: Uint8List(8),
        payloadDims: 2,
        enqueuedAt: BrainTime.utc(2026, 1, 1),
      );
      expect(write.toString(), contains('n_x'));
      expect(write.toString(), contains('m'));

      final failure = TwoDbReplayFailure(
        nodeId: 'n_y',
        error: StateError('oops'),
        stackTrace: StackTrace.current,
      );
      expect(failure.toString(), contains('n_y'));
      expect(failure.toString(), contains('oops'));

      final report = TwoDbReplayReport(
        scanned: 3,
        succeeded: 2,
        failures: [failure],
        startedAt: BrainTime.utc(2026, 1, 1),
        finishedAt: BrainTime.utc(2026, 1, 1).plus(
          const Duration(milliseconds: 5),
        ),
      );
      expect(report.toString(), contains('scanned: 3'));
      expect(report.toString(), contains('succeeded: 2'));
      expect(report.toString(), contains('failed: 1'));
      expect(report.duration, equals(const Duration(milliseconds: 5)));
    });

    test('TwoDbReplayReport.failures is unmodifiable', () {
      final report = TwoDbReplayReport(
        scanned: 0,
        succeeded: 0,
        failures: const [],
        startedAt: BrainTime.utc(2026, 1, 1),
        finishedAt: BrainTime.utc(2026, 1, 1),
      );
      expect(
        () => report.failures.add(TwoDbReplayFailure(
          nodeId: 'x',
          error: 'x',
          stackTrace: StackTrace.current,
        )),
        throwsUnsupportedError,
      );
    });
  });
}

// ─────────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────────

/// Inserts a minimal valid row into the `nodes` table for the given id.
///
/// Uses the spec-level field set the schema declares; values are
/// deterministic so the surrounding test assertions can refer to them.
void _insertMinimalNode(Database db, {required String id}) {
  db.execute(
    'INSERT INTO nodes '
    '(id, type_name, scope_json, attrs_json, status, '
    'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      'TestType',
      '{}',
      '{}',
      'active',
      0,
      '1970-01-01T00:00:00.000Z',
      0,
      '1970-01-01T00:00:00.000Z',
    ],
  );
}

PendingVectorWritePayload _payload({
  required String modelId,
  required int dims,
}) =>
    PendingVectorWritePayload(
      embeddingModelId: modelId,
      payloadBlob: Uint8List(dims * 4),
      payloadDims: dims,
    );

/// Records every vector write so tests can assert what the applier saw.
final class _FakeVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> applied = [];

  @override
  void apply(PendingVectorWrite write) {
    applied.add(write);
  }
}

/// Always throws on apply; tracks how many times it was called so tests
/// can verify the coordinator's retry boundaries.
final class _FailingVectorApplier implements VectorApplier {
  final Object _error;
  int applyCallCount = 0;

  _FailingVectorApplier(this._error);

  @override
  void apply(PendingVectorWrite write) {
    applyCallCount++;
    throw _error;
  }
}

/// Decides per-call whether to succeed or throw, based on the
/// originating node id. Used for the "partial-failure recovery"
/// scenario.
final class _SelectiveApplier implements VectorApplier {
  final Set<String> succeedFor;
  final Map<String, Object> errorFor;
  final List<PendingVectorWrite> successes = [];

  _SelectiveApplier({required this.succeedFor, required this.errorFor});

  @override
  void apply(PendingVectorWrite write) {
    if (succeedFor.contains(write.nodeId)) {
      successes.add(write);
      return;
    }
    final err = errorFor[write.nodeId];
    if (err != null) {
      throw err;
    }
    throw StateError('_SelectiveApplier: unhandled node ${write.nodeId}');
  }
}

/// In-memory model of an idempotent (REPLACE-INTO) vector applier. Used
/// to demonstrate the recovery path against a partial pre-crash apply.
final class _UpsertApplier implements VectorApplier {
  /// Map from node id to the number of live rows. A correctly-behaved
  /// upsert applier always leaves exactly one live row per node id,
  /// regardless of how many times `apply` is called.
  final Map<String, int> _live = {};

  /// Simulates a pre-crash partial apply by seeding a row for [nodeId].
  void preStage(String nodeId, {required int dims}) {
    _live[nodeId] = 1;
  }

  int live(String nodeId) => _live[nodeId] ?? 0;

  @override
  void apply(PendingVectorWrite write) {
    // REPLACE-INTO semantics: collapses any pre-existing row.
    _live[write.nodeId] = 1;
  }
}
