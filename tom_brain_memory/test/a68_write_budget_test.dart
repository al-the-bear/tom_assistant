// A.68 — `WriteBudget` enforcement across `persist`, `edge`, and
// stack `push`.
//
// The agent registry (`memory_specification.md` § 9.5) attaches a
// per-agent `WriteBudget(maxNodes, maxEdges, maxStackEntries)` to
// each run. § 9.3 mandates that memory rejects writes past the
// budget with `BudgetExceeded` (the memory-internal exception is
// `WriteBudgetExceeded`; see file header for the naming rationale).
//
// What this test exercises (one `test(...)` per row):
//
//   Tracker primitives
//   ------------------
//   * `beginRun` registers a budget; `endRun` removes it; double
//     `beginRun` resets the remaining counters.
//   * `remaining` returns null for unregistered runs and the
//     decremented counters for registered ones.
//
//   Per-write enforcement — happy path
//   ----------------------------------
//   * `chargeNode` decrements `maxNodes` until zero; the Nth+1 call
//     throws with `dimension == maxNodes`.
//   * `chargeEdge` and `chargeStackEntry` mirror the same shape on
//     their respective dimensions, independently of one another.
//   * Pass-through: a charge for a null runId is a no-op; a charge
//     for an unregistered runId is also a no-op.
//
//   NodePersister integration
//   -------------------------
//   * Budget honoured: persists up to `maxNodes`; the Nth+1 throws
//     `WriteBudgetExceeded`; the rejected draft leaves no row and
//     emits no `NodePersisted`.
//   * Idempotent re-persist does NOT consume budget — a second
//     persist under the same key still works after the original
//     budget would otherwise have been exhausted.
//   * Validation failure does NOT consume budget — an
//     `InvalidNodeDraft` reject leaves the run's counters intact.
//
//   EdgeWriter integration
//   ----------------------
//   * Budget honoured: writes up to `maxEdges`; the Nth+1 throws
//     `WriteBudgetExceeded` and emits no `EdgeCreated`.
//   * Endpoint-missing / permission rejection does NOT consume
//     budget — the rejection path fires before the charge call.
//   * Idempotent re-edge does NOT consume budget.
//
//   StackApi integration
//   --------------------
//   * Push without a `Scope` is unmetered (pass-through, regardless
//     of tracker state) — bootstrap-style installs do not need a
//     registered run.
//   * Push with a `Scope` carrying an unregistered runId is also
//     pass-through (opt-in tracker contract).
//   * Push with a `Scope` whose runId IS registered consumes one
//     unit; the Nth+1 push throws and no row is inserted.
//   * Push on a missing stack does NOT consume budget — the
//     `StackNotFound` reject fires before the charge call.
//
//   Multi-run isolation
//   -------------------
//   * Two runs registered concurrently consume their own counters
//     independently; exhausting one does not affect the other.
//
//   `endRun`
//   --------
//   * After `endRun`, the run id passes through unchecked again —
//     subsequent writes do not throw.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainTime,
        BrainVersion,
        EdgeId,
        FixedClock,
        NodeId,
        StackEntryId,
        Vec,
        WriteBudget;

const _producer = 'extractor:dream_extract_v1:r_a68';
const _runId = 'r_a68';

