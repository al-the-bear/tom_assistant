// A.71 — Cognitive-agent infrastructure cross-cut integration test.
//
// Plan step A.71 (closing test step of section A.12 — cognitive-agent
// infrastructure):
//
//   "Tests: idempotent re-persist returns stable `NodeId`; budget
//    exceeded errors with `BudgetExceeded`; shaking events flow
//    end-to-end."
//
// The preceding steps each have their own focused per-feature test
// file:
//
//   - A.67 — `Scope.idempotencyKey` enforcement
//            (`a67_idempotency_cross_cut_test.dart`)
//   - A.68 — `WriteBudget` enforcement
//            (`a68_write_budget_test.dart`)
//   - A.69 — `ShakingEvent` emission
//            (`a69_shaking_events_test.dart`)
//   - A.70 — `AgentRegistration` + scope enforcement
//            (`a70_agent_scope_enforcement_test.dart`)
//
// What A.71 adds — and the reason it is a separate file — is the
// *cross-cut* assertion that all four mechanisms remain composable
// in a single realistic agent-run scenario:
//
//   1. The same `Scope` carrying `agentName`, `runId`, and
//      `idempotencyKey` flows through `NodePersister.persist` and
//      `EdgeWriter.edge` in one go, and every one of the four
//      guards (idempotency dedup, write-budget charge, agent-scope
//      guard, shaking-event emission) fires in the right order and
//      without interfering with the others.
//
//   2. An interrupted agent run that retries from the top under the
//      *same* idempotency keys converges back to exactly the same
//      `NodeId` / `EdgeId` pair, with no second event, no second row,
//      and — crucially — without re-consuming `WriteBudget`. The
//      "replay does not double-charge budget" invariant is what
//      makes interrupted-and-retried dreaming agents safe.
//
//   3. A `contradicts` edge written under the cross-cut scope
//      surfaces a `ContradictionDetected` shaking event on the same
//      event sink that carries `NodePersisted` / `EdgeCreated`. The
//      shaking event is observable both by its concrete type and by
//      the `ShakingEvent.kindPrefix` discriminator that downstream
//      `dream_reconsolidate_v1` subscribes to.
//
//   4. Once the budget is exhausted, the *next* write — regardless
//      of whether it is otherwise valid (scope allowed, idempotency
//      key fresh, structural validation passes) — fails with
//      `WriteBudgetExceeded` carrying the right dimension and the
//      original cap (not the remaining counter).
//
// The fixtures deliberately mirror those used by the per-feature
// test files so the integration scenario can be diff-compared
// against the focused tests; only the *combination* is new.
//
// One `test(...)` per row:
//
//   * `simulated extractor run is idempotent, budget-aware, and
//     emits the contradiction shaking event end-to-end` — the full
//     happy-path scenario.
//
//   * `budget exhaustion across persist and edge under the same run
//     throws WriteBudgetExceeded on the next write` — the budget
//     guardrail at the cross-cut boundary.
//
//   * `replayed agent run does not re-emit shaking events` — the
//     replay-idempotency invariant for shaking events specifically
//     (a `ContradictionDetected` is not a re-signal, it is a
//     one-time-per-edge cognitive marker).

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        AgentRegistration,
        BrainTime,
        BrainVersion,
        EdgeId,
        FixedClock,
        NodeId,
        Vec,
        WriteBudget;

// ─── Run / agent constants (shared across the file) ──────────────────

const _agentName = 'extractor';
const _procedureId = 'dream_extract_v1';
const _producer = 'extractor:dream_extract_v1:r_a71';
const _runId = 'r_a71';

