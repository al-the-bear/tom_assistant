// A.33 — NodeTypeRegistry contract test.
//
// Covers `NodeTypeRegistry.registerNodeType` + the validation matrix
// + the critique-hook seam. The test exercises the real SQLite engine
// (in-memory `:memory:`) so the SQL path is real, not mocked.
//
// Coverage map (one `test(...)` per row):
//
//   Success paths
//   -------------
//   * Fresh type with full embedding policy commits, mints decl-node id,
//     warms cache, emits NodeTypeRegistered.
//   * Type with EmbeddingPolicy.none commits.
//   * Successor (supersedes set, version bumped) replaces live tip.
//   * listAll returns insertion order.
//   * A second registry over the same DB warms its cache from the row.
//   * The critique hook is handed a snapshot of existing types.
//
//   Failure — InvalidNodeTypeDecl
//   -----------------------------
//   * Empty typeName.
//   * Non-PascalCase typeName.
//   * version < 1.
//   * Empty schema.
//   * FieldSpec.name mismatched with map key.
//   * Empty validatorScriptId.
//   * embeddingPolicy.modelIdentity empty (not-none policy).
//   * embeddingPolicy.dimensions ≤ 0.
//   * embeddingPolicy.sourceFields empty.
//   * embeddingPolicy.sourceFields names missing field.
//   * embeddingPolicy.sourceFields names non-string field.
//   * indexPolicy.ftsFields names missing field.
//   * indexPolicy.ftsFields names non-eligible field.
//   * indexPolicy.vectorFields names missing field.
//   * indexPolicy.vectorFields names non-vec field.
//   * indexPolicy.vectorFields names non-eligible vec field.
//
//   Failure — cross-type
//   --------------------
//   * NodeTypeAlreadyExists when supersedes is null and name collides.
//   * NodeTypeNotFound when supersedes set but type absent.
//   * NodeTypeNotFound when supersedes references stale decl-node id.
//   * NodeTypeVersionNotMonotonic when supersedes set but version not >.
//
//   Failure — critique
//   ------------------
//   * NodeTypeRejected when hook returns CritiqueRejected (reason +
//     conflictingTypeNames preserved).
//   * NodeTypeRejected when hook crashes (crash message preserved).
//
//   Side-effect invariants
//   ----------------------
//   * On rejection (any path), no row written, no cache update,
//     no event emitted.
//
// Tests do NOT assert on the JSON shape of the cache row — that is
// considered an internal serialisation choice and is covered by the
// cache-warm round-trip test (a second registry reading the row back
// reconstructs an equal `NodeTypeDecl`).

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, NodeId, Vec;

