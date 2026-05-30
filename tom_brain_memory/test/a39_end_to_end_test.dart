// A.39 — end-to-end thread test across A.32–A.38.
//
// Per `prototype_implementation_plan.md` step A.39:
//
//   "Tests: bootstrap type load, idempotent persist, edge alphabet
//    enforcement, demote-then-forget chain produces correct Tombstone."
//
// This file is the integration cross-check for the work landed at
// A.32–A.38. Each per-component test (`bootstrap_node_types_test`,
// `node_type_yaml_loader_test`, `node_type_registry_test`,
// `node_persister_test`, `node_lifecycle_test`, `edge_writer_test`,
// `edge_reader_test`) already covers its surface in isolation. A.39
// wires them together along the four spec-named threads and asserts
// the *thread-level* invariants — the ones that only surface when
// the bootstrap manifest, the registry, the persister, the edge
// writer, and the lifecycle manager all share the same SQLite
// instance.
//
// Coverage map (one `test(...)` per row):
//
//   Bootstrap type load
//   -------------------
//   * loadBootstrapManifest() returns 21 NodeTypeDecls.
//   * All 21 register through NodeTypeRegistry without rejection.
//   * Every registered type is reachable through registry.get() and
//     surfaces in registry.listNodeTypes() with version 1.
//   * Each declared `allowed_outgoing` / `allowed_incoming` wire-name
//     parses to a valid EdgeType — i.e. the closed 12-edge alphabet
//     is the only one ever used in the manifest.
//
//   Idempotent persist
//   ------------------
//   * Persist with idempotency key K returns id X; second persist with
//     the same key returns the same id X with no second row written,
//     no second NodePersisted event emitted, no second vector-applier
//     call.
//   * Persist with a different key writes a fresh row and a fresh id.
//   * Different draft contents under the same key still return the
//     original id (the key is the contract, not the content).
//
//   Edge alphabet enforcement
//   -------------------------
//   * A permitted edge from the bootstrap allowed-set commits and
//     emits EdgeCreated.
//   * An edge whose label is not in the from-type's allowedOutgoing
//     throws EdgeNotPermitted(side=from, reason=notInAllowedOutgoing)
//     and emits EdgeRejected; no row inserted.
//   * An edge whose label is allowed-outgoing but not in the
//     to-type's allowedIncoming throws EdgeNotPermitted(side=to,
//     reason=notInAllowedIncoming) and emits EdgeRejected.
//   * Round-trip via EdgeReader returns the committed edge in both
//     directions with the same `created_at_ms ASC, id ASC` ordering
//     the per-component test established.
//
//   Demote → forget → Tombstone
//   ---------------------------
//   * Persist a Claim → demote → forget chain produces:
//       - get(id) == null (live row gone),
//       - exactly one Tombstone row (type_name='Tombstone',
//         attrs={reason, forgotten_at}, idempotency_key
//         'tombstone:<id>'),
//       - exactly one tombstones_index row pointing the forgotten
//         id at the Tombstone with the original type name and the
//         forget reason,
//       - the Tombstone reachable by its own NodeId via
//         NodeReader.get,
//       - the emitted event sequence NodePersisted → NodeDemoted →
//         NodeForgotten with the right reasons and clock stamps,
//       - the demote reason (prunerDecision) and the forget reason
//         (userRequested) NOT muddled with each other on the
//         resulting Tombstone (the Tombstone carries the forget
//         reason).
//
// Test fixtures use the real bootstrap manifest via
// `NodeTypeYamlLoader.loadBootstrapManifest()` rather than the
// hand-rolled fixtures the per-component tests use. This is the
// thread-level guarantee that the manifest, the registry, and the
// runtime stay in lockstep.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, EdgeId, FixedClock, NodeId, Vec;

