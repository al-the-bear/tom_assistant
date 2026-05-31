// A.70 — `AgentRegistration` + read/write scope enforcement across
// `persist`, `edge`, and stack `push`.
//
// Spec § 9.5: every cognitive-agent write carries an `agentName` on
// its `Scope`; the in-process `AgentRegistry` resolves the name to an
// `AgentRegistration` and rejects writes whose target resource is not
// covered by the registration's `writeScopes`.
//
// What this test exercises (one `test(...)` per row):
//
//   AgentRegistry primitives
//   ------------------------
//   * register / unregister / resolve / isRegistered / registeredAgents
//     round-trip cleanly; unknown agents resolve to null and
//     unregister of an unknown agent is a no-op.
//   * `register` with an already-known name *replaces* the prior
//     registration (file header: "honest reset").
//   * Pass-through: `guard*` with `agentName == null` is a no-op
//     regardless of registry state.
//   * Unregistered agent name throws
//     `AgentScopeViolation(agentNotRegistered)`.
//   * Denied node-scope / edge-scope / stack-scope throws
//     `AgentScopeViolation(writeScopeDenied)` with the requested
//     scope and the registration's `writeScopes` snapshot attached.
//   * `guardRead` mirrors the write side with `readScopeDenied`.
//   * Wildcards: `*` matches every scope; `node:*` / `edge:*` /
//     `stack:*` match every scope of that kind only — no kind bleed.
//
//   NodePersister × AgentRegistry
//   -----------------------------
//   * Allowed `node:<TypeName>` succeeds; rejected scope throws and
//     leaves no row + no `NodePersisted` event.
//   * Unregistered agent name throws `agentNotRegistered` with no
//     row and no event.
//   * Null `scope.agentName` is pass-through even when registry
//     populated and would otherwise deny.
//   * A persister constructed *without* a registry passes every
//     write through unchecked (opt-in contract).
//   * A denied write does NOT consume `WriteBudget.maxNodes` — the
//     scope guard sits before the budget charge.
//   * `node:*` and `*` wildcards both allow a Claim write.
//
//   EdgeWriter × AgentRegistry
//   --------------------------
//   * Allowed `edge:<wireName>` succeeds; rejected scope throws and
//     leaves no row + no `EdgeCreated` event.
//   * Unregistered agent name throws.
//   * Denied edge does NOT consume `WriteBudget.maxEdges`.
//
//   SqliteStackApi × AgentRegistry
//   ------------------------------
//   * Allowed `stack:<name>` succeeds; denied throws and leaves no
//     row + no `StackPushed` event.
//   * Denied push does NOT consume `WriteBudget.maxStackEntries`.

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
        StackEntryId,
        Vec,
        WriteBudget;

const _producer = 'extractor:dream_extract_v1:r_a70';
const _runId = 'r_a70';
const _agentName = 'extractor';
const _procedureId = 'dream_extract_v1';

