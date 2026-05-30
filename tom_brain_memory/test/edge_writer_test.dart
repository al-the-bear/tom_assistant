// A.36 — EdgeWriter contract test.
//
// Covers `EdgeWriter.edge` end-to-end against a real in-memory SQLite
// engine. Validates the full refusal matrix (missing endpoints,
// unregistered type, allowedOutgoing rejection, allowedIncoming
// rejection) plus the success paths (attrs, weights, event payload).
//
// Coverage map (one `test(...)` per row):
//
//   Success paths
//   -------------
//   * Happy path: Claim --derived_from--> Source inserts a row,
//     emits `EdgeCreated` with the resolved type names, returns a
//     fresh `EdgeId`.
//   * Default weight is 1.0 and `attrs_json` is NULL when no attrs
//     supplied; both surface correctly on the event.
//   * Non-empty `attrs` (e.g. `{'kind': 'depends_on'}`) round-trips
//     into the row as JSON and onto the event.
//   * Custom `weight` round-trips into the row and onto the event.
//   * Multiple edges between the same two nodes get distinct ids
//     and produce distinct rows (no uniqueness constraint).
//
//   Permission rejections
//   ---------------------
//   * Edge label not in from-type's `allowedOutgoing` →
//     `EdgeNotPermitted` (side=from), `EdgeRejected` event with
//     reason=`notInAllowedOutgoing`, no row inserted.
//   * Edge label not in to-type's `allowedIncoming` →
//     `EdgeNotPermitted` (side=to), `EdgeRejected` event with
//     reason=`notInAllowedIncoming`, no row inserted.
//
//   Endpoint rejections
//   -------------------
//   * `from` node not in `nodes` → `EdgeEndpointMissing` (side=from),
//     `EdgeRejected` with reason=`fromEndpointMissing`.
//   * `to` node not in `nodes` → `EdgeEndpointMissing` (side=to),
//     `EdgeRejected` with reason=`toEndpointMissing`.
//   * When both endpoints are missing, the from-side rejection
//     takes precedence (short-circuit).
//
//   Integrity tripwire
//   ------------------
//   * A node row exists with a `type_name` whose decl was removed
//     from the registry cache → `UnknownNodeTypeForEdge`,
//     `EdgeRejected` with the unregistered type reason.
//
// The writer is tested without going through `SqliteTomBrainMemory`
// (which doesn't exist yet — that class composes per-operation
// owners). Tests construct the writer directly using the
// already-tested `NodePersister` (A.34) for fixture nodes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, EdgeId, FixedClock, NodeId, Vec;

