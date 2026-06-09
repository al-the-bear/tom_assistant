// A.90 / G-M2 — schema-additions contract test.
//
// Completion plan Todo 3 (`tom_brain_completion_plan.md`): the five
// "schema additions" node types — `Plan`, `PlanStep`, `Artifact`,
// `Procedure`, `ProcedureRun` — must exist, round-trip (insert → query →
// typed read), carry their spec § 4.1 key edges, and enforce the
// no-overwrite revision-chain invariant (hard principle 6) via
// `superseded_by`.
//
// These five types were declared in the bootstrap manifest at A.32, so
// `bootstrap_node_types_test` and `a39_end_to_end_test` already prove the
// manifest *declares* them. This file is the G-M2 *contract*: it pins the
// behaviour the planning / creation / procedure subsystems (Todos 7–9)
// depend on, separately from the manifest-shape tests.
//
// The revision-chain group is the load-bearing addition. A revision is
// `predecessor —superseded_by→ successor` between two nodes of the SAME
// type; both are retained and the live tip is the node with no outgoing
// `superseded_by` (memory_specification.md § 4.1 footnote †,
// procedure_specification.md lifecycle, planning_specification.md § 4.7).
// For that edge to be writable a self-superseding type must permit
// `superseded_by` in BOTH `allowedOutgoing` (predecessor emits) and
// `allowedIncoming` (successor receives) — exactly as `NodeType` does.
//
// Fixtures mirror `a39_end_to_end_test`: an in-memory SQLite store, the
// real bootstrap manifest registered through `NodeTypeRegistry`, and the
// concrete persister / reader / edge-writer / edge-reader.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, EdgeId, FixedClock, NodeId, Vec;

const _testScope = Scope.nonIdempotent(producer: 'a90-test');