void main() {
  group('A.33 NodeTypeRegistry.registerNodeType', () {
    late Database db;
    late List<MemoryEvent> events;
    late int idCounter;
    late DateTime fakeNow;

    NodeId mintId() {
      // Deterministic decl-node id stream — uses the NodeId.generate
      // randomness override to produce stable ULIDs without leaking
      // implementation details into the test.
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    NodeTypeRegistry buildRegistry({
      CritiqueHook? hook,
      bool noEventSink = false,
    }) {
      return NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: hook ?? _approveAll(),
        idMint: mintId,
        now: () => fakeNow,
        eventSink: noEventSink ? null : events.add,
      );
    }

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      idCounter = 0;
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
    });

    tearDown(() {
      db.dispose();
    });

    // ──────────────────────────────────────────────────────────────
    // Success paths
    // ──────────────────────────────────────────────────────────────

    test('commits a fresh type, mints decl-node id, emits event', () async {
      final registry = buildRegistry();
      final decl = _validClaim();

      final id = await registry.registerNodeType(decl);

      expect(id.toString(), startsWith('n_'));
      expect(registry.get('Claim'), same(decl));
      expect(registry.declNodeIdOf('Claim'), equals(id));

      // DB side: one row, with the same decl-node id.
      final rows = db.select('SELECT * FROM node_types');
      expect(rows, hasLength(1));
      expect(rows.first['type_name'], equals('Claim'));
      expect(rows.first['decl_node_id'], equals(id.toString()));
      expect(rows.first['version'], equals(1));
      expect(rows.first['supersedes'], isNull);

      // Event side: exactly one NodeTypeRegistered.
      expect(events, hasLength(1));
      final ev = events.single as NodeTypeRegistered;
      expect(ev.typeName, equals('Claim'));
      expect(ev.declNodeId, equals(id));
      expect(ev.version, equals(1));
      expect(ev.supersedes, isNull);
      expect(ev.critiqueNote, isNull);
      expect(ev.occurredAt, equals(fakeNow));
      expect(ev.kind, equals('memory.node-type-registered'));
    });

    test('commits a type with EmbeddingPolicy.none', () async {
      final registry = buildRegistry();
      final decl = _validTombstone();

      final id = await registry.registerNodeType(decl);

      expect(registry.get('Tombstone'), same(decl));
      expect(registry.declNodeIdOf('Tombstone'), equals(id));
      expect(events, hasLength(1));
    });

    test('successor replaces the live tip', () async {
      final registry = buildRegistry();
      final v1 = _validClaim();
      final firstId = await registry.registerNodeType(v1);

      final v2 = NodeTypeDecl(
        typeName: 'Claim',
        version: BrainVersion.fromInt(2),
        supersedes: firstId,
        schema: <String, FieldSpec>{
          'text': const FieldSpec(
            name: 'text',
            type: FieldType.string,
            ftsEligible: true,
          ),
          'confidence': const FieldSpec(
            name: 'confidence',
            type: FieldType.string,
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

      final secondId = await registry.registerNodeType(v2);

      expect(secondId, isNot(equals(firstId)));
      expect(registry.get('Claim'), same(v2));
      expect(registry.declNodeIdOf('Claim'), equals(secondId));

      // DB has one row (PRIMARY KEY type_name).
      final rows = db.select('SELECT version, supersedes FROM node_types '
          'WHERE type_name = ?', <Object?>['Claim']);
      expect(rows, hasLength(1));
      expect(rows.first['version'], equals(2));
      expect(rows.first['supersedes'], equals(firstId.toString()));

      // Two events emitted in order.
      expect(events, hasLength(2));
      expect((events[0] as NodeTypeRegistered).version, equals(1));
      expect((events[1] as NodeTypeRegistered).version, equals(2));
      expect((events[1] as NodeTypeRegistered).supersedes, equals(firstId));
    });

    test('listAll returns insertion order', () async {
      final registry = buildRegistry();
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validTombstone());
      await registry.registerNodeType(_validQuestion());

      expect(
        registry.listAll().map((d) => d.typeName).toList(),
        equals(<String>['Claim', 'Tombstone', 'Question']),
      );
    });

    test('a second registry warms its cache from existing rows', () async {
      final first = buildRegistry();
      final id = await first.registerNodeType(_validClaim());

      // Construct a fresh registry over the same DB. It must not need
      // any explicit "load" call — `_ensureWarmed` is lazy.
      final second = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: _approveAll(),
      );

      final decl = second.get('Claim');
      expect(decl, isNotNull);
      expect(decl!.typeName, equals('Claim'));
      expect(decl.version.value, equals(1));
      expect(decl.allowedOutgoing, contains(EdgeType.derivedFrom));
      expect(second.declNodeIdOf('Claim'), equals(id));

      // listAll on the cold-loaded registry must contain the warmed
      // entry exactly once.
      expect(second.listAll(), hasLength(1));
    });

    test('hook receives a snapshot of currently-registered types', () async {
      final seen = <List<String>>[];
      final registry = buildRegistry(
        hook: (proposal, existing) async {
          seen.add(existing.map((d) => d.typeName).toList());
          return const CritiqueApproved();
        },
      );

      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validTombstone());
      await registry.registerNodeType(_validQuestion());

      expect(seen, equals(<List<String>>[
        <String>[],
        <String>['Claim'],
        <String>['Claim', 'Tombstone'],
      ]));
    });

    test('approval note is preserved in the emitted event', () async {
      final registry = buildRegistry(
        hook: (_, _) async => const CritiqueApproved(note: 'looks good'),
      );

      await registry.registerNodeType(_validClaim());

      expect((events.single as NodeTypeRegistered).critiqueNote,
          equals('looks good'));
    });

    // ──────────────────────────────────────────────────────────────
    // Structural validation — InvalidNodeTypeDecl
    // ──────────────────────────────────────────────────────────────

    test('rejects empty typeName', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(typeName: '');

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'typeName',
      );
      _expectNoCommit(db, events);
    });

    test('rejects non-PascalCase typeName', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(typeName: 'claim');

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'typeName',
      );
      _expectNoCommit(db, events);
    });

    test('rejects typeName starting with digit', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(typeName: '1Claim');

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'typeName',
      );
    });

    test('rejects version < 1 (via BrainVersion guard)', () {
      // BrainVersion itself rejects 0; the registry never sees it.
      // This test pins the upstream invariant so a future change to
      // BrainVersion that loosens the guard will surface here.
      expect(
        () => BrainVersion.fromInt(0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects empty schema', () async {
      final registry = buildRegistry();
      final decl = NodeTypeDecl(
        typeName: 'Claim',
        version: BrainVersion.fromInt(1),
        schema: const <String, FieldSpec>{},
        embeddingPolicy: EmbeddingPolicy.none,
        indexPolicy: const IndexPolicy(),
        retentionPolicy: RetentionPolicy.indefinite,
        allowedOutgoing: const <EdgeType>{},
        allowedIncoming: const <EdgeType>{},
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'schema',
      );
    });

    test('rejects FieldSpec.name mismatched with map key', () async {
      final registry = buildRegistry();
      final decl = NodeTypeDecl(
        typeName: 'Claim',
        version: BrainVersion.fromInt(1),
        schema: <String, FieldSpec>{
          'text': const FieldSpec(name: 'body', type: FieldType.string),
        },
        embeddingPolicy: EmbeddingPolicy.none,
        indexPolicy: const IndexPolicy(),
        retentionPolicy: RetentionPolicy.indefinite,
        allowedOutgoing: const <EdgeType>{},
        allowedIncoming: const <EdgeType>{},
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'schema.text.name',
      );
    });

    test('rejects empty validatorScriptId', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(validatorScriptId: '');

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'validatorScriptId',
      );
    });

    test('rejects embeddingPolicy.modelIdentity empty (not none)', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        embeddingPolicy: const EmbeddingPolicy(
          modelIdentity: '',
          dimensions: 768,
          sourceFields: <String>['text'],
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'embeddingPolicy.modelIdentity',
      );
    });

    test('rejects embeddingPolicy.dimensions <= 0', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        embeddingPolicy: const EmbeddingPolicy(
          modelIdentity: 'm',
          dimensions: 0,
          sourceFields: <String>['text'],
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'embeddingPolicy.dimensions',
      );
    });

    test('rejects empty embeddingPolicy.sourceFields', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        embeddingPolicy: const EmbeddingPolicy(
          modelIdentity: 'm',
          dimensions: 768,
          sourceFields: <String>[],
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'embeddingPolicy.sourceFields',
      );
    });

    test('rejects embeddingPolicy.sourceFields naming missing field',
        () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        embeddingPolicy: const EmbeddingPolicy(
          modelIdentity: 'm',
          dimensions: 768,
          sourceFields: <String>['ghost'],
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'embeddingPolicy.sourceFields',
      );
    });

    test('rejects embeddingPolicy.sourceFields naming non-string field',
        () async {
      final registry = buildRegistry();
      final decl = NodeTypeDecl(
        typeName: 'Claim',
        version: BrainVersion.fromInt(1),
        schema: <String, FieldSpec>{
          'text': const FieldSpec(
            name: 'text',
            type: FieldType.string,
            ftsEligible: true,
          ),
          'count': const FieldSpec(name: 'count', type: FieldType.integer),
        },
        embeddingPolicy: const EmbeddingPolicy(
          modelIdentity: 'm',
          dimensions: 768,
          sourceFields: <String>['count'],
        ),
        indexPolicy: const IndexPolicy(),
        retentionPolicy: RetentionPolicy.indefinite,
        allowedOutgoing: const <EdgeType>{},
        allowedIncoming: const <EdgeType>{},
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'embeddingPolicy.sourceFields',
      );
    });

    test('rejects indexPolicy.ftsFields naming missing field', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        indexPolicy: const IndexPolicy(
          ftsFields: <String>{'ghost'},
          vectorFields: <String>{},
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'indexPolicy.ftsFields',
      );
    });

    test('rejects indexPolicy.ftsFields naming non-eligible field', () async {
      final registry = buildRegistry();
      final decl = NodeTypeDecl(
        typeName: 'Claim',
        version: BrainVersion.fromInt(1),
        schema: <String, FieldSpec>{
          'text': const FieldSpec(name: 'text', type: FieldType.string),
        },
        embeddingPolicy: EmbeddingPolicy.none,
        indexPolicy: const IndexPolicy(
          ftsFields: <String>{'text'},
          vectorFields: <String>{},
        ),
        retentionPolicy: RetentionPolicy.indefinite,
        allowedOutgoing: const <EdgeType>{},
        allowedIncoming: const <EdgeType>{},
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'indexPolicy.ftsFields',
      );
    });

    test('rejects indexPolicy.vectorFields naming missing field', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        indexPolicy: const IndexPolicy(
          ftsFields: <String>{'text'},
          vectorFields: <String>{'ghost'},
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'indexPolicy.vectorFields',
      );
    });

    test('rejects indexPolicy.vectorFields naming non-vec field', () async {
      final registry = buildRegistry();
      final decl = _validClaim().copyWith(
        indexPolicy: const IndexPolicy(
          ftsFields: <String>{'text'},
          vectorFields: <String>{'text'},
        ),
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'indexPolicy.vectorFields',
      );
    });

    test('rejects indexPolicy.vectorFields naming non-eligible vec field',
        () async {
      final registry = buildRegistry();
      final decl = NodeTypeDecl(
        typeName: 'Pattern',
        version: BrainVersion.fromInt(1),
        schema: <String, FieldSpec>{
          'text': const FieldSpec(
            name: 'text',
            type: FieldType.string,
            ftsEligible: true,
          ),
          // vec field but explicitly NOT vectorEligible.
          'centroid': const FieldSpec(name: 'centroid', type: FieldType.vec),
        },
        embeddingPolicy: EmbeddingPolicy.none,
        indexPolicy: const IndexPolicy(
          ftsFields: <String>{},
          vectorFields: <String>{'centroid'},
        ),
        retentionPolicy: RetentionPolicy.indefinite,
        allowedOutgoing: const <EdgeType>{},
        allowedIncoming: const <EdgeType>{},
      );

      await _expectInvalid(
        () => registry.registerNodeType(decl),
        fieldPath: 'indexPolicy.vectorFields',
      );
    });

    // ──────────────────────────────────────────────────────────────
    // Cross-type consistency
    // ──────────────────────────────────────────────────────────────

    test('NodeTypeAlreadyExists when supersedes is null and name collides',
        () async {
      final registry = buildRegistry();
      await registry.registerNodeType(_validClaim());

      await expectLater(
        registry.registerNodeType(_validClaim()),
        throwsA(isA<NodeTypeAlreadyExists>()
            .having((e) => e.typeName, 'typeName', 'Claim')),
      );
      // First registration committed; second did not double-emit.
      expect(events, hasLength(1));
    });

    test('NodeTypeNotFound when supersedes set but type absent', () async {
      final registry = buildRegistry();
      final phantomId =
          NodeId.generate(at: fakeNow, randomness: List<int>.filled(16, 1));

      final decl = _validClaim().copyWith(
        version: BrainVersion.fromInt(2),
        supersedes: phantomId,
      );

      await expectLater(
        registry.registerNodeType(decl),
        throwsA(isA<NodeTypeNotFound>()
            .having((e) => e.typeName, 'typeName', 'Claim')
            .having(
              (e) => e.supersedesDeclNodeId,
              'supersedesDeclNodeId',
              phantomId.toString(),
            )
            .having((e) => e.registeredDeclNodeId, 'registeredDeclNodeId',
                isNull)),
      );
      _expectNoCommit(db, events);
    });

    test('NodeTypeNotFound when supersedes references stale decl-node id',
        () async {
      final registry = buildRegistry();
      final realId = await registry.registerNodeType(_validClaim());
      events.clear();

      final wrongId =
          NodeId.generate(at: fakeNow, randomness: List<int>.filled(16, 2));
      final decl = _validClaim().copyWith(
        version: BrainVersion.fromInt(2),
        supersedes: wrongId,
      );

      await expectLater(
        registry.registerNodeType(decl),
        throwsA(isA<NodeTypeNotFound>()
            .having(
              (e) => e.supersedesDeclNodeId,
              'supersedesDeclNodeId',
              wrongId.toString(),
            )
            .having(
              (e) => e.registeredDeclNodeId,
              'registeredDeclNodeId',
              realId.toString(),
            )),
      );
    });

    test('NodeTypeVersionNotMonotonic when supersedes set but version not >',
        () async {
      final registry = buildRegistry();
      final firstId = await registry.registerNodeType(_validClaim());
      events.clear();

      final decl = _validClaim().copyWith(
        version: BrainVersion.fromInt(1),
        supersedes: firstId,
      );

      await expectLater(
        registry.registerNodeType(decl),
        throwsA(isA<NodeTypeVersionNotMonotonic>()
            .having((e) => e.existingVersion, 'existingVersion', 1)
            .having((e) => e.proposedVersion, 'proposedVersion', 1)),
      );
    });

    // ──────────────────────────────────────────────────────────────
    // Critique
    // ──────────────────────────────────────────────────────────────

    test('NodeTypeRejected when hook returns CritiqueRejected', () async {
      final registry = buildRegistry(
        hook: (_, _) async => const CritiqueRejected(
          reason: 'overlaps Pattern',
          conflictingTypeNames: <String>['Pattern'],
        ),
      );

      await expectLater(
        registry.registerNodeType(_validClaim()),
        throwsA(isA<NodeTypeRejected>()
            .having((e) => e.reason, 'reason', 'overlaps Pattern')
            .having((e) => e.conflictingTypeNames,
                'conflictingTypeNames', equals(<String>['Pattern']))),
      );
      _expectNoCommit(db, events);
    });

    test('NodeTypeRejected when hook crashes preserves the crash message',
        () async {
      final registry = buildRegistry(
        hook: (_, _) async => throw StateError('engine offline'),
      );

      await expectLater(
        registry.registerNodeType(_validClaim()),
        throwsA(isA<NodeTypeRejected>()
            .having((e) => e.reason, 'reason', contains('engine offline'))),
      );
      _expectNoCommit(db, events);
    });

    test('event sink is optional — no callback configured', () async {
      final registry = buildRegistry(noEventSink: true);
      final id = await registry.registerNodeType(_validClaim());

      expect(id.toString(), startsWith('n_'));
      // The shared events list MUST NOT have grown — the sink wasn't
      // wired.
      expect(events, isEmpty);
      expect(registry.get('Claim'), isNotNull);
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────

CritiqueHook _approveAll() =>
    (proposal, existing) async => const CritiqueApproved();

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
      },
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: IndexPolicy.indexNothing,
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

NodeTypeDecl _validQuestion() => NodeTypeDecl(
      typeName: 'Question',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'prompt': const FieldSpec(
          name: 'prompt',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['prompt'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'prompt'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.motivates},
      allowedIncoming: const <EdgeType>{EdgeType.satisfiedBy},
    );

Future<void> _expectInvalid(
  Future<Object?> Function() call, {
  required String fieldPath,
}) async {
  await expectLater(
    call(),
    throwsA(isA<InvalidNodeTypeDecl>()
        .having((e) => e.fieldPath, 'fieldPath', fieldPath)),
  );
}

void _expectNoCommit(Database db, List<MemoryEvent> events) {
  final rows = db.select('SELECT COUNT(*) AS n FROM node_types');
  expect(rows.first['n'], equals(0));
  expect(events, isEmpty);
}

// ─── Test-only copyWith on NodeTypeDecl ────────────────────────
//
// `NodeTypeDecl` is a value type without a `copyWith`. Tests need to
// vary one field while holding the rest constant; without a
// `copyWith` helper each test would re-build the entire declaration
// inline and the failure-path tests would lose readability.
//
// Keeping this helper in the test file (rather than in `lib/`) is
// deliberate — `copyWith` is a test convenience, not part of the
// production API. Production callers construct fresh decls (typically
// from the YAML manifest loader).

extension _NodeTypeDeclCopyWith on NodeTypeDecl {
  NodeTypeDecl copyWith({
    String? typeName,
    BrainVersion? version,
    NodeId? supersedes,
    Map<String, FieldSpec>? schema,
    EmbeddingPolicy? embeddingPolicy,
    IndexPolicy? indexPolicy,
    RetentionPolicy? retentionPolicy,
    Vec? classificationCentroid,
    Set<EdgeType>? allowedOutgoing,
    Set<EdgeType>? allowedIncoming,
    String? validatorScriptId,
  }) =>
      NodeTypeDecl(
        typeName: typeName ?? this.typeName,
        version: version ?? this.version,
        supersedes: supersedes ?? this.supersedes,
        schema: schema ?? this.schema,
        embeddingPolicy: embeddingPolicy ?? this.embeddingPolicy,
        indexPolicy: indexPolicy ?? this.indexPolicy,
        retentionPolicy: retentionPolicy ?? this.retentionPolicy,
        classificationCentroid:
            classificationCentroid ?? this.classificationCentroid,
        allowedOutgoing: allowedOutgoing ?? this.allowedOutgoing,
        allowedIncoming: allowedIncoming ?? this.allowedIncoming,
        validatorScriptId: validatorScriptId ?? this.validatorScriptId,
      );
}