void main() {
  group('A.70 AgentRegistry primitives', () {
    test('register / resolve / isRegistered / registeredAgents round-trip', () {
      final r = AgentRegistry();
      expect(r.isRegistered(_agentName), isFalse);
      expect(r.resolve(_agentName), isNull);
      expect(r.registeredAgents(), isEmpty);

      r.register(_reg(writeScopes: {'node:Claim'}));
      expect(r.isRegistered(_agentName), isTrue);
      expect(r.resolve(_agentName)!.agentName, equals(_agentName));
      expect(r.registeredAgents(), equals({_agentName}));
    });

    test('unregister removes; unregister of unknown is a no-op', () {
      final r = AgentRegistry();
      r.register(_reg(writeScopes: {'node:Claim'}));
      r.unregister(_agentName);
      expect(r.isRegistered(_agentName), isFalse);
      // No throw.
      r.unregister('never-existed');
    });

    test('register with same name replaces the prior registration', () {
      final r = AgentRegistry();
      r.register(_reg(writeScopes: {'node:Claim'}));
      // Prior is narrow — would deny node:Source.
      expect(
        () => r.guardNodeWrite(agentName: _agentName, typeName: 'Source'),
        throwsA(isA<AgentScopeViolation>().having(
            (e) => e.kind, 'kind', AgentScopeViolationKind.writeScopeDenied)),
      );
      // Replacement broadens.
      r.register(_reg(writeScopes: {'node:Claim', 'node:Source'}));
      // No throw — replaced, not merged or rejected.
      r.guardNodeWrite(agentName: _agentName, typeName: 'Source');
    });

    test('null agentName is pass-through for every guard helper', () {
      final r = AgentRegistry(); // empty
      r.guardNodeWrite(agentName: null, typeName: 'Claim');
      r.guardEdgeWrite(agentName: null, wireName: 'derived_from');
      r.guardStackPush(agentName: null, stackName: 'work');
      r.guardRead(agentName: null, scope: 'node:Claim');
    });

    test('unregistered agentName throws agentNotRegistered', () {
      final r = AgentRegistry();
      expect(
        () => r.guardNodeWrite(agentName: 'ghost', typeName: 'Claim'),
        throwsA(isA<AgentScopeViolation>()
            .having((e) => e.kind, 'kind',
                AgentScopeViolationKind.agentNotRegistered)
            .having((e) => e.agentName, 'agentName', 'ghost')),
      );
      expect(
        () => r.guardEdgeWrite(agentName: 'ghost', wireName: 'derived_from'),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.agentNotRegistered)),
      );
      expect(
        () => r.guardStackPush(agentName: 'ghost', stackName: 'work'),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.agentNotRegistered)),
      );
    });

    test('denied node-scope throws writeScopeDenied with full payload', () {
      final r = AgentRegistry();
      final granted = {'node:Claim'};
      r.register(_reg(writeScopes: granted));
      expect(
        () => r.guardNodeWrite(agentName: _agentName, typeName: 'Source'),
        throwsA(isA<AgentScopeViolation>()
            .having((e) => e.kind, 'kind',
                AgentScopeViolationKind.writeScopeDenied)
            .having((e) => e.agentName, 'agentName', _agentName)
            .having((e) => e.requestedScope, 'requestedScope', 'node:Source')
            .having((e) => e.grantedScopes, 'grantedScopes',
                equals(granted))),
      );
    });

    test('denied edge-scope and stack-scope name the right kind', () {
      final r = AgentRegistry();
      r.register(_reg(writeScopes: {'edge:derived_from', 'stack:work'}));
      expect(
        () =>
            r.guardEdgeWrite(agentName: _agentName, wireName: 'contradicts'),
        throwsA(isA<AgentScopeViolation>()
            .having((e) => e.kind, 'kind',
                AgentScopeViolationKind.writeScopeDenied)
            .having((e) => e.requestedScope, 'requestedScope',
                'edge:contradicts')),
      );
      expect(
        () => r.guardStackPush(agentName: _agentName, stackName: 'inflight'),
        throwsA(isA<AgentScopeViolation>()
            .having((e) => e.kind, 'kind',
                AgentScopeViolationKind.writeScopeDenied)
            .having((e) => e.requestedScope, 'requestedScope',
                'stack:inflight')),
      );
    });

    test('guardRead denies with readScopeDenied', () {
      final r = AgentRegistry();
      r.register(_reg(
        readScopes: {'node:Claim'},
        writeScopes: {'node:Claim'},
      ));
      // Allowed.
      r.guardRead(agentName: _agentName, scope: 'node:Claim');
      // Denied.
      expect(
        () => r.guardRead(agentName: _agentName, scope: 'node:Procedure'),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.readScopeDenied)),
      );
    });

    test('wildcard "*" matches every scope', () {
      final r = AgentRegistry();
      r.register(_reg(writeScopes: {'*'}));
      r.guardNodeWrite(agentName: _agentName, typeName: 'Claim');
      r.guardNodeWrite(agentName: _agentName, typeName: 'Procedure');
      r.guardEdgeWrite(agentName: _agentName, wireName: 'derived_from');
      r.guardStackPush(agentName: _agentName, stackName: 'anywhere');
    });

    test('kind wildcard "node:*" matches every node scope but not edge/stack',
        () {
      final r = AgentRegistry();
      r.register(_reg(writeScopes: {'node:*'}));
      // Every node typeName allowed.
      r.guardNodeWrite(agentName: _agentName, typeName: 'Claim');
      r.guardNodeWrite(agentName: _agentName, typeName: 'Source');
      // No kind bleed: edges and stacks still denied.
      expect(
        () =>
            r.guardEdgeWrite(agentName: _agentName, wireName: 'derived_from'),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.writeScopeDenied)),
      );
      expect(
        () => r.guardStackPush(agentName: _agentName, stackName: 'work'),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.writeScopeDenied)),
      );
    });
  });

  group('A.70 NodePersister × AgentRegistry', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late AgentRegistry agentRegistry;
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
      idCounter = 4000;

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintNodeId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validSource());

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
    });

    tearDown(() => db.dispose());

    Scope scopeWith({String? agentName = _agentName, String? runId = _runId}) =>
        Scope(producer: _producer, runId: runId, agentName: agentName);

    Future<NodeId> persistClaim(Scope scope, {String text = 'observation'}) =>
        persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: <String, Object?>{'text': text},
            embedding: _v768(seed: text.hashCode),
          ),
          scope: scope,
        );

    int claimCount() => db
        .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Claim'")
        .first['n'] as int;

    test('allowed scope persists; denied scope throws and leaves no row',
        () async {
      agentRegistry.register(_reg(writeScopes: {'node:Claim'}));
      // Allowed.
      await persistClaim(scopeWith());
      expect(claimCount(), equals(1));
      expect(events.whereType<NodePersisted>(), hasLength(1));

      // Denied: persister attempts Source but registration only
      // covers Claim.
      events.clear();
      final beforeRows = db
          .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Source'")
          .first['n'] as int;
      await expectLater(
        () => persister.persist(
          NodeDraft(
            typeName: 'Source',
            values: const <String, Object?>{'url': 'https://example.org/x'},
            embedding: _v768(seed: 99),
          ),
          scope: scopeWith(),
        ),
        throwsA(isA<AgentScopeViolation>().having(
            (e) => e.kind, 'kind', AgentScopeViolationKind.writeScopeDenied)),
      );
      final afterRows = db
          .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Source'")
          .first['n'] as int;
      expect(afterRows, equals(beforeRows),
          reason: 'denied scope must leave no row');
      expect(events.whereType<NodePersisted>(), isEmpty,
          reason: 'denied scope must not emit NodePersisted');
    });

    test('unregistered agentName throws agentNotRegistered', () async {
      // No registration for _agentName at all.
      await expectLater(
        () => persistClaim(scopeWith()),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.agentNotRegistered)),
      );
      expect(claimCount(), equals(0));
      expect(events.whereType<NodePersisted>(), isEmpty);
    });

    test('null scope.agentName is pass-through (no enforcement)', () async {
      // Registry has *no* matching scope, but agentName is null on
      // the scope — pass-through fires before any lookup.
      agentRegistry.register(_reg(writeScopes: const <String>{}));
      await persistClaim(scopeWith(agentName: null));
      expect(claimCount(), equals(1));
    });

    test('persister built without registry passes through unchecked',
        () async {
      // Construct a second persister without an agentRegistry.
      final unguarded = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      // No registration anywhere, but the persister has no registry
      // — pass-through.
      await unguarded.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'ungated'},
          embedding: _v768(seed: 7),
        ),
        scope: scopeWith(),
      );
      expect(claimCount(), equals(1));
    });

    test('denied write does not consume WriteBudget.maxNodes', () async {
      agentRegistry.register(_reg(writeScopes: {'node:Claim'}));
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 1, maxEdges: 0, maxStackEntries: 0),
      );
      // Denied scope on a different type — must NOT consume the unit.
      await expectLater(
        () => persister.persist(
          NodeDraft(
            typeName: 'Source',
            values: const <String, Object?>{'url': 'https://example.org/y'},
            embedding: _v768(seed: 11),
          ),
          scope: scopeWith(),
        ),
        throwsA(isA<AgentScopeViolation>()),
      );
      expect(tracker.remaining(_runId)!.maxNodes, equals(1),
          reason: 'scope-denied write must NOT consume budget');
      // Allowed write still has its unit.
      await persistClaim(scopeWith());
      expect(tracker.remaining(_runId)!.maxNodes, equals(0));
      expect(claimCount(), equals(1));
    });

    test('"node:*" wildcard allows every node type', () async {
      agentRegistry.register(_reg(writeScopes: {'node:*'}));
      await persistClaim(scopeWith(), text: 'wild-claim');
      await persister.persist(
        NodeDraft(
          typeName: 'Source',
          values: const <String, Object?>{'url': 'https://example.org/wild'},
          embedding: _v768(seed: 33),
        ),
        scope: scopeWith(),
      );
      expect(claimCount(), equals(1));
      final sourceCount = db
          .select("SELECT COUNT(*) AS n FROM nodes WHERE type_name = 'Source'")
          .first['n'] as int;
      expect(sourceCount, equals(1));
    });

    test('"*" wildcard allows every scope kind', () async {
      agentRegistry.register(_reg(writeScopes: {'*'}));
      await persistClaim(scopeWith(), text: 'star-claim');
      expect(claimCount(), equals(1));
    });
  });

  group('A.70 EdgeWriter × AgentRegistry', () {
    late Database db;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late AgentRegistry agentRegistry;
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
      idCounter = 5000;
      edgeIdCounter = 0;

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintNodeId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validSource());

      agentRegistry = AgentRegistry();
      tracker = WriteBudgetTracker();
      // Fixture-only persister — no registry/tracker so it does not
      // interact with the EdgeWriter we are exercising.
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
        agentRegistry: agentRegistry,
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

    Scope agentScope() => const Scope(
          producer: _producer,
          runId: _runId,
          agentName: _agentName,
        );

    test('allowed edge scope writes; denied throws and leaves no row',
        () async {
      agentRegistry.register(_reg(writeScopes: {'edge:derived_from'}));
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/a');

      events.clear();
      await writer.edge(claim, EdgeType.derivedFrom, src, scope: agentScope());
      expect(edgeCount(), equals(1));
      expect(events.whereType<EdgeCreated>(), hasLength(1));
    });

    test('denied edge throws writeScopeDenied; leaves no row + no event',
        () async {
      // Only allow derived_from; attempt evidence_for, which is
      // structurally valid as Source --evidence_for--> Claim
      // (Claim.allowedIncoming contains evidence_for, Source.allowed
      // Outgoing contains evidence_for). The scope guard must fire
      // *after* structural checks have passed, so the structural
      // validity of this edge is the whole point — without it we
      // would be testing structural rejection, not scope rejection.
      agentRegistry.register(_reg(writeScopes: {'edge:derived_from'}));
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/a');

      events.clear();
      final before = edgeCount();
      await expectLater(
        () =>
            writer.edge(src, EdgeType.evidenceFor, claim, scope: agentScope()),
        throwsA(isA<AgentScopeViolation>().having(
            (e) => e.kind, 'kind', AgentScopeViolationKind.writeScopeDenied)),
      );
      expect(edgeCount(), equals(before));
      expect(events.whereType<EdgeCreated>(), isEmpty);
    });

    test('unregistered agent name throws agentNotRegistered on edge',
        () async {
      // No registration at all.
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/a');
      events.clear();
      await expectLater(
        () =>
            writer.edge(claim, EdgeType.derivedFrom, src, scope: agentScope()),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.agentNotRegistered)),
      );
      expect(edgeCount(), equals(0));
      expect(events.whereType<EdgeCreated>(), isEmpty);
    });

    test('denied edge does not consume WriteBudget.maxEdges', () async {
      agentRegistry.register(_reg(writeScopes: {'edge:derived_from'}));
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/a');
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 1, maxStackEntries: 0),
      );
      // Structurally-valid but scope-denied edge: Source --evidence_for--> Claim.
      await expectLater(
        () =>
            writer.edge(src, EdgeType.evidenceFor, claim, scope: agentScope()),
        throwsA(isA<AgentScopeViolation>()),
      );
      expect(tracker.remaining(_runId)!.maxEdges, equals(1),
          reason: 'denied scope must NOT consume edge budget');
      // Allowed edge still has its unit.
      await writer.edge(claim, EdgeType.derivedFrom, src, scope: agentScope());
      expect(tracker.remaining(_runId)!.maxEdges, equals(0));
      expect(edgeCount(), equals(1));
    });

    test('null agentName on edge scope is pass-through', () async {
      agentRegistry.register(_reg(writeScopes: const <String>{}));
      final claim = await persistClaim('c');
      final src = await persistSource('https://example.org/np');
      await writer.edge(
        claim,
        EdgeType.derivedFrom,
        src,
        scope: const Scope(producer: _producer),
      );
      expect(edgeCount(), equals(1));
    });
  });

  group('A.70 SqliteStackApi × AgentRegistry', () {
    late Database db;
    late AgentRegistry agentRegistry;
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
          summary: 'a70 enforcement test',
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
      idCounter = 6000;
      entryCounter = 0;
      agentRegistry = AgentRegistry();
      tracker = WriteBudgetTracker();
      api = SqliteStackApi(
        memoryDb: db,
        entryIdMint: entryId,
        stackNodeIdMint: nodeId,
        now: () => fakeNow,
        eventSink: events.add,
        budgetTracker: tracker,
        agentRegistry: agentRegistry,
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

    Scope agentScope() => const Scope(
          producer: _producer,
          runId: _runId,
          agentName: _agentName,
        );

    test('allowed stack scope push succeeds; denied push throws and '
        'leaves no row + no event', () async {
      await createWorkStack();
      agentRegistry.register(_reg(writeScopes: {'stack:work'}));

      // Allowed.
      await api.push('work', nodeId(), scope: agentScope());
      expect(activeCount(), equals(1));
      expect(events.whereType<StackPushed>(), hasLength(1));

      // Register a stack we *do not* allow, then attempt to push there.
      await api.create(
        StackDecl(
          name: 'denied',
          summary: 'denied target',
          entryNodeType: 'Claim',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      events.clear();
      final beforeDenied = db
          .select("SELECT COUNT(*) AS n FROM stack_entries "
              "WHERE stack_name = 'denied' AND status = 'active'")
          .first['n'] as int;
      await expectLater(
        () => api.push('denied', nodeId(), scope: agentScope()),
        throwsA(isA<AgentScopeViolation>().having(
            (e) => e.kind, 'kind', AgentScopeViolationKind.writeScopeDenied)),
      );
      final afterDenied = db
          .select("SELECT COUNT(*) AS n FROM stack_entries "
              "WHERE stack_name = 'denied' AND status = 'active'")
          .first['n'] as int;
      expect(afterDenied, equals(beforeDenied));
      expect(events.whereType<StackPushed>(), isEmpty);
    });

    test('unregistered agent name on push throws agentNotRegistered',
        () async {
      await createWorkStack();
      await expectLater(
        () => api.push('work', nodeId(), scope: agentScope()),
        throwsA(isA<AgentScopeViolation>().having((e) => e.kind, 'kind',
            AgentScopeViolationKind.agentNotRegistered)),
      );
      expect(activeCount(), equals(0));
      expect(events.whereType<StackPushed>(), isEmpty);
    });

    test('denied push does not consume WriteBudget.maxStackEntries',
        () async {
      await createWorkStack();
      agentRegistry.register(_reg(writeScopes: {'stack:work'}));
      tracker.beginRun(
        runId: _runId,
        budget: WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 1),
      );
      // Create a second stack and attempt to push there — denied.
      await api.create(
        StackDecl(
          name: 'denied',
          summary: 'denied target',
          entryNodeType: 'Claim',
          policy: const StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        ),
      );
      await expectLater(
        () => api.push('denied', nodeId(), scope: agentScope()),
        throwsA(isA<AgentScopeViolation>()),
      );
      expect(tracker.remaining(_runId)!.maxStackEntries, equals(1),
          reason: 'denied push must NOT consume stack-entry budget');
      // Allowed push still has its unit.
      await api.push('work', nodeId(), scope: agentScope());
      expect(tracker.remaining(_runId)!.maxStackEntries, equals(0));
      expect(activeCount(), equals(1));
    });

    test('null agentName on push scope is pass-through', () async {
      await createWorkStack();
      // Register agent with nothing — but we pass agentName=null, so
      // enforcement is skipped.
      agentRegistry.register(_reg(writeScopes: const <String>{}));
      await api.push(
        'work',
        nodeId(),
        scope: const Scope(producer: _producer, runId: _runId),
      );
      expect(activeCount(), equals(1));
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

AgentRegistration _reg({
  Set<String> readScopes = const <String>{},
  Set<String> writeScopes = const <String>{},
}) =>
    AgentRegistration(
      agentName: _agentName,
      procedureId: _procedureId,
      defaultBudget:
          WriteBudget(maxNodes: 10, maxEdges: 10, maxStackEntries: 10),
      readScopes: readScopes,
      writeScopes: writeScopes,
    );

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