void main() {
  group('A.90 / G-M2 schema-additions contract', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late NodeReader reader;
    late EdgeWriter edgeWriter;
    late EdgeReader edgeReader;
    late int idCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;

    NodeId mintNodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter * 3 + i) & 31),
      );
    }

    EdgeId mintEdgeId() {
      edgeIdCounter += 1;
      return EdgeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (edgeIdCounter * 7 + i) & 31),
      );
    }

    setUp(() async {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: _NoopVectorApplier(),
        clock: FixedClock(BrainTime.utc(2026, 6, 9, 12, 0, 0)),
      );
      idCounter = 0;
      edgeIdCounter = 0;
      fakeNow = DateTime.utc(2026, 6, 9, 12, 0, 0);

      var regIdCounter = 5000;
      NodeId mintRegistryId() {
        regIdCounter += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness: List<int>.generate(16, (i) => (regIdCounter + i) & 31),
        );
      }

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      for (final decl in await NodeTypeYamlLoader.loadBootstrapManifest()) {
        await registry.registerNodeType(decl);
      }

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: (_) {},
      );
      reader = NodeReader(memoryDb: db);
      edgeWriter = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: (_) {},
      );
      edgeReader = EdgeReader(memoryDb: db);
    });

    tearDown(() => db.dispose());

    // ─── Persist helpers (one per G-M2 type) ──────────────────────────

    Future<NodeId> persistPlan(String goal, String summary, String key,
        {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Plan',
          values: <String, Object?>{'goal': goal, 'summary': summary},
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistPlanStep(String description, int stepIndex, String key,
        {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'PlanStep',
          values: <String, Object?>{
            'description': description,
            'step_index': stepIndex,
          },
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistArtifact(String kind, String summary, String key,
        {String? contentRef, int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Artifact',
          values: <String, Object?>{
            'kind': kind,
            'summary': summary,
            'content_ref': contentRef,
          },
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistProcedure(
        String name, String summary, String code, String key,
        {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Procedure',
          values: <String, Object?>{
            'name': name,
            'summary': summary,
            'code': code,
          },
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistProcedureRun(String summary, String key) {
      return persister.persist(
        NodeDraft(
          typeName: 'ProcedureRun',
          values: <String, Object?>{
            'procedureId': 'p_a90',
            'version': 1,
            'runId': 'r_$key',
            'status': 'accepted',
            'summary': summary,
            'startedAt': '2026-06-09T12:00:00.000Z',
            'trailId': 't_a90',
          },
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistConclusion(String key, {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Conclusion',
          values: <String, Object?>{'statement': 's', 'rationale': 'r'},
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistSession(String key, {int seed = 1}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Session',
          values: <String, Object?>{
            'summary': 'a session',
            'started_at': '2026-06-09T12:00:00.000Z',
          },
          embedding: _v768(seed),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    Future<NodeId> persistEvent(String key) {
      return persister.persist(
        NodeDraft(
          typeName: 'Event',
          values: <String, Object?>{'summary': 'an event', 'payload': '{}'},
          embedding: _v768(2),
        ),
        scope: Scope(producer: 'a90', idempotencyKey: key),
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // Node round-trip — insert → query → typed read.
    // ═══════════════════════════════════════════════════════════════

    group('node round-trip', () {
      test('Plan round-trips with goal + summary', () async {
        final id = await persistPlan('ship G-M2', 'do the schema work', 'plan1');
        final node = await reader.get(id);
        expect(node, isNotNull);
        expect(node!.typeName, 'Plan');
        expect(node.values['goal'], 'ship G-M2');
        expect(node.values['summary'], 'do the schema work');
      });

      test('PlanStep round-trips with description + step_index', () async {
        final id = await persistPlanStep('write the test', 0, 'step1');
        final node = await reader.get(id);
        expect(node!.typeName, 'PlanStep');
        expect(node.values['description'], 'write the test');
        expect(node.values['step_index'], 0);
      });

      test('Artifact round-trips with kind + summary + nullable content_ref',
          () async {
        final id = await persistArtifact('dart', 'a generated file', 'art1',
            contentRef: 'lib/foo.dart');
        final node = await reader.get(id);
        expect(node!.typeName, 'Artifact');
        expect(node.values['kind'], 'dart');
        expect(node.values['summary'], 'a generated file');
        expect(node.values['content_ref'], 'lib/foo.dart');
      });

      test('Procedure round-trips with name + summary + code', () async {
        final id = await persistProcedure(
            'plan_v1', 'the planning loop', 'void main() {}', 'proc1');
        final node = await reader.get(id);
        expect(node!.typeName, 'Procedure');
        expect(node.values['name'], 'plan_v1');
        expect(node.values['code'], 'void main() {}');
      });

      test('ProcedureRun round-trips operational fields (no embedding)',
          () async {
        final id = await persistProcedureRun('a finished run', 'run1');
        final node = await reader.get(id);
        expect(node!.typeName, 'ProcedureRun');
        expect(node.values['status'], 'accepted');
        expect(node.values['runId'], 'r_run1');
        // EmbeddingPolicy.none — the row carries no embedding.
        expect(node.embedding, isNull);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Key edges — spec § 4.1 columns for the five types.
    // ═══════════════════════════════════════════════════════════════

    group('key edges', () {
      test('PlanStep —part_of→ Plan (membership) commits and round-trips',
          () async {
        final plan = await persistPlan('g', 's', 'p-mem');
        final step = await persistPlanStep('s1', 0, 'st-mem');
        final edgeId =
            await edgeWriter.edge(step, EdgeType.partOf, plan, scope: _testScope);
        final out =
            await edgeReader.edgesOf(step, direction: EdgeDirection.outgoing);
        expect(out.map((e) => e.id), equals(<EdgeId>[edgeId]));
        expect(out.single.type, EdgeType.partOf);
        expect(out.single.to, plan);
      });

      test('PlanStep —part_of{kind:depends_on}→ PlanStep round-trips the '
          'depends_on sub-shape attribute', () async {
        // Spec § 4.1 footnote: `depends_on` is a `part_of` edge carrying
        // `attrs.kind=depends_on` — no new edge label.
        final a = await persistPlanStep('compile', 0, 'st-a');
        final b = await persistPlanStep('test', 1, 'st-b');
        final edgeId = await edgeWriter.edge(
          b, EdgeType.partOf, a,
          scope: _testScope,
          attrs: <String, Object?>{'kind': 'depends_on'},
        );
        final out =
            await edgeReader.edgesOf(b, direction: EdgeDirection.outgoing);
        final edge = out.firstWhere((e) => e.id == edgeId);
        expect(edge.type, EdgeType.partOf);
        expect(edge.attrs['kind'], 'depends_on',
            reason: 'the depends_on sub-shape must round-trip in attrs');
      });

      test('Artifact —produced_by→ ProcedureRun and —satisfied_by→ Conclusion',
          () async {
        final run = await persistProcedureRun('r', 'run-art');
        final concl = await persistConclusion('concl-art');
        final artifact = await persistArtifact('doc', 'spec', 'art-edges');
        await edgeWriter.edge(artifact, EdgeType.producedBy, run,
            scope: _testScope);
        await edgeWriter.edge(artifact, EdgeType.satisfiedBy, concl,
            scope: _testScope);
        final out = await edgeReader.edgesOf(artifact,
            direction: EdgeDirection.outgoing);
        expect(out.map((e) => e.type).toSet(),
            containsAll(<EdgeType>[EdgeType.producedBy, EdgeType.satisfiedBy]));
      });

      test('Procedure —authored_by→ Session commits', () async {
        final session = await persistSession('sess-auth');
        final proc = await persistProcedure('p', 's', 'c', 'proc-auth');
        final edgeId = await edgeWriter.edge(
            proc, EdgeType.authoredBy, session, scope: _testScope);
        final out =
            await edgeReader.edgesOf(proc, direction: EdgeDirection.outgoing);
        expect(out.map((e) => e.id), contains(edgeId));
      });

      test('ProcedureRun —caused_by→ Event and —derived_from→ Event', () async {
        final event = await persistEvent('evt-run');
        final run = await persistProcedureRun('r', 'run-causal');
        await edgeWriter.edge(run, EdgeType.causedBy, event, scope: _testScope);
        await edgeWriter.edge(run, EdgeType.derivedFrom, event,
            scope: _testScope);
        final out =
            await edgeReader.edgesOf(run, direction: EdgeDirection.outgoing);
        expect(out.map((e) => e.type).toSet(),
            containsAll(<EdgeType>[EdgeType.causedBy, EdgeType.derivedFrom]));
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Revision chains — superseded_by, never overwrite (hard principle 6).
    // ═══════════════════════════════════════════════════════════════

    group('superseded_by revision chains (no-overwrite invariant)', () {
      // Helper: assert `v1 —superseded_by→ v2` is writable, both nodes
      // survive with their original content, and the live tip is v2.
      Future<void> assertRevisionChain({
        required NodeId v1,
        required NodeId v2,
        required String originalMarker,
        required String markerField,
      }) async {
        final edgeId = await edgeWriter.edge(
            v1, EdgeType.supersededBy, v2, scope: _testScope);

        // Both nodes still exist — the revision never overwrote the
        // predecessor (hard principle 6).
        final n1 = await reader.get(v1);
        final n2 = await reader.get(v2);
        expect(n1, isNotNull, reason: 'predecessor must be retained');
        expect(n2, isNotNull, reason: 'successor must exist');
        expect(n1!.values[markerField], originalMarker,
            reason: 'predecessor content is untouched by the revision');

        // The edge is the chain: v1 emits superseded_by; v2 receives it.
        final outV1 =
            await edgeReader.edgesOf(v1, direction: EdgeDirection.outgoing);
        expect(outV1.map((e) => e.id), contains(edgeId));
        expect(outV1.single.to, v2);

        final inV2 =
            await edgeReader.edgesOf(v2, direction: EdgeDirection.incoming);
        expect(inV2.map((e) => e.id), contains(edgeId));

        // Live tip = node with no outgoing superseded_by.
        final outV2 =
            await edgeReader.edgesOf(v2, direction: EdgeDirection.outgoing);
        expect(outV2.where((e) => e.type == EdgeType.supersededBy), isEmpty,
            reason: 'v2 is the live tip — it supersedes nothing yet');
      }

      test('Procedure revision chain is writable and retains the original',
          () async {
        final v1 = await persistProcedure(
            'plan_v1', 'first draft', 'void main() {}', 'proc-v1');
        final v2 = await persistProcedure(
            'plan_v1', 'second draft', 'void main() { plan(); }', 'proc-v2',
            seed: 2);
        await assertRevisionChain(
            v1: v1, v2: v2, originalMarker: 'first draft', markerField: 'summary');
      });

      test('Plan revision chain is writable and retains the original',
          () async {
        final v1 = await persistPlan('goal', 'first plan', 'plan-v1');
        final v2 = await persistPlan('goal', 'revised plan', 'plan-v2', seed: 2);
        await assertRevisionChain(
            v1: v1, v2: v2, originalMarker: 'first plan', markerField: 'summary');
      });

      test('PlanStep revision chain is writable and retains the original',
          () async {
        final v1 = await persistPlanStep('old step', 0, 'pstep-v1');
        final v2 = await persistPlanStep('new step', 0, 'pstep-v2', seed: 2);
        await assertRevisionChain(
            v1: v1,
            v2: v2,
            originalMarker: 'old step',
            markerField: 'description');
      });

      test('a non-self-superseding type (Event) refuses superseded_by — '
          'the edge-direction grammar is still closed', () async {
        // Event carries neither outgoing nor incoming superseded_by; the
        // revision grammar must stay opt-in, not universal.
        final a = await persistEvent('evt-x');
        final b = await persistEvent('evt-y');
        Object? caught;
        try {
          await edgeWriter.edge(a, EdgeType.supersededBy, b, scope: _testScope);
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<EdgeNotPermitted>(),
            reason: 'Event is not a self-superseding type');
        expect((caught as EdgeNotPermitted).side, EdgeEndpointSide.from);
      });
    });
  });
}

Vec _v768(int seed) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

final class _NoopVectorApplier implements VectorApplier {
  @override
  void apply(PendingVectorWrite write) {}
}