void main() {
  group('A.39 end-to-end (bootstrap → persist → edge → demote → forget)',
      () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late NodeReader reader;
    late NodeLifecycleManager lifecycle;
    late EdgeWriter edgeWriter;
    late EdgeReader edgeReader;
    late List<MemoryEvent> events;
    late int idCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;

    NodeId mintNodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
      );
    }

    NodeId mintLifecycleId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (idCounter + i + 64) & 31),
      );
    }

    EdgeId mintEdgeId() {
      edgeIdCounter += 1;
      return EdgeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(
            16, (i) => (edgeIdCounter * 7 + i) & 31),
      );
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
      edgeIdCounter = 0;
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

      // Register all 21 types from the real bootstrap manifest. This
      // is the thread-level contract — the per-component tests use
      // hand-rolled NodeTypeDecls, A.39 must use the manifest.
      final decls = await NodeTypeYamlLoader.loadBootstrapManifest();
      for (final decl in decls) {
        await registry.registerNodeType(decl);
      }

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
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
      edgeWriter = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      edgeReader = EdgeReader(memoryDb: db);
    });

    tearDown(() {
      db.dispose();
    });

    // ─── Helpers ──────────────────────────────────────────────────

    Future<NodeId> persistClaim(String statement, String key,
        {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'statement': statement},
          embedding: _v768(seed: seed),
        ),
        scope: Scope(producer: 'a39:test:r1', idempotencyKey: key),
      );
    }

    Future<NodeId> persistConclusion(
        String statement, String rationale, String key,
        {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Conclusion',
          values: <String, Object?>{
            'statement': statement,
            'rationale': rationale,
          },
          embedding: _v768(seed: seed),
        ),
        scope: Scope(producer: 'a39:test:r1', idempotencyKey: key),
      );
    }

    Future<NodeId> persistQuestion(String text, String key, {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Question',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: seed),
        ),
        scope: Scope(producer: 'a39:test:r1', idempotencyKey: key),
      );
    }

    // ═════════════════════════════════════════════════════════════
    // Bootstrap type load
    // ═════════════════════════════════════════════════════════════

    test('bootstrap manifest registers all 21 spec types', () async {
      final all = registry.listAll();
      // The setUp already registered the manifest; this asserts the
      // registry surface mirrors it.
      expect(all, hasLength(21));

      final namesFromRegistry = all.map((d) => d.typeName).toSet();
      const expected = <String>{
        'Event',
        'Claim',
        'Concept',
        'Conclusion',
        'Question',
        'Pattern',
        'Contradiction',
        'Source',
        'Plan',
        'PlanStep',
        'Artifact',
        'Procedure',
        'ProcedureRun',
        'AutomationIdea',
        'InterestItem',
        'NodeType',
        'Session',
        'Trail',
        'Stack',
        'StackEntry',
        'Tombstone',
      };
      expect(namesFromRegistry, equals(expected));

      // Every registered type's allowed-edge sets only mention labels
      // from the closed 12-edge alphabet (EdgeType). This is a
      // thread-level guarantee: a typo in the manifest that survived
      // YAML parsing must not survive registration.
      for (final decl in all) {
        // EdgeType.values is the 12-edge alphabet; the sets carry
        // EdgeType instances, so set-inclusion proves the manifest
        // round-tripped through `EdgeType.fromWireName` cleanly.
        for (final out in decl.allowedOutgoing) {
          expect(EdgeType.values, contains(out),
              reason: 'allowedOutgoing on ${decl.typeName}');
        }
        for (final inc in decl.allowedIncoming) {
          expect(EdgeType.values, contains(inc),
              reason: 'allowedIncoming on ${decl.typeName}');
        }
      }
    });

    test('every registered type is individually reachable via getNodeType',
        () async {
      for (final name in const <String>[
        'Event', 'Claim', 'Concept', 'Conclusion', 'Question', 'Pattern',
        'Contradiction', 'Source', 'Plan', 'PlanStep', 'Artifact',
        'Procedure', 'ProcedureRun', 'AutomationIdea', 'InterestItem',
        'NodeType', 'Session', 'Trail', 'Stack', 'StackEntry', 'Tombstone',
      ]) {
        final decl = registry.get(name);
        expect(decl, isNotNull, reason: 'registry.get($name)');
        expect(decl!.typeName, equals(name));
        expect(decl.version.value, equals(1),
            reason: 'bootstrap version is always 1');
      }
    });

    // ═════════════════════════════════════════════════════════════
    // Idempotent persist
    // ═════════════════════════════════════════════════════════════

    test('persist with the same idempotency key is a no-op returning '
        'the original id', () async {
      final id1 = await persistClaim('first call', 'idem-k1', seed: 7);

      // Snapshot the side-effect counters between the two calls so
      // the second-call assertion is unambiguous.
      final rowsBeforeRepeat =
          db.select('SELECT COUNT(*) AS n FROM nodes').first['n'] as int;
      final pendingBeforeRepeat = coordinator.pendingCount();
      final applierCallsBeforeRepeat = applier.calls.length;
      final eventsBeforeRepeat = events.length;

      final id2 = await persistClaim('first call', 'idem-k1', seed: 7);
      expect(id2, equals(id1),
          reason: 'idempotency key is the contract — same key returns '
              'the same id');

      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(rowsBeforeRepeat),
          reason: 'no second row');
      expect(coordinator.pendingCount(), equals(pendingBeforeRepeat),
          reason: 'no second pending vector write');
      expect(applier.calls.length, equals(applierCallsBeforeRepeat),
          reason: 'no second vector applier call');
      expect(events.length, equals(eventsBeforeRepeat),
          reason: 'no second NodePersisted event');
    });

    test('persist with a different idempotency key writes a fresh node',
        () async {
      final id1 = await persistClaim('a', 'idem-k-a', seed: 1);
      final id2 = await persistClaim('b', 'idem-k-b', seed: 2);
      expect(id2, isNot(equals(id1)));

      final rows = db.select('SELECT COUNT(*) AS n FROM nodes WHERE '
              'type_name = ?', <Object?>['Claim'])
          .first['n'] as int;
      expect(rows, equals(2));
    });

    test('persist with same key but different content still returns '
        'the original id (key is the contract, not the content)',
        () async {
      final id1 = await persistClaim('original content', 'idem-k-stable',
          seed: 11);

      final id2 = await persistClaim('different content', 'idem-k-stable',
          seed: 99);
      expect(id2, equals(id1));

      // Live row still carries the original content — the second
      // call did not overwrite.
      final stored = await reader.get(id1);
      expect(stored, isNotNull);
      expect(stored!.values['statement'], equals('original content'));
    });

    // ═════════════════════════════════════════════════════════════
    // Edge alphabet enforcement
    // ═════════════════════════════════════════════════════════════

    test('permitted edge (Claim --evidence_for--> Claim) commits and '
        'round-trips via EdgeReader', () async {
      // From the bootstrap manifest:
      //   Claim.allowed_outgoing: [evidence_for, contradicts,
      //                             derived_from, mentions]
      //   Claim.allowed_incoming: [evidence_for, contradicts,
      //                             derived_from, mentions, produced_by]
      // So Claim --evidence_for--> Claim is permitted at both ends.
      final from = await persistClaim('premise', 'k-from', seed: 1);
      final to = await persistClaim('supported claim', 'k-to', seed: 2);

      final eventsBefore = events.length;
      final edgeId =
          await edgeWriter.edge(from, EdgeType.evidenceFor, to);
      // The edge row landed.
      final row = db.select(
        'SELECT from_node, to_node, type FROM edges WHERE id = ?',
        <Object?>[edgeId.toString()],
      );
      expect(row, hasLength(1));
      expect(row.first['from_node'], equals(from.toString()));
      expect(row.first['to_node'], equals(to.toString()));
      expect(row.first['type'], equals('evidence_for'));

      // EdgeCreated event emitted with the right shape.
      final after = events.sublist(eventsBefore);
      expect(after, hasLength(1));
      expect(after.single, isA<EdgeCreated>());

      // Round-trip through EdgeReader in both directions.
      final out = await edgeReader.edgesOf(from,
          direction: EdgeDirection.outgoing);
      expect(out.map((e) => e.id).toList(), equals(<EdgeId>[edgeId]));

      final inc = await edgeReader.edgesOf(to,
          direction: EdgeDirection.incoming);
      expect(inc.map((e) => e.id).toList(), equals(<EdgeId>[edgeId]));
    });

    test('edge whose label is not in the from-type allowedOutgoing '
        'throws EdgeNotPermitted(side=from) and inserts nothing',
        () async {
      // Claim.allowed_outgoing does NOT include `motivates`.
      // (motivates lives on Question / InterestItem / AutomationIdea.)
      final from = await persistClaim('a claim', 'k-from-rej', seed: 3);
      final to = await persistQuestion('a question', 'k-to-rej', seed: 4);

      final beforeRows =
          db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;
      final beforeEvents = events.length;

      Object? caught;
      try {
        await edgeWriter.edge(from, EdgeType.motivates, to);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<EdgeNotPermitted>());
      final ex = caught as EdgeNotPermitted;
      expect(ex.side, equals(EdgeEndpointSide.from));
      expect(ex.reason, equals(EdgeRejectionReason.notInAllowedOutgoing));

      // No row, exactly one EdgeRejected event.
      expect(
          db.select('SELECT COUNT(*) AS n FROM edges').first['n'],
          equals(beforeRows));
      final after = events.sublist(beforeEvents);
      expect(after, hasLength(1));
      expect(after.single, isA<EdgeRejected>());
      expect((after.single as EdgeRejected).reason,
          equals(EdgeRejectionReason.notInAllowedOutgoing));
    });

    test('edge whose label is allowed-outgoing but not in the to-type '
        'allowedIncoming throws EdgeNotPermitted(side=to)', () async {
      // Conclusion.allowed_outgoing includes `evidence_for`, but
      // Question.allowed_incoming does NOT include `evidence_for`
      // (Question accepts: satisfied_by, mentions, derived_from).
      // So Conclusion --evidence_for--> Question is rejected
      // on the to-side, not the from-side.
      final from =
          await persistConclusion('c', 'r', 'k-from-toRej', seed: 5);
      final to = await persistQuestion('q', 'k-to-toRej', seed: 6);

      final beforeRows =
          db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;
      final beforeEvents = events.length;

      Object? caught;
      try {
        await edgeWriter.edge(from, EdgeType.evidenceFor, to);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<EdgeNotPermitted>());
      final ex = caught as EdgeNotPermitted;
      expect(ex.side, equals(EdgeEndpointSide.to));
      expect(ex.reason, equals(EdgeRejectionReason.notInAllowedIncoming));

      expect(
          db.select('SELECT COUNT(*) AS n FROM edges').first['n'],
          equals(beforeRows));
      final after = events.sublist(beforeEvents);
      expect(after, hasLength(1));
      expect(after.single, isA<EdgeRejected>());
      expect((after.single as EdgeRejected).reason,
          equals(EdgeRejectionReason.notInAllowedIncoming));
    });

    // ═════════════════════════════════════════════════════════════
    // Demote → forget → Tombstone
    // ═════════════════════════════════════════════════════════════

    test('persist → demote → forget produces a single correct Tombstone',
        () async {
      // Persist.
      final t0 = DateTime.utc(2026, 5, 30, 14, 0, 0);
      fakeNow = t0;
      final id = await persistClaim('to be forgotten', 'k-chain', seed: 21);

      // Demote at a later wall-clock.
      final tDemote = DateTime.utc(2026, 5, 30, 15, 0, 0);
      fakeNow = tDemote;
      await lifecycle.demote(id, DemotionReason.prunerDecision);

      // Sanity: get() returns the demoted node (still addressable).
      final demoted = await reader.get(id);
      expect(demoted, isNotNull);
      expect(demoted!.status, equals(NodeStatus.demoted));

      // Forget at a still-later wall-clock.
      final tForget = DateTime.utc(2026, 5, 30, 16, 0, 0);
      fakeNow = tForget;
      await lifecycle.forget(id, ForgetReason.userRequested);

      // Live row gone; get() returns null.
      expect(await reader.get(id), isNull);

      // Exactly one Tombstone row.
      final tombs = db.select(
        "SELECT id, type_name, attrs_json, idempotency_key, status "
        "FROM nodes WHERE type_name = 'Tombstone'",
      );
      expect(tombs, hasLength(1));
      final tombRow = tombs.first;
      expect(tombRow['type_name'], equals('Tombstone'));
      expect(tombRow['status'], equals('active'),
          reason: 'Tombstones are themselves active records');
      expect(tombRow['idempotency_key'],
          equals('tombstone:${id.toString()}'));

      final attrs = jsonDecode(tombRow['attrs_json'] as String)
          as Map<String, Object?>;
      // Forget reason — NOT muddled with the prior demote reason.
      expect(attrs['reason'], equals('userRequested'));
      expect(attrs['forgotten_at'], equals(tForget.toIso8601String()));

      // tombstones_index has the cross-reference row.
      final idx = db.select('SELECT * FROM tombstones_index');
      expect(idx, hasLength(1));
      expect(idx.first['forgotten_node_id'], equals(id.toString()));
      expect(idx.first['tombstone_node_id'], equals(tombRow['id']));
      expect(idx.first['forgotten_type'], equals('Claim'),
          reason: 'index preserves the original type, not "Tombstone"');
      expect(idx.first['reason'], equals('userRequested'));

      // Tombstone is reachable by its own NodeId.
      final tombstoneId =
          NodeId.fromString(tombRow['id'] as String);
      final tombstone = await reader.get(tombstoneId);
      expect(tombstone, isNotNull);
      expect(tombstone!.typeName, equals('Tombstone'));
      expect(tombstone.values['reason'], equals('userRequested'));
      expect(tombstone.values['forgotten_at'],
          equals(tForget.toIso8601String()));

      // lookupTombstone resolves the forgotten id correctly.
      final entry = lookupTombstone(db, id);
      expect(entry, isNotNull);
      expect(entry!.forgottenNodeId, equals(id));
      expect(entry.tombstoneNodeId, equals(tombstoneId));
      expect(entry.forgottenType, equals('Claim'));
      expect(entry.reason, equals('userRequested'));
      expect(entry.forgottenAt, equals(tForget));

      // Event sequence: NodePersisted → NodeDemoted → NodeForgotten,
      // exactly three lifecycle events for this id.
      final forIdEvents = events.where((e) {
        if (e is NodePersisted) return e.nodeId == id;
        if (e is NodeDemoted) return e.nodeId == id;
        if (e is NodeForgotten) return e.forgottenNodeId == id;
        return false;
      }).toList();

      expect(forIdEvents, hasLength(3));
      expect(forIdEvents[0], isA<NodePersisted>());
      expect(forIdEvents[1], isA<NodeDemoted>());
      expect(forIdEvents[2], isA<NodeForgotten>());

      final demotedEvent = forIdEvents[1] as NodeDemoted;
      expect(demotedEvent.reason, equals(DemotionReason.prunerDecision));
      expect(demotedEvent.occurredAt, equals(tDemote));

      final forgottenEvent = forIdEvents[2] as NodeForgotten;
      expect(forgottenEvent.reason, equals(ForgetReason.userRequested));
      expect(forgottenEvent.forgottenType, equals('Claim'),
          reason: 'forgotten type is the pre-forget type_name');
      expect(forgottenEvent.tombstoneNodeId, equals(tombstoneId));
      expect(forgottenEvent.occurredAt, equals(tForget));
    });

    test('forget after demote does not chain Tombstones if called twice',
        () async {
      final id = await persistClaim('once-forgotten', 'k-once', seed: 31);
      await lifecycle.demote(id, DemotionReason.prunerDecision);
      await lifecycle.forget(id, ForgetReason.userRequested);

      // Second forget — id no longer addressable, must be silent.
      final beforeRows = db.select(
              "SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Tombstone'")
          .first['n'] as int;
      final beforeIdx = db
          .select('SELECT COUNT(*) AS n FROM tombstones_index')
          .first['n'] as int;
      final beforeEvents = events.length;

      await lifecycle.forget(id, ForgetReason.legalErasure);

      expect(
          db.select(
                  "SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Tombstone'")
              .first['n'],
          equals(beforeRows),
          reason: 'no second Tombstone row');
      expect(
          db.select('SELECT COUNT(*) AS n FROM tombstones_index')
              .first['n'],
          equals(beforeIdx),
          reason: 'no duplicate tombstones_index row');
      expect(events.length, equals(beforeEvents),
          reason: 'no second NodeForgotten event');
    });
  });
}

// ─── Fixtures ───────────────────────────────────────────────────

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