void main() {
  group('A.71 cognitive-agent infrastructure cross-cut', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late AgentRegistry agentRegistry;
    late WriteBudgetTracker tracker;
    late NodePersister persister;
    late EdgeWriter writer;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int nodeIdCounter;
    late int edgeIdCounter;

    NodeId mintNodeId() {
      nodeIdCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (nodeIdCounter + i) & 31),
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
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: _NoopVectorApplier(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      events = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      nodeIdCounter = 0;
      edgeIdCounter = 0;

      // Separate counter for the NodeType registry — its `idMint`
      // would collide with the application-side counter otherwise.
      var regIdCounter = 5000;
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
      // Claim allows contradicts both ways — the only NodeType the
      // extractor run touches in this scenario.
      await registry.registerNodeType(_claimContradicts());

      // Wire the four cognitive-agent infrastructure pieces (A.67
      // idempotency lives inside the persister/writer; A.68
      // tracker; A.69 emission happens inside the writer + on the
      // shared event sink; A.70 agent registry). Persister and
      // writer share the same event sink so the test sees a single
      // ordered stream.
      agentRegistry = AgentRegistry();
      tracker = WriteBudgetTracker();
      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
        agentRegistry: agentRegistry,
      );
      writer = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
        agentRegistry: agentRegistry,
      );
    });

    tearDown(() => db.dispose());

    // Helper: build a Scope carrying the full cross-cut bundle —
    // producer, run id, agent name, and a per-write idempotency key.
    Scope crossCutScope(String idemKey) => Scope(
          producer: _producer,
          runId: _runId,
          agentName: _agentName,
          idempotencyKey: idemKey,
        );

    Future<NodeId> persistClaim(String text, {required String idemKey}) =>
        persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: <String, Object?>{'text': text},
            embedding: _v768(seed: idemKey.hashCode),
          ),
          scope: crossCutScope(idemKey),
        );

    Future<EdgeId> contradicts(
      NodeId from,
      NodeId to, {
      required String idemKey,
    }) =>
        writer.edge(
          from,
          EdgeType.contradicts,
          to,
          scope: crossCutScope(idemKey),
        );

    int claimCount() => db
        .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Claim'")
        .first['n'] as int;

    int edgeCount() =>
        db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;

    test('simulated extractor run is idempotent, budget-aware, and emits '
        'the contradiction shaking event end-to-end', () async {
      // Register the agent with a tight budget — enough room for the
      // happy-path run but no slack to hide a double-charge.
      agentRegistry.register(_extractorRegistration(
        writeScopes: const {
          'node:Claim',
          'edge:contradicts',
        },
      ));
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 2, maxEdges: 1, maxStackEntries: 0),
      );

      // ─── First run ──────────────────────────────────────────────
      final claimA1 = await persistClaim('the sky is blue', idemKey: 'k-A');
      final claimB1 = await persistClaim('the sky is green', idemKey: 'k-B');
      final edgeAB1 = await contradicts(claimA1, claimB1, idemKey: 'k-AB');

      // State after first run: 2 nodes, 1 edge, budget fully spent.
      expect(claimCount(), equals(2));
      expect(edgeCount(), equals(1));
      expect(tracker.remaining(_runId),
          equals(WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0)));

      // Event stream after first run: two NodePersisted, one
      // EdgeCreated, one ContradictionDetected — in that order. The
      // ContradictionDetected immediately follows its EdgeCreated.
      expect(events.whereType<NodePersisted>(), hasLength(2));
      expect(events.whereType<EdgeCreated>(), hasLength(1));
      final contradictions = events.whereType<ContradictionDetected>().toList();
      expect(contradictions, hasLength(1));

      final contradiction = contradictions.single;
      // The shaking event carries the cross-cut Scope context: same
      // runId and edge endpoints as the EdgeCreated that preceded it.
      expect(contradiction.edgeId, equals(edgeAB1));
      expect(contradiction.from, equals(claimA1));
      expect(contradiction.to, equals(claimB1));
      expect(contradiction.fromTypeName, equals('Claim'));
      expect(contradiction.toTypeName, equals('Claim'));
      expect(contradiction.runId, equals(_runId));
      // Discriminator surface — subscribers identify shaking events
      // by prefix; the leaf kind is the kebab-cased class name.
      expect(contradiction.kind,
          equals('memory.shaking.contradiction-detected'));
      expect(contradiction.kind, startsWith(ShakingEvent.kindPrefix));

      // EdgeCreated must land before ContradictionDetected — the
      // "structural fact first, cognitive signal second" pairing
      // documented in `edge_writer.dart` / `shaking_events.dart`.
      final edgeIdx =
          events.indexWhere((e) => e is EdgeCreated && e.edgeId == edgeAB1);
      final contraIdx = events.indexOf(contradiction);
      expect(edgeIdx, greaterThanOrEqualTo(0));
      expect(contraIdx, greaterThan(edgeIdx));

      // ─── Replay (interrupted-and-retried) ───────────────────────
      // The agent crashes mid-run and the dispatcher re-issues every
      // write under the same idempotency keys. The cross-cut
      // guarantee: same IDs returned, no extra rows, no extra
      // events, and — the part this file owns — no second
      // WriteBudget charge.
      final eventsBeforeReplay = events.length;
      final claimA2 = await persistClaim('the sky is blue', idemKey: 'k-A');
      final claimB2 = await persistClaim('the sky is green', idemKey: 'k-B');
      final edgeAB2 = await contradicts(claimA2, claimB2, idemKey: 'k-AB');

      expect(claimA2, equals(claimA1),
          reason: 'idempotency key returns the same NodeId');
      expect(claimB2, equals(claimB1),
          reason: 'idempotency key returns the same NodeId');
      expect(edgeAB2, equals(edgeAB1),
          reason: 'idempotency key returns the same EdgeId');

      expect(claimCount(), equals(2));
      expect(edgeCount(), equals(1));

      // Event stream must be unchanged — a replay is a silent no-op,
      // not a re-signal.
      expect(events.length, equals(eventsBeforeReplay),
          reason: 'replay must not emit duplicate events of any kind');

      // Budget remains at zero — replay does not double-charge. The
      // critical invariant that lets an interrupted agent run safely
      // resume mid-flight under a budget that was sized for one
      // successful pass.
      expect(tracker.remaining(_runId),
          equals(WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0)),
          reason: 'idempotent replay must not consume budget');
    });

    test('budget exhaustion across persist and edge under the same run '
        'throws WriteBudgetExceeded on the next write', () async {
      agentRegistry.register(_extractorRegistration(
        writeScopes: const {
          'node:Claim',
          'edge:contradicts',
        },
      ));
      // Headroom for exactly one node and one edge — the next of
      // each kind must throw.
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 1, maxEdges: 1, maxStackEntries: 0),
      );

      final claimA = await persistClaim('only-claim', idemKey: 'k-only');
      // Persist within the same run under a *fresh* idempotency key
      // — must throw `WriteBudgetExceeded` on maxNodes because the
      // node budget is now exhausted.
      events.clear();
      final claimsBefore = claimCount();
      await expectLater(
        () => persistClaim('over-budget', idemKey: 'k-over'),
        throwsA(isA<WriteBudgetExceeded>()
            .having((e) => e.dimension, 'dimension',
                WriteBudgetDimension.maxNodes)
            .having((e) => e.runId, 'runId', _runId)
            .having((e) => e.producer, 'producer', _producer)
            .having((e) => e.budget.maxNodes, 'budget.maxNodes', 1)),
      );
      expect(claimCount(), equals(claimsBefore),
          reason: 'rejected persist must not leave a row');
      expect(events.whereType<NodePersisted>(), isEmpty,
          reason: 'rejected persist must not emit NodePersisted');

      // We still have one edge of headroom. We need a second target
      // node to write an edge to. Persist it under a *null* runId so
      // it bypasses the tracker — the test scenario is "the test
      // harness seeds a second node outside the agent run".
      // (Bootstrap-style writes — see Scope.runId doc — pass through
      // the tracker.)
      final claimB = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'fixture-claim-B'},
          embedding: _v768(seed: 999),
        ),
        scope: const Scope(producer: 'fixture'),
      );

      // First edge under the run succeeds — consumes the last unit.
      final edge1 = await contradicts(claimA, claimB, idemKey: 'k-edge-1');
      expect(edgeCount(), equals(1));
      expect(edge1, isNotNull);

      // Second edge: budget exhausted on maxEdges. Must throw, must
      // not leave a row, must not emit EdgeCreated or
      // ContradictionDetected.
      events.clear();
      final edgesBefore = edgeCount();
      await expectLater(
        () => contradicts(claimB, claimA, idemKey: 'k-edge-2'),
        throwsA(isA<WriteBudgetExceeded>()
            .having((e) => e.dimension, 'dimension',
                WriteBudgetDimension.maxEdges)
            .having((e) => e.budget.maxEdges, 'budget.maxEdges', 1)),
      );
      expect(edgeCount(), equals(edgesBefore),
          reason: 'rejected edge must not leave a row');
      expect(events.whereType<EdgeCreated>(), isEmpty);
      expect(events.whereType<ContradictionDetected>(), isEmpty,
          reason: 'budget-rejected edge must not emit the shaking event');
    });

    test('replayed agent run does not re-emit shaking events', () async {
      // Focused regression: a `ContradictionDetected` is a one-time
      // cognitive marker for an edge, not a re-signal. The replay
      // path must suppress it just like it suppresses EdgeCreated.
      agentRegistry.register(_extractorRegistration(
        writeScopes: const {
          'node:Claim',
          'edge:contradicts',
        },
      ));
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 4, maxEdges: 4, maxStackEntries: 0),
      );

      final a = await persistClaim('a', idemKey: 'k-a');
      final b = await persistClaim('b', idemKey: 'k-b');
      await contradicts(a, b, idemKey: 'k-ab');

      expect(events.whereType<ContradictionDetected>(), hasLength(1));

      // Replay every write three times — under the same keys each
      // time, exactly the same EdgeId / NodeIds come back, and the
      // ContradictionDetected count stays at one.
      for (var i = 0; i < 3; i++) {
        await persistClaim('a', idemKey: 'k-a');
        await persistClaim('b', idemKey: 'k-b');
        await contradicts(a, b, idemKey: 'k-ab');
      }

      expect(events.whereType<ContradictionDetected>(), hasLength(1),
          reason: 'replay must not re-emit a one-time cognitive marker');
      expect(events.whereType<NodePersisted>(), hasLength(2));
      expect(events.whereType<EdgeCreated>(), hasLength(1));

      // And the run's budget is still healthy — replays did not
      // double-charge any dimension.
      expect(tracker.remaining(_runId)!.maxNodes, equals(2));
      expect(tracker.remaining(_runId)!.maxEdges, equals(3));
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

AgentRegistration _extractorRegistration({
  Set<String> readScopes = const <String>{'*'},
  required Set<String> writeScopes,
}) =>
    AgentRegistration(
      agentName: _agentName,
      procedureId: _procedureId,
      // The defaultBudget on the registration is the *suggested*
      // per-run budget. The tracker uses an explicit `beginRun`
      // budget in this test so we can assert the concrete remaining
      // values; the registration's defaultBudget is intentionally
      // generous to avoid any cross-cut interaction.
      defaultBudget:
          WriteBudget(maxNodes: 100, maxEdges: 100, maxStackEntries: 100),
      readScopes: readScopes,
      writeScopes: writeScopes,
    );

NodeTypeDecl _claimContradicts() => NodeTypeDecl(
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
      allowedOutgoing: const <EdgeType>{
        EdgeType.contradicts,
        EdgeType.derivedFrom,
      },
      allowedIncoming: const <EdgeType>{
        EdgeType.contradicts,
        EdgeType.derivedFrom,
      },
    );

Vec _v768({required int seed}) {
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
