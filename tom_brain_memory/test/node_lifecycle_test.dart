// A.35 — NodeReader + NodeLifecycleManager contract tests.
//
// Covers the four methods that land at A.35:
//
//   NodeReader.get
//   ---------------
//   * Returns null for an unknown id.
//   * Returns the persisted node by id (active status).
//   * Returns null after the node has been forgotten (live row gone).
//   * Returns a demoted node with status == NodeStatus.demoted.
//
//   NodeReader.getMany
//   ------------------
//   * Empty input returns empty output without hitting SQLite.
//   * Preserves input order in the output list.
//   * Elides missing ids (no null placeholders).
//   * Duplicate input ids return each found node once.
//   * Bulk reads return the demoted/active status correctly.
//
//   NodeLifecycleManager.demote
//   ---------------------------
//   * Active → demoted: row remains present with new status.
//   * Demote is idempotent (second call is a no-op).
//   * Demote on a non-existent id is a no-op (no error).
//   * updated_at_ms is bumped on the demoted row.
//   * Demote does NOT delete the row.
//
//   NodeLifecycleManager.forget
//   ---------------------------
//   * Forget on a live node: writes a Tombstone, indexes it,
//     removes the live row, leaves the Tombstone reachable by its
//     own NodeId, returns null on get(forgottenId).
//   * Tombstone carries reason + forgotten_at attrs.
//   * tombstones_index row references the right forgotten id and
//     type.
//   * Forget on a non-existent id is a no-op — no Tombstone written.
//   * Forget on an already-forgotten id is a no-op — does not
//     chain Tombstones.
//   * Forget on a demoted node: still writes a Tombstone and
//     removes the row.
//   * Forget cleans up pending_vector_writes for the forgotten id.
//   * Tombstone's idempotency_key is `tombstone:<forgotten_id>`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.35 NodeReader + NodeLifecycleManager', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late NodeReader reader;
    late NodeLifecycleManager lifecycle;
    late List<MemoryEvent> events;
    late int idCounter;
    late DateTime fakeNow;

    NodeId mintId() {
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    NodeId mintLifecycleId() {
      // Different randomness stream from the persister so ids cannot
      // collide.
      idCounter += 1;
      final randomness =
          List<int>.generate(16, (i) => (idCounter + i + 64) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    setUp(() async {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      events = <MemoryEvent>[];
      idCounter = 0;
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);

      var regIdCounter = 1000;
      NodeId mintRegistryId() {
        regIdCounter += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness:
              List<int>.generate(16, (i) => (regIdCounter + i) & 31),
        );
      }

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validTombstone());

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      reader = NodeReader(memoryDb: db);
      lifecycle = NodeLifecycleManager(
        memoryDb: db,
        idMint: mintLifecycleId,
        now: () => fakeNow,
        eventSink: events.add,
      );
    });

    tearDown(() {
      db.dispose();
    });

    Future<NodeId> persistClaim({
      required String text,
      required String key,
      int seed = 1,
    }) {
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: seed),
        ),
        scope: Scope(producer: 'p', idempotencyKey: key),
      );
    }

    // ─── NodeReader.get ────────────────────────────────────────────

    test('get returns null for an unknown id', () async {
      final unknown = NodeId.generate();
      final node = await reader.get(unknown);
      expect(node, isNull);
    });

    test('get returns the persisted node', () async {
      final id = await persistClaim(text: 'hello', key: 'k1');
      final node = await reader.get(id);

      expect(node, isNotNull);
      expect(node!.id, equals(id));
      expect(node.typeName, equals('Claim'));
      expect(node.status, equals(NodeStatus.active));
      expect(node.values['text'], equals('hello'));
      expect(node.createdAt.isUtc, isTrue);
      expect(node.createdAt, equals(fakeNow));
      // Embedding readback is deferred to A.50+; A.35 contract is
      // explicit on this being null even when the type carries one.
      expect(node.embedding, isNull);
    });

    test('get returns null for a forgotten id', () async {
      final id = await persistClaim(text: 'gone', key: 'k-gone');
      await lifecycle.forget(id, ForgetReason.userRequested);
      final node = await reader.get(id);
      expect(node, isNull);
    });

    test('get returns a demoted node with status = demoted', () async {
      final id = await persistClaim(text: 'hidden', key: 'k-hidden');
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      final node = await reader.get(id);
      expect(node, isNotNull);
      expect(node!.status, equals(NodeStatus.demoted));
      expect(node.values['text'], equals('hidden'));
    });

    // ─── NodeReader.getMany ────────────────────────────────────────

    test('getMany returns empty for empty input', () async {
      final out = await reader.getMany(const <NodeId>[]);
      expect(out, isEmpty);
    });

    test('getMany preserves input order', () async {
      final id1 = await persistClaim(text: 'a', key: 'k-a', seed: 1);
      final id2 = await persistClaim(text: 'b', key: 'k-b', seed: 2);
      final id3 = await persistClaim(text: 'c', key: 'k-c', seed: 3);

      final out = await reader.getMany(<NodeId>[id3, id1, id2]);
      expect(out.map((n) => n.id).toList(), equals(<NodeId>[id3, id1, id2]));
    });

    test('getMany elides missing ids', () async {
      final id1 = await persistClaim(text: 'a', key: 'k-a', seed: 1);
      final missing = NodeId.generate();
      final id2 = await persistClaim(text: 'b', key: 'k-b', seed: 2);

      final out = await reader.getMany(<NodeId>[id1, missing, id2]);
      expect(out.map((n) => n.id).toList(), equals(<NodeId>[id1, id2]));
    });

    test('getMany returns each found node once for duplicate ids',
        () async {
      final id1 = await persistClaim(text: 'a', key: 'k-a', seed: 1);
      final out = await reader.getMany(<NodeId>[id1, id1, id1]);
      expect(out, hasLength(1));
      expect(out.single.id, equals(id1));
    });

    test('getMany reflects demoted status', () async {
      final id1 = await persistClaim(text: 'active', key: 'k-active', seed: 1);
      final id2 = await persistClaim(text: 'demoted', key: 'k-d', seed: 2);
      await lifecycle.demote(id2, DemotionReason.prunerDecision);

      final out = await reader.getMany(<NodeId>[id1, id2]);
      expect(out, hasLength(2));
      expect(out[0].status, equals(NodeStatus.active));
      expect(out[1].status, equals(NodeStatus.demoted));
    });

    // ─── NodeLifecycleManager.demote ───────────────────────────────

    test('demote flips status from active to demoted', () async {
      final id = await persistClaim(text: 'x', key: 'k1');

      // Capture the pre-demote updated_at to confirm the bump.
      final preRow = db.select(
          'SELECT updated_at_ms FROM nodes WHERE id = ?',
          <Object?>[id.toString()]);
      final preUpdated = preRow.first['updated_at_ms'] as int;

      // Bump the clock so the post-demote row has a different stamp.
      fakeNow = DateTime.utc(2026, 5, 30, 15, 0, 0);

      await lifecycle.demote(id, DemotionReason.prunerDecision);

      final postRow = db.select(
        'SELECT status, updated_at_ms FROM nodes WHERE id = ?',
        <Object?>[id.toString()],
      );
      expect(postRow, hasLength(1));
      expect(postRow.first['status'], equals('demoted'));
      expect(postRow.first['updated_at_ms'],
          equals(fakeNow.millisecondsSinceEpoch));
      expect(postRow.first['updated_at_ms'],
          isNot(equals(preUpdated)));
    });

    test('demote on already-demoted node is a no-op (updated_at unchanged)',
        () async {
      final id = await persistClaim(text: 'x', key: 'k1');

      fakeNow = DateTime.utc(2026, 5, 30, 15, 0, 0);
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      final firstDemoteMs = fakeNow.millisecondsSinceEpoch;

      // Second demote at a later clock — must NOT bump updated_at.
      fakeNow = DateTime.utc(2026, 5, 30, 16, 0, 0);
      await lifecycle.demote(id, DemotionReason.prunerDecision);

      final row = db.select(
          'SELECT status, updated_at_ms FROM nodes WHERE id = ?',
          <Object?>[id.toString()]);
      expect(row.first['status'], equals('demoted'));
      expect(row.first['updated_at_ms'], equals(firstDemoteMs));
    });

    test('demote on a non-existent id is a no-op', () async {
      final unknown = NodeId.generate();
      // No throw, no side effects.
      await lifecycle.demote(unknown, DemotionReason.prunerDecision);
      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(0));
    });

    test('demote does not delete the row', () async {
      final id = await persistClaim(text: 'x', key: 'k1');
      await lifecycle.demote(id, DemotionReason.prunerDecision);

      final row = db.select('SELECT COUNT(*) AS n FROM nodes WHERE id = ?',
          <Object?>[id.toString()]);
      expect(row.first['n'], equals(1));
    });

    // ─── NodeLifecycleManager.forget ───────────────────────────────

    test('forget writes a Tombstone, indexes it, removes the live row',
        () async {
      final id = await persistClaim(text: 'remove me', key: 'k1');
      final preCount = db.select('SELECT COUNT(*) AS n FROM nodes')
          .first['n'] as int;
      expect(preCount, equals(1));

      await lifecycle.forget(id, ForgetReason.userRequested);

      // Live row is gone.
      expect(await reader.get(id), isNull);

      // Exactly one row remains — the Tombstone.
      final remaining = db.select(
        'SELECT id, type_name, attrs_json, idempotency_key FROM nodes',
      );
      expect(remaining, hasLength(1));
      final tombRow = remaining.first;
      expect(tombRow['type_name'], equals('Tombstone'));
      expect(tombRow['idempotency_key'], equals('tombstone:${id.toString()}'));

      final attrs = jsonDecode(tombRow['attrs_json'] as String) as Map;
      expect(attrs['reason'], equals('userRequested'));
      expect(attrs['forgotten_at'], equals(fakeNow.toIso8601String()));

      // The tombstones_index row points the forgotten id at the
      // Tombstone and preserves the original type name.
      final idx = db.select('SELECT * FROM tombstones_index');
      expect(idx, hasLength(1));
      expect(idx.first['forgotten_node_id'], equals(id.toString()));
      expect(idx.first['tombstone_node_id'], equals(tombRow['id']));
      expect(idx.first['forgotten_type'], equals('Claim'));
      expect(idx.first['reason'], equals('userRequested'));
    });

    test('forget on a non-existent id is a no-op', () async {
      final unknown = NodeId.generate();
      await lifecycle.forget(unknown, ForgetReason.userRequested);
      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(0));
      expect(db.select('SELECT COUNT(*) AS n FROM tombstones_index')
              .first['n'],
          equals(0));
    });

    test('forget on an already-forgotten id does not chain Tombstones',
        () async {
      final id = await persistClaim(text: 'x', key: 'k1');
      await lifecycle.forget(id, ForgetReason.userRequested);

      // After the first forget: exactly one Tombstone.
      final afterFirst = db.select(
              'SELECT COUNT(*) AS n FROM nodes WHERE type_name = ?',
              <Object?>['Tombstone'])
          .first['n'] as int;
      expect(afterFirst, equals(1));

      // Second forget on the same (now-gone) id: no new Tombstone.
      await lifecycle.forget(id, ForgetReason.userRequested);

      final afterSecond = db.select(
              'SELECT COUNT(*) AS n FROM nodes WHERE type_name = ?',
              <Object?>['Tombstone'])
          .first['n'] as int;
      expect(afterSecond, equals(1));

      // tombstones_index still has just one entry.
      expect(
          db.select('SELECT COUNT(*) AS n FROM tombstones_index')
              .first['n'],
          equals(1));
    });

    test('forget on a demoted node still writes a Tombstone', () async {
      final id = await persistClaim(text: 'x', key: 'k1');
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      await lifecycle.forget(id, ForgetReason.legalErasure);

      expect(await reader.get(id), isNull);
      final tombs = db.select(
        "SELECT attrs_json FROM nodes WHERE type_name = 'Tombstone'",
      );
      expect(tombs, hasLength(1));
      final attrs = jsonDecode(tombs.first['attrs_json'] as String) as Map;
      expect(attrs['reason'], equals('legalErasure'));
    });

    test('forget clears pending vector writes for the forgotten id',
        () async {
      // Arrange: simulate a leftover pending-write row for the
      // forgotten id (the normal protocol deletes the row at step 6
      // of `persistNodeWithVector`, but a crash between the COMMIT
      // and the DELETE — or a future delete-vector path — could
      // leave one in place. We insert one directly to exercise the
      // cleanup branch.).
      final id = await persistClaim(text: 'x', key: 'k1');
      db.execute(
        'INSERT INTO pending_vector_writes ('
        'node_id, embedding_model_id, payload_blob, payload_dims, '
        'enqueued_at_ms, enqueued_at_iso) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>[
          id.toString(),
          'nomic-embed-text@v1.5',
          Uint8List(768 * 4),
          768,
          fakeNow.millisecondsSinceEpoch,
          fakeNow.toIso8601String(),
        ],
      );
      expect(coordinator.pendingCount(), equals(1));

      await lifecycle.forget(id, ForgetReason.userRequested);

      // Pending row is gone — no orphan.
      expect(coordinator.pendingCount(), equals(0));
    });

    test('Tombstone is reachable by its own NodeId via get', () async {
      final id = await persistClaim(text: 'x', key: 'k1');
      await lifecycle.forget(id, ForgetReason.userRequested);

      final tombRow = db
          .select(
              "SELECT id FROM nodes WHERE type_name = 'Tombstone' LIMIT 1")
          .first;
      final tombstoneId = NodeId.fromString(tombRow['id'] as String);

      final tomb = await reader.get(tombstoneId);
      expect(tomb, isNotNull);
      expect(tomb!.typeName, equals('Tombstone'));
      expect(tomb.status, equals(NodeStatus.active));
      expect(tomb.values['reason'], equals('userRequested'));
    });

    test('lookupTombstone resolves a forgotten id to its Tombstone',
        () async {
      final id = await persistClaim(text: 'x', key: 'k1');
      expect(lookupTombstone(db, id), isNull);

      await lifecycle.forget(id, ForgetReason.scopeViolation);
      final entry = lookupTombstone(db, id);

      expect(entry, isNotNull);
      expect(entry!.forgottenNodeId, equals(id));
      expect(entry.forgottenType, equals('Claim'));
      expect(entry.reason, equals('scopeViolation'));
      expect(entry.forgottenAt, equals(fakeNow));
    });

    // ─── A.38 — NodeDemoted / NodeForgotten event emission ─────────

    test('demote emits NodeDemoted on the active → demoted transition',
        () async {
      final id = await persistClaim(text: 'd', key: 'k-d');
      // Drain the NodePersisted event emitted by persistClaim so the
      // assertion below isolates the demote-side emission.
      final beforeDemote = events.length;

      fakeNow = DateTime.utc(2026, 5, 30, 15, 0, 0);
      await lifecycle.demote(id, DemotionReason.prunerDecision);

      final lifecycleEvents = events.sublist(beforeDemote);
      expect(lifecycleEvents, hasLength(1));
      final ev = lifecycleEvents.single;
      expect(ev, isA<NodeDemoted>());
      final demoted = ev as NodeDemoted;
      expect(demoted.nodeId, equals(id));
      expect(demoted.typeName, equals('Claim'));
      expect(demoted.reason, equals(DemotionReason.prunerDecision));
      expect(demoted.occurredAt, equals(fakeNow));
      expect(demoted.kind, equals('memory.node-demoted'));
      expect(
        demoted.payloadJson(),
        equals(<String, Object?>{
          'nodeId': id.toString(),
          'typeName': 'Claim',
          'reason': 'prunerDecision',
        }),
      );
    });

    test('demote is silent on no-op (already-demoted, missing)', () async {
      final id = await persistClaim(text: 'x', key: 'k-noop');
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      final afterFirstDemote = events.length;

      // Second demote at a later wall-clock — must NOT emit a second
      // NodeDemoted (no transition).
      fakeNow = DateTime.utc(2026, 5, 30, 16, 0, 0);
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      expect(events.length, equals(afterFirstDemote));

      // Demote against a never-existed id — also silent.
      final unknown = NodeId.generate();
      await lifecycle.demote(unknown, DemotionReason.prunerDecision);
      expect(events.length, equals(afterFirstDemote));
    });

    test('forget emits NodeForgotten on the Tombstone commit', () async {
      final id = await persistClaim(text: 'gone', key: 'k-f');
      final beforeForget = events.length;

      fakeNow = DateTime.utc(2026, 5, 30, 17, 0, 0);
      await lifecycle.forget(id, ForgetReason.userRequested);

      final lifecycleEvents = events.sublist(beforeForget);
      expect(lifecycleEvents, hasLength(1));
      final ev = lifecycleEvents.single;
      expect(ev, isA<NodeForgotten>());
      final forgotten = ev as NodeForgotten;

      // The Tombstone id in the event must match the actual row in
      // `tombstones_index` — that table is the SQL-side audit trail
      // and the event is its observability twin; they must agree.
      final indexed = lookupTombstone(db, id);
      expect(indexed, isNotNull);
      expect(forgotten.forgottenNodeId, equals(id));
      expect(forgotten.tombstoneNodeId, equals(indexed!.tombstoneNodeId));
      expect(forgotten.forgottenType, equals('Claim'));
      expect(forgotten.reason, equals(ForgetReason.userRequested));
      expect(forgotten.occurredAt, equals(fakeNow));
      expect(forgotten.kind, equals('memory.node-forgotten'));
      expect(
        forgotten.payloadJson(),
        equals(<String, Object?>{
          'forgottenNodeId': id.toString(),
          'tombstoneNodeId': indexed.tombstoneNodeId.toString(),
          'forgottenType': 'Claim',
          'reason': 'userRequested',
        }),
      );
    });

    test('forget is silent on no-op (unknown, already-forgotten)', () async {
      // Unknown id — no Tombstone, no event.
      final beforeUnknown = events.length;
      await lifecycle.forget(NodeId.generate(), ForgetReason.userRequested);
      expect(events.length, equals(beforeUnknown));

      // Already-forgotten id — first forget emits, second is silent.
      final id = await persistClaim(text: 'twice', key: 'k-twice');
      await lifecycle.forget(id, ForgetReason.userRequested);
      final afterFirstForget = events.length;
      await lifecycle.forget(id, ForgetReason.userRequested);
      expect(events.length, equals(afterFirstForget));
    });

    test('forget on a demoted node emits NodeForgotten with the post-demote '
        'type name and the supplied reason', () async {
      final id = await persistClaim(text: 'd-then-f', key: 'k-d-f');
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      final beforeForget = events.length;

      await lifecycle.forget(id, ForgetReason.legalErasure);

      final lifecycleEvents = events.sublist(beforeForget);
      expect(lifecycleEvents, hasLength(1));
      final forgotten = lifecycleEvents.single as NodeForgotten;
      // The forgotten type must be the original Claim, not the
      // status — demote changes status, not type_name.
      expect(forgotten.forgottenType, equals('Claim'));
      expect(forgotten.reason, equals(ForgetReason.legalErasure));
    });
  });
}

// ─── Fixtures ───────────────────────────────────────────────────

NodeTypeDecl _validClaim() => NodeTypeDecl(
      typeName: 'Claim',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'text': const FieldSpec(
          name: 'text',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['text'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'text'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

NodeTypeDecl _validTombstone() => NodeTypeDecl(
      typeName: 'Tombstone',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'reason': const FieldSpec(name: 'reason', type: FieldType.string),
        'forgotten_at':
            const FieldSpec(name: 'forgotten_at', type: FieldType.string),
      },
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: IndexPolicy.indexNothing,
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

final class _RecordingVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> calls = <PendingVectorWrite>[];

  @override
  void apply(PendingVectorWrite write) {
    calls.add(write);
  }
}
