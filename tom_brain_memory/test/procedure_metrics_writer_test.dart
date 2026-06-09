// Todo 7 (G-PR5) — ProcedureMetricsWriter contract tests
// (`procedure_specification.md` § 6.4, § 7.1).
//
// The metrics pass (`dream_procedure_metrics_v1`) maintains a Procedure node's
// derived cache — `successRate` / `runCount` / `lastRunAt` and the
// `active ⇄ preferred` stage — through one narrow in-place write. These tests
// pin that write against the in-memory db harness (no vec0 binary needed):
//
//   * Only the supplied fields change; the rest of the node's values are
//     preserved (it is a merge, not a replace).
//   * The `nodes.updated_at_ms` column is bumped.
//   * A write against a non-`Procedure` node is refused (the type guard is the
//     immutability protection — it cannot be turned against a Claim/Event).
//   * A write against a missing id is a no-op (a concurrent forget is not a
//     failure), mirroring `NodeLifecycleManager.demote`.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainTime,
        BrainVersion,
        FixedClock,
        NodeId,
        NodeStatus,
        ProcedureStatus,
        Scope;

void main() {
  group('G-PR5 ProcedureMetricsWriter', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late NodeReader reader;
    late ProcedureMetricsWriter metrics;
    late DateTime fakeNow;
    late int idCounter;

    NodeId mintId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
      );
    }

    setUp(() async {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      idCounter = 0;
      fakeNow = DateTime.utc(2026, 6, 1, 9, 0, 0);
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: _NoopVectorApplier(),
        clock: FixedClock(BrainTime.utc(2026, 6, 1, 9, 0, 0)),
      );

      var regId = 2000;
      NodeId mintRegistryId() {
        regId += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness: List<int>.generate(16, (i) => (regId + i) & 31),
        );
      }

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_procedureType());
      await registry.registerNodeType(_claimType());

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
      );
      reader = NodeReader(memoryDb: db);
      metrics = ProcedureMetricsWriter(
        memoryDb: db,
        now: () => fakeNow,
      );
    });

    tearDown(() => db.dispose());

    Future<NodeId> persistProcedure() => persister.persist(
          NodeDraft(
            typeName: 'Procedure',
            values: <String, Object?>{
              'name': 'greet_user_v1',
              'summary': 'Greet the user',
              'code': 'run() {}',
              'status': 'active',
              'revision': 1,
              'requires': <String>['recall', 'note'],
            },
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'proc-1'),
        );

    test('writes back the cached metrics, preserving the other fields',
        () async {
      final id = await persistProcedure();
      fakeNow = DateTime.utc(2026, 6, 1, 10, 0, 0);

      await metrics.updateProcedureMetrics(
        id,
        status: ProcedureStatus.preferred,
        successRate: 0.875,
        runCount: 8,
        lastRunAt: DateTime.utc(2026, 6, 1, 9, 30, 0),
      );

      final node = (await reader.get(id))!;
      expect(node.values['status'], equals('preferred'));
      expect((node.values['successRate'] as num).toDouble(), closeTo(0.875, 1e-9));
      expect(node.values['runCount'], equals(8));
      expect(node.values['lastRunAt'],
          equals(DateTime.utc(2026, 6, 1, 9, 30, 0).toIso8601String()));
      // Untouched fields survive the merge.
      expect(node.values['name'], equals('greet_user_v1'));
      expect(node.values['revision'], equals(1));
      expect(node.values['requires'], equals(<String>['recall', 'note']));
      // Still a live node (the cache write is not a lifecycle demote).
      expect(node.status, equals(NodeStatus.active));
    });

    test('only the supplied fields change', () async {
      final id = await persistProcedure();
      await metrics.updateProcedureMetrics(id, successRate: 0.5, runCount: 2);

      final node = (await reader.get(id))!;
      // status untouched — still the authored 'active'.
      expect(node.values['status'], equals('active'));
      expect((node.values['successRate'] as num).toDouble(), closeTo(0.5, 1e-9));
      expect(node.values['runCount'], equals(2));
      expect(node.values['lastRunAt'], isNull);
    });

    test('bumps updated_at_ms', () async {
      final id = await persistProcedure();
      final before = db.select(
        'SELECT updated_at_ms FROM nodes WHERE id = ?',
        <Object?>[id.toString()],
      ).first['updated_at_ms'] as int;

      fakeNow = DateTime.utc(2026, 6, 2, 9, 0, 0);
      await metrics.updateProcedureMetrics(id, runCount: 1);

      final after = db.select(
        'SELECT updated_at_ms FROM nodes WHERE id = ?',
        <Object?>[id.toString()],
      ).first['updated_at_ms'] as int;
      expect(after, greaterThan(before));
    });

    test('refuses a non-Procedure node (immutability guard)', () async {
      final claimId = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': 'the sky is blue'},
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'claim-1'),
      );

      expect(
        () => metrics.updateProcedureMetrics(claimId, successRate: 1.0),
        throwsArgumentError,
      );
      // The Claim's values are untouched by the refused write.
      final claim = (await reader.get(claimId))!;
      expect(claim.values['text'], equals('the sky is blue'));
      expect(claim.values.containsKey('successRate'), isFalse);
    });

    test('is a no-op on a missing id', () async {
      final unknown = NodeId.generate();
      // Should not throw.
      await metrics.updateProcedureMetrics(unknown, runCount: 3);
      expect(await reader.get(unknown), isNull);
    });
  });
}

NodeTypeDecl _procedureType() => NodeTypeDecl(
      typeName: 'Procedure',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'name': const FieldSpec(
            name: 'name', type: FieldType.string, ftsEligible: true),
        'summary': const FieldSpec(
            name: 'summary', type: FieldType.string, ftsEligible: true),
        'code': const FieldSpec(name: 'code', type: FieldType.string),
        'status': const FieldSpec(
            name: 'status', type: FieldType.string, nullable: true),
        'revision': const FieldSpec(
            name: 'revision', type: FieldType.integer, nullable: true),
        'requires': const FieldSpec(
            name: 'requires', type: FieldType.json, nullable: true),
        'successRate': const FieldSpec(
            name: 'successRate', type: FieldType.json, nullable: true),
        'runCount': const FieldSpec(
            name: 'runCount', type: FieldType.integer, nullable: true),
        'lastRunAt': const FieldSpec(
            name: 'lastRunAt', type: FieldType.string, nullable: true),
        'authoredAt': const FieldSpec(
            name: 'authoredAt', type: FieldType.string, nullable: true),
      },
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'name', 'summary'},
        vectorFields: <String>{},
      ),
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{EdgeType.supersededBy},
      allowedIncoming: const <EdgeType>{EdgeType.supersededBy},
    );

NodeTypeDecl _claimType() => NodeTypeDecl(
      typeName: 'Claim',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'text': const FieldSpec(
            name: 'text', type: FieldType.string, ftsEligible: true),
      },
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'text'},
        vectorFields: <String>{},
      ),
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

final class _NoopVectorApplier implements VectorApplier {
  @override
  void apply(PendingVectorWrite write) {}
}