void main() {
  group('A.68 WriteBudgetTracker primitives', () {
    test('unregistered run: remaining is null, charges are no-ops', () {
      final t = WriteBudgetTracker();
      expect(t.isRegistered('nope'), isFalse);
      expect(t.remaining('nope'), isNull);
      // No throws.
      t.chargeNode(runId: 'nope', producer: 'x');
      t.chargeEdge(runId: 'nope', producer: 'x');
      t.chargeStackEntry(runId: 'nope', producer: 'x');
      // Null runId is also a no-op even when the tracker is empty.
      t.chargeNode(runId: null, producer: 'x');
    });

    test('beginRun seeds counters; remaining mirrors decrement', () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 3, maxEdges: 2, maxStackEntries: 1),
      );
      expect(t.isRegistered('r1'), isTrue);
      expect(t.remaining('r1'), equals(WriteBudget(maxNodes: 3, maxEdges: 2, maxStackEntries: 1)));

      t.chargeNode(runId: 'r1', producer: _producer);
      expect(t.remaining('r1'),
          equals(WriteBudget(maxNodes: 2, maxEdges: 2, maxStackEntries: 1)));
      t.chargeEdge(runId: 'r1', producer: _producer);
      expect(t.remaining('r1'),
          equals(WriteBudget(maxNodes: 2, maxEdges: 1, maxStackEntries: 1)));
      t.chargeStackEntry(runId: 'r1', producer: _producer);
      expect(t.remaining('r1'),
          equals(WriteBudget(maxNodes: 2, maxEdges: 1, maxStackEntries: 0)));
    });

    test('chargeNode throws WriteBudgetExceeded on overflow; counter '
        'untouched and dimension correct', () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 1, maxEdges: 10, maxStackEntries: 10),
      );
      t.chargeNode(runId: 'r1', producer: _producer);
      expect(t.remaining('r1')!.maxNodes, equals(0));
      try {
        t.chargeNode(runId: 'r1', producer: _producer);
        fail('expected WriteBudgetExceeded');
      } on WriteBudgetExceeded catch (e) {
        expect(e.dimension, equals(WriteBudgetDimension.maxNodes));
        expect(e.runId, equals('r1'));
        expect(e.producer, equals(_producer));
        expect(e.budget.maxNodes, equals(1),
            reason: 'exception carries the ORIGINAL cap, not remaining');
      }
      // Counter not decremented past zero on a rejected charge.
      expect(t.remaining('r1')!.maxNodes, equals(0));
    });

    test('chargeEdge and chargeStackEntry name the right dimension on '
        'overflow', () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 10, maxEdges: 0, maxStackEntries: 0),
      );
      expect(
        () => t.chargeEdge(runId: 'r1', producer: _producer),
        throwsA(isA<WriteBudgetExceeded>().having(
            (e) => e.dimension, 'dimension', WriteBudgetDimension.maxEdges)),
      );
      expect(
        () => t.chargeStackEntry(runId: 'r1', producer: _producer),
        throwsA(isA<WriteBudgetExceeded>().having((e) => e.dimension,
            'dimension', WriteBudgetDimension.maxStackEntries)),
      );
    });

    test('beginRun twice for same run id resets remaining to new budget',
        () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 1, maxEdges: 1, maxStackEntries: 1),
      );
      t.chargeNode(runId: 'r1', producer: _producer);
      expect(t.remaining('r1')!.maxNodes, equals(0));
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 5, maxEdges: 5, maxStackEntries: 5),
      );
      expect(t.remaining('r1')!.maxNodes, equals(5),
          reason: 'second beginRun replaces, not adds');
    });

    test('endRun removes registration; subsequent charges pass through',
        () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0),
      );
      // Pre-endRun: any charge throws.
      expect(
        () => t.chargeNode(runId: 'r1', producer: _producer),
        throwsA(isA<WriteBudgetExceeded>()),
      );
      t.endRun('r1');
      expect(t.isRegistered('r1'), isFalse);
      // Post-endRun: no throw — unregistered runs pass through.
      t.chargeNode(runId: 'r1', producer: _producer);
    });

    test('endRun on unregistered runId is a no-op', () {
      final t = WriteBudgetTracker();
      t.endRun('never-existed'); // does not throw
    });

    test('two concurrent runs consume independent counters', () {
      final t = WriteBudgetTracker();
      t.beginRun(
        runId: 'r1',
        budget: WriteBudget(maxNodes: 1, maxEdges: 1, maxStackEntries: 1),
      );
      t.beginRun(
        runId: 'r2',
        budget: WriteBudget(maxNodes: 5, maxEdges: 5, maxStackEntries: 5),
      );
      t.chargeNode(runId: 'r1', producer: _producer);
      expect(t.remaining('r1')!.maxNodes, equals(0));
      expect(t.remaining('r2')!.maxNodes, equals(5),
          reason: 'exhausting r1 does not affect r2');

      // r1 is exhausted on nodes; r2 still has room.
      expect(
        () => t.chargeNode(runId: 'r1', producer: _producer),
        throwsA(isA<WriteBudgetExceeded>()),
      );
      t.chargeNode(runId: 'r2', producer: _producer); // ok
    });
  });

  group('A.68 NodePersister × WriteBudget', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late WriteBudgetTracker tracker;
    late NodePersister persister;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int idCounter;

    NodeId mintNodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
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
      idCounter = 1000;

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintNodeId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());

      tracker = WriteBudgetTracker();
      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
      );
    });

    tearDown(() => db.dispose());

    Future<NodeId> persistClaim({String? idemKey, String text = 'observation'}) {
      final scope = Scope(
        producer: _producer,
        idempotencyKey: idemKey,
        runId: _runId,
      );
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: text.hashCode + (idemKey?.hashCode ?? 0)),
        ),
        scope: scope,
      );
    }

    int claimCount() => db
        .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Claim'")
        .first['n'] as int;

    test('budget honoured: persists up to maxNodes, then throws on N+1',
        () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 2, maxEdges: 0, maxStackEntries: 0),
      );
      await persistClaim(text: 'one');
      await persistClaim(text: 'two');
      expect(claimCount(), equals(2));

      events.clear();
      await expectLater(
        () => persistClaim(text: 'three'),
        throwsA(isA<WriteBudgetExceeded>().having(
            (e) => e.dimension, 'dimension', WriteBudgetDimension.maxNodes)),
      );
      expect(claimCount(), equals(2),
          reason: 'rejected persist must not leave a row behind');
      expect(events.whereType<NodePersisted>(), isEmpty,
          reason: 'rejected persist must not emit NodePersisted');
    });

    test('idempotent re-persist does not consume budget', () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 1, maxEdges: 0, maxStackEntries: 0),
      );
      final first = await persistClaim(idemKey: 'k1', text: 'unique');
      expect(tracker.remaining(_runId)!.maxNodes, equals(0));
      // Replay under same key — must succeed (no charge fired).
      final second = await persistClaim(idemKey: 'k1', text: 'unique');
      expect(second, equals(first));
      expect(claimCount(), equals(1));
      expect(tracker.remaining(_runId)!.maxNodes, equals(0),
          reason: 'idempotent replay does not double-charge');
    });

    test('validation failure does not consume budget', () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 1, maxEdges: 0, maxStackEntries: 0),
      );
      // Bogus draft: unknown field on Claim.
      final scope = const Scope(
        producer: _producer,
        runId: _runId,
      );
      await expectLater(
        () => persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{'nonsense': 42},
            embedding: _v768(seed: 99),
          ),
          scope: scope,
        ),
        throwsA(isA<InvalidNodeDraft>()),
      );
      // Budget remains full — a subsequent valid persist must succeed.
      expect(tracker.remaining(_runId)!.maxNodes, equals(1));
      await persistClaim(text: 'after-reject');
      expect(claimCount(), equals(1));
    });

    test('persist with null runId passes through unchecked', () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0),
      );
      // Different scope: no runId.
      final scope = const Scope(producer: _producer);
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'no run id'},
          embedding: _v768(seed: 42),
        ),
        scope: scope,
      );
      expect(claimCount(), equals(1),
          reason: 'null runId never charges, even when other runs exhausted');
    });

    test('persist for unregistered runId passes through', () async {
      // tracker is empty — no beginRun called for _runId.
      await persistClaim(text: 'unregistered-run');
      expect(claimCount(), equals(1));
    });
  });

  group('A.68 EdgeWriter × WriteBudget', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late WriteBudgetTracker tracker;
    late NodePersister persister;
    late EdgeWriter writer;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int idCounter;
    late int edgeIdCounter;

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
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: _NoopVectorApplier(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      events = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 2000;
      edgeIdCounter = 0;

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintNodeId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validSource());

      tracker = WriteBudgetTracker();
      // Persister has no budget tracker — we only test EdgeWriter's
      // enforcement in this group. Persisting fixture nodes must not
      // affect the edge-only budget.
      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      writer = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
      );
    });

    tearDown(() => db.dispose());

    Future<NodeId> persistClaim(String text) => persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: <String, Object?>{'text': text},
            embedding: _v768(seed: text.hashCode),
          ),
          scope: const Scope(producer: 'fixture'),
        );

    Future<NodeId> persistSource(String url) => persister.persist(
          NodeDraft(
            typeName: 'Source',
            values: <String, Object?>{'url': url},
            embedding: _v768(seed: url.hashCode + 7),
          ),
          scope: const Scope(producer: 'fixture'),
        );

    int edgeCount() =>
        db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;

    test('budget honoured: writes up to maxEdges, then throws on N+1',
        () async {
      final claim = await persistClaim('c');
      final src1 = await persistSource('https://example.org/1');
      final src2 = await persistSource('https://example.org/2');
      final src3 = await persistSource('https://example.org/3');

      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 2, maxStackEntries: 0),
      );
      final scope = const Scope(producer: _producer, runId: _runId);
      await writer.edge(claim, EdgeType.derivedFrom, src1, scope: scope);
      await writer.edge(claim, EdgeType.derivedFrom, src2, scope: scope);
      expect(edgeCount(), equals(2));

      events.clear();
      await expectLater(
        () => writer.edge(claim, EdgeType.derivedFrom, src3, scope: scope),
        throwsA(isA<WriteBudgetExceeded>().having(
            (e) => e.dimension, 'dimension', WriteBudgetDimension.maxEdges)),
      );
      expect(edgeCount(), equals(2),
          reason: 'rejected edge must not leave a row');
      expect(events.whereType<EdgeCreated>(), isEmpty);
    });

    test('endpoint-missing rejection does not consume budget', () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 1, maxStackEntries: 0),
      );
      final scope = const Scope(producer: _producer, runId: _runId);
      final ghost = mintNodeId(); // never persisted
      final claim = await persistClaim('only-real');

      await expectLater(
        () => writer.edge(ghost, EdgeType.derivedFrom, claim, scope: scope),
        throwsA(isA<EdgeEndpointMissing>()),
      );
      // Budget intact — a subsequent valid edge must still succeed.
      expect(tracker.remaining(_runId)!.maxEdges, equals(1));
    });

    test('idempotent re-edge does not consume budget', () async {
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/idem');
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 1, maxStackEntries: 0),
      );
      final scope = const Scope(
        producer: _producer,
        idempotencyKey: 'edge-k1',
        runId: _runId,
      );
      final first =
          await writer.edge(claim, EdgeType.derivedFrom, src, scope: scope);
      expect(tracker.remaining(_runId)!.maxEdges, equals(0));
      // Replay — must succeed even though budget is exhausted.
      final second =
          await writer.edge(claim, EdgeType.derivedFrom, src, scope: scope);
      expect(second, equals(first));
      expect(edgeCount(), equals(1));
      expect(tracker.remaining(_runId)!.maxEdges, equals(0));
    });
  });

  group('A.68 SqliteStackApi × WriteBudget', () {
    late Database db;
    late WriteBudgetTracker tracker;
    late SqliteStackApi api;
    late List<MemoryEvent> events;
    late DateTime fakeNow;
    late int idCounter;
    late int entryCounter;

    NodeId nodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
      );
    }

    StackEntryId entryId() {
      entryCounter += 1;
      return StackEntryId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (entryCounter * 11 + i) & 31),
      );
    }

    Future<void> createWorkStack() async {
      await api.create(
        StackDecl(
          name: 'work',
          summary: 'budget test',
          entryNodeType: 'Claim',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 3000;
      entryCounter = 0;
      tracker = WriteBudgetTracker();
      api = SqliteStackApi(
        memoryDb: db,
        entryIdMint: entryId,
        stackNodeIdMint: nodeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
      );
    });

    tearDown(() async {
      await api.close();
      db.dispose();
    });

    int activeCount() => db
        .select("SELECT COUNT(*) AS n FROM stack_entries "
            "WHERE stack_name = 'work' AND status = 'active'")
        .first['n'] as int;

    test('push without scope is unmetered regardless of tracker state',
        () async {
      await createWorkStack();
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0),
      );
      // Scope omitted → pass-through.
      await api.push('work', nodeId());
      await api.push('work', nodeId());
      expect(activeCount(), equals(2));
    });

    test('push with scope but unregistered runId passes through', () async {
      await createWorkStack();
      // No beginRun for _runId.
      await api.push(
        'work',
        nodeId(),
        scope: const Scope(producer: _producer, runId: _runId),
      );
      expect(activeCount(), equals(1));
    });

    test('push with registered run honours maxStackEntries and rejects N+1',
        () async {
      await createWorkStack();
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 2),
      );
      final scope = const Scope(producer: _producer, runId: _runId);
      await api.push('work', nodeId(), scope: scope);
      await api.push('work', nodeId(), scope: scope);
      expect(activeCount(), equals(2));

      events.clear();
      await expectLater(
        () => api.push('work', nodeId(), scope: scope),
        throwsA(isA<WriteBudgetExceeded>().having((e) => e.dimension,
            'dimension', WriteBudgetDimension.maxStackEntries)),
      );
      expect(activeCount(), equals(2),
          reason: 'rejected push must not leave a row behind');
      expect(events.whereType<StackPushed>(), isEmpty);
    });

    test('push on missing stack does not consume budget', () async {
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 1),
      );
      await expectLater(
        () => api.push(
          'never-created',
          nodeId(),
          scope: const Scope(producer: _producer, runId: _runId),
        ),
        throwsA(isA<StackNotFound>()),
      );
      // Budget intact.
      expect(tracker.remaining(_runId)!.maxStackEntries, equals(1));
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
      allowedOutgoing: const <EdgeType>{
        EdgeType.derivedFrom,
        EdgeType.evidenceFor,
      },
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
      allowedIncoming: const <EdgeType>{EdgeType.derivedFrom},
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