void main() {
  group('A.36 EdgeWriter.edge', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
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

    EdgeId mintEdgeId() {
      edgeIdCounter += 1;
      return EdgeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (edgeIdCounter * 7 + i) & 31),
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

      // Registry: separate id stream so registry decl-node ids never
      // collide with persister-minted node ids.
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
      await registry.registerNodeType(_validSource());
      await registry.registerNodeType(_validConclusion());
      await registry.registerNodeType(_validPlanStep());

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        // Persister events are noise for these tests — discard.
      );
    });

    tearDown(() {
      db.dispose();
    });

    EdgeWriter buildWriter() {
      return EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
    }

    Future<NodeId> persistClaim(String text, {required String key}) async {
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: key.hashCode),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    Future<NodeId> persistSource(String url, {required String key}) async {
      return persister.persist(
        NodeDraft(
          typeName: 'Source',
          values: <String, Object?>{'url': url},
          embedding: _v768(seed: key.hashCode + 7),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    Future<NodeId> persistConclusion(String text, {required String key}) async {
      return persister.persist(
        NodeDraft(
          typeName: 'Conclusion',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: key.hashCode + 13),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    Future<NodeId> persistPlanStep(String label, {required String key}) async {
      return persister.persist(
        NodeDraft(
          typeName: 'PlanStep',
          values: <String, Object?>{'label': label},
          embedding: _v768(seed: key.hashCode + 19),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    int edgeCount() =>
        db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;

    // ─── Success paths ───────────────────────────────────────────────

    test('commits a fresh edge and emits EdgeCreated', () async {
      final writer = buildWriter();
      final claim = await persistClaim('the sky is blue', key: 'kc1');
      final source = await persistSource('https://example.org/a', key: 'ks1');

      final id =
          await writer.edge(claim, EdgeType.derivedFrom, source);

      // Row in edges.
      final rows = db.select(
        'SELECT * FROM edges WHERE id = ?',
        <Object?>[id.toString()],
      );
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row['from_node'], equals(claim.toString()));
      expect(row['to_node'], equals(source.toString()));
      expect(row['type'], equals('derived_from'));
      expect((row['weight'] as num).toDouble(), equals(1.0));
      expect(row['attrs_json'], isNull);
      expect(row['produced_by'], isNull);
      expect(row['created_at_ms'], equals(fakeNow.millisecondsSinceEpoch));

      // Event emitted with resolved type names.
      expect(events, hasLength(1));
      final ev = events.single as EdgeCreated;
      expect(ev.edgeId, equals(id));
      expect(ev.from, equals(claim));
      expect(ev.to, equals(source));
      expect(ev.type, equals(EdgeType.derivedFrom));
      expect(ev.fromTypeName, equals('Claim'));
      expect(ev.toTypeName, equals('Source'));
      expect(ev.weight, equals(1.0));
      expect(ev.attrs, isEmpty);
      expect(ev.kind, equals('memory.edge-created'));
      expect(ev.occurredAt, equals(fakeNow));
    });

    test('non-empty attrs round-trip into row and event', () async {
      final writer = buildWriter();
      final s1 = await persistPlanStep('compile', key: 'ps1');
      final s2 = await persistPlanStep('run-tests', key: 'ps2');

      final attrs = <String, Object?>{'kind': 'depends_on'};
      final id = await writer.edge(s2, EdgeType.partOf, s1, attrs: attrs);

      final row = db
          .select('SELECT attrs_json FROM edges WHERE id = ?',
              <Object?>[id.toString()])
          .first;
      final attrsJson = row['attrs_json'] as String;
      expect(jsonDecode(attrsJson), equals(<String, Object?>{'kind': 'depends_on'}));

      final ev = events.whereType<EdgeCreated>().single;
      expect(ev.attrs, equals(<String, Object?>{'kind': 'depends_on'}));
      expect(ev.payloadJson()['attrs'], equals(<String, Object?>{'kind': 'depends_on'}));
    });

    test('custom weight round-trips into row and event', () async {
      final writer = buildWriter();
      final claim = await persistClaim('first', key: 'cw1');
      final conclusion = await persistConclusion('summary', key: 'kw1');

      await writer.edge(
        claim,
        EdgeType.evidenceFor,
        conclusion,
        weight: 0.42,
      );

      final row =
          db.select('SELECT weight FROM edges').first;
      expect((row['weight'] as num).toDouble(), closeTo(0.42, 1e-9));

      final ev = events.whereType<EdgeCreated>().single;
      expect(ev.weight, closeTo(0.42, 1e-9));
    });

    test('multiple edges between same endpoints get distinct ids',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('only', key: 'cm1');
      final source = await persistSource('https://example.org/b', key: 'sm1');

      final id1 =
          await writer.edge(claim, EdgeType.derivedFrom, source);
      final id2 =
          await writer.edge(claim, EdgeType.derivedFrom, source);

      expect(id1, isNot(equals(id2)));
      expect(edgeCount(), equals(2));
      expect(events.whereType<EdgeCreated>().length, equals(2));
    });

    test('composite indexes accept the inserts (smoke check on planner)',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('seed', key: 'ci1');
      final source = await persistSource('https://example.org/c', key: 'si1');
      await writer.edge(claim, EdgeType.derivedFrom, source);

      // EXPLAIN QUERY PLAN should pick one of the composite indexes
      // rather than a SCAN. We don't assert the exact plan — that's
      // SQLite version-dependent — but we do require that *no*
      // "SCAN edges" appears.
      final rows = db.select(
        "EXPLAIN QUERY PLAN SELECT * FROM edges WHERE from_node = ? AND type = ?",
        <Object?>[claim.toString(), 'derived_from'],
      );
      final detail = rows.map((r) => r['detail'] as String).join(' | ');
      expect(detail, isNot(contains('SCAN edges')));
    });

    // ─── Permission rejections ───────────────────────────────────────

    test('label not in from-type allowedOutgoing → EdgeNotPermitted (from)',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('forbidden src', key: 'kp1');
      final source = await persistSource('https://example.org/d', key: 'sp1');

      // Claim.allowedOutgoing only contains derivedFrom. Try mentions.
      await expectLater(
        writer.edge(claim, EdgeType.mentions, source),
        throwsA(isA<EdgeNotPermitted>()
            .having((e) => e.side, 'side', EdgeEndpointSide.from)
            .having((e) => e.rejectingTypeName, 'rejecting', 'Claim')
            .having((e) => e.reason, 'reason',
                EdgeRejectionReason.notInAllowedOutgoing)),
      );

      expect(edgeCount(), equals(0));
      final ev = events.whereType<EdgeRejected>().single;
      expect(ev.reason, equals(EdgeRejectionReason.notInAllowedOutgoing));
      expect(ev.fromTypeName, equals('Claim'));
      expect(ev.toTypeName, equals('Source'));
      expect(ev.kind, equals('memory.edge-rejected'));
    });

    test('label not in to-type allowedIncoming → EdgeNotPermitted (to)',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('src ok', key: 'kp2');
      final source = await persistSource('https://example.org/e', key: 'sp2');

      // Happy-path seed so we have one edge to count against later.
      // Source's allowedIncoming includes derivedFrom, so this passes.
      await writer.edge(claim, EdgeType.derivedFrom, source);

      // To exercise the to-side rejection we pick a different pair:
      // PlanStep --motivates--> PlanStep. PlanStep.allowedOutgoing
      // includes motivates, but PlanStep.allowedIncoming does NOT.
      final s1 = await persistPlanStep('build', key: 'pl1');
      final s2 = await persistPlanStep('deploy', key: 'pl2');

      await expectLater(
        writer.edge(s1, EdgeType.motivates, s2),
        throwsA(isA<EdgeNotPermitted>()
            .having((e) => e.side, 'side', EdgeEndpointSide.to)
            .having((e) => e.rejectingTypeName, 'rejecting', 'PlanStep')
            .having((e) => e.reason, 'reason',
                EdgeRejectionReason.notInAllowedIncoming)),
      );

      // Only the successful first insert remains; the second was
      // rejected.
      expect(edgeCount(), equals(1));
      final rejected = events.whereType<EdgeRejected>().single;
      expect(rejected.reason,
          equals(EdgeRejectionReason.notInAllowedIncoming));
      expect(rejected.fromTypeName, equals('PlanStep'));
      expect(rejected.toTypeName, equals('PlanStep'));
    });

    // ─── Endpoint rejections ─────────────────────────────────────────

    test('from-node missing → EdgeEndpointMissing (from)', () async {
      final writer = buildWriter();
      final source = await persistSource('https://example.org/f', key: 'sm2');
      final phantom = NodeId.generate();

      await expectLater(
        writer.edge(phantom, EdgeType.derivedFrom, source),
        throwsA(isA<EdgeEndpointMissing>()
            .having((e) => e.side, 'side', EdgeEndpointSide.from)
            .having((e) => e.reason, 'reason',
                EdgeRejectionReason.fromEndpointMissing)),
      );
      expect(edgeCount(), equals(0));
      final rejected = events.whereType<EdgeRejected>().single;
      expect(rejected.reason, equals(EdgeRejectionReason.fromEndpointMissing));
      expect(rejected.fromTypeName, isNull);
      expect(rejected.toTypeName, isNull);
    });

    test('to-node missing → EdgeEndpointMissing (to)', () async {
      final writer = buildWriter();
      final claim = await persistClaim('first', key: 'cmis1');
      final phantom = NodeId.generate();

      await expectLater(
        writer.edge(claim, EdgeType.derivedFrom, phantom),
        throwsA(isA<EdgeEndpointMissing>()
            .having((e) => e.side, 'side', EdgeEndpointSide.to)),
      );
      expect(edgeCount(), equals(0));
      final rejected = events.whereType<EdgeRejected>().single;
      expect(rejected.reason, equals(EdgeRejectionReason.toEndpointMissing));
    });

    test('both endpoints missing → from-side rejection wins', () async {
      final writer = buildWriter();
      final ghostA = NodeId.generate();
      final ghostB = NodeId.generate();
      await expectLater(
        writer.edge(ghostA, EdgeType.derivedFrom, ghostB),
        throwsA(isA<EdgeEndpointMissing>()
            .having((e) => e.side, 'side', EdgeEndpointSide.from)),
      );
      expect(events.whereType<EdgeRejected>().single.reason,
          equals(EdgeRejectionReason.fromEndpointMissing));
    });

    // ─── Integrity tripwire ──────────────────────────────────────────

    test('node row references an unregistered type → '
        'UnknownNodeTypeForEdge', () async {
      final writer = buildWriter();
      final claim = await persistClaim('seed', key: 'ku1');
      final source = await persistSource('https://example.org/g', key: 'su1');

      // Manually corrupt the from-node to carry an unregistered
      // type_name. This is the integrity-tripwire scenario.
      db.execute(
        'UPDATE nodes SET type_name = ? WHERE id = ?',
        <Object?>['NotRegistered', claim.toString()],
      );

      await expectLater(
        writer.edge(claim, EdgeType.derivedFrom, source),
        throwsA(isA<UnknownNodeTypeForEdge>()
            .having((e) => e.side, 'side', EdgeEndpointSide.from)
            .having((e) => e.unknownTypeName, 'type', 'NotRegistered')
            .having((e) => e.reason, 'reason',
                EdgeRejectionReason.fromEndpointTypeUnregistered)),
      );
      expect(edgeCount(), equals(0));
      final rejected = events.whereType<EdgeRejected>().single;
      expect(rejected.reason,
          equals(EdgeRejectionReason.fromEndpointTypeUnregistered));
    });

    // ─── Event payload shape ─────────────────────────────────────────

    test('EdgeCreated.payloadJson carries the wire-name and types',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('p', key: 'kpj1');
      final source = await persistSource('https://example.org/h', key: 'spj1');
      final id =
          await writer.edge(claim, EdgeType.derivedFrom, source, weight: 0.5);

      final payload =
          events.whereType<EdgeCreated>().single.payloadJson();
      expect(payload['edgeId'], equals(id.toString()));
      expect(payload['type'], equals('derived_from'));
      expect(payload['fromTypeName'], equals('Claim'));
      expect(payload['toTypeName'], equals('Source'));
      expect(payload['weight'], equals(0.5));
      expect(payload.containsKey('attrs'), isFalse);
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

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
      // Claim emits derivedFrom AND evidenceFor.
      allowedOutgoing: const <EdgeType>{
        EdgeType.derivedFrom,
        EdgeType.evidenceFor,
      },
      // Claim receives evidenceFor only (e.g. Source --evidenceFor--> Claim).
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

NodeTypeDecl _validSource() => NodeTypeDecl(
      typeName: 'Source',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'url': const FieldSpec(
          name: 'url',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['url'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'url'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.evidenceFor},
      // Source receives derivedFrom (a Claim derives from a Source).
      allowedIncoming: const <EdgeType>{EdgeType.derivedFrom},
    );

NodeTypeDecl _validConclusion() => NodeTypeDecl(
      typeName: 'Conclusion',
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
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      // Conclusion receives evidenceFor (Claim --evidenceFor--> Conclusion).
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

/// PlanStep: tests `motivates` outgoing without `motivates` incoming,
/// so the to-side permission check can fire.
NodeTypeDecl _validPlanStep() => NodeTypeDecl(
      typeName: 'PlanStep',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'label': const FieldSpec(
          name: 'label',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['label'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'label'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      // Outgoing: partOf (for plan membership + depends_on attr) and
      // motivates (a plan step can motivate research).
      allowedOutgoing: const <EdgeType>{
        EdgeType.partOf,
        EdgeType.motivates,
      },
      // Incoming: only partOf (plan-step dependencies via attrs.kind).
      // Deliberately omits motivates so the to-side check can fire.
      allowedIncoming: const <EdgeType>{EdgeType.partOf},
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
