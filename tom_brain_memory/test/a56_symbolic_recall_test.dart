// A.56 — symbolic mode against SQLite (integration + compiler).
//
// Plan step A.56:
//   "Implement `symbolic` filter language (type, time window, scope,
//    attribute equality) compiled into SQL `WHERE`."
//
// What this file covers (one `test(...)` per row):
//
//   compileSymbolicFilter — pure-function compiler
//   --------------------------------------------------
//   * Empty filter compiles to the tautology `1` with empty bindings.
//   * typeNames compiles to `type_name IN (?, ...)` with one binding
//     per type.
//   * createdAfter compiles to `created_at_ms >= ?` with epoch-ms.
//   * createdBefore compiles to `created_at_ms < ?` with epoch-ms.
//   * producer compiles to `produced_by = ?`.
//   * Attribute `eq` with non-null compiles to `json_extract(...) = ?`.
//   * Attribute `eq` with null compiles to `json_extract(...) IS NULL`.
//   * Attribute `ne` with non-null includes the NULL branch.
//   * Attribute `ne` with null compiles to `IS NOT NULL`.
//   * Attribute `lt/lte/gt/gte` compiles with the correct SQL op.
//   * Attribute `inList` compiles to `IN (?, ?, ...)`.
//   * Attribute `notInList` compiles to `NOT IN (?, ?, ...)`.
//   * Multiple clauses are AND-ed in order: type, time, producer,
//     attributes.
//   * Field-name validation — bad identifier raises ArgumentError.
//   * `lt` with a null value raises ArgumentError.
//   * `inList` with a non-list value raises ArgumentError.
//   * `inList` with an empty list raises ArgumentError.
//
//   SymbolicRecall — DB integration
//   --------------------------------
//   * typeNames filter narrows the result to the named types.
//   * Time-window filter [after, before) returns only rows in the
//     half-open range.
//   * producer filter returns only rows whose `Scope.producer`
//     matches.
//   * Attribute `eq` finds the matching row.
//   * Attribute `inList` finds the union; rows whose attribute lies
//     outside the list are excluded.
//   * Empty filter returns the newest perModeK nodes (tautology).
//   * Result is ordered newest-first by created_at_ms, tie-broken by
//     id ascending.
//   * perModeK == 0 returns empty without issuing SQL.
//   * perModeK negative returns empty without issuing SQL.
//   * perModeK truncates the result.
//   * Empty corpus returns empty.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.56 symbolic filter compiler', () {
    test('empty filter compiles to the tautology', () {
      final compiled = compileSymbolicFilter(const SymbolicFilter());
      expect(compiled.whereSql, equals('1'));
      expect(compiled.bindings, isEmpty);
    });

    test('typeNames compiles to type_name IN (?, ?, ...)', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(typeNames: <String>{'Claim', 'Question'}),
      );
      expect(compiled.whereSql, contains('type_name IN ('));
      // One placeholder per type name.
      expect('?'.allMatches(compiled.whereSql), hasLength(2));
      expect(compiled.bindings, containsAll(<String>['Claim', 'Question']));
      expect(compiled.bindings, hasLength(2));
    });

    test('createdAfter compiles to created_at_ms >= ? with epoch-ms', () {
      final t = DateTime.utc(2026, 5, 30, 14, 0, 0);
      final compiled = compileSymbolicFilter(
        SymbolicFilter(createdAfter: t),
      );
      expect(compiled.whereSql, equals('created_at_ms >= ?'));
      expect(compiled.bindings, equals(<Object?>[t.millisecondsSinceEpoch]));
    });

    test('createdBefore compiles to created_at_ms < ? with epoch-ms', () {
      final t = DateTime.utc(2026, 5, 30, 15, 0, 0);
      final compiled = compileSymbolicFilter(
        SymbolicFilter(createdBefore: t),
      );
      expect(compiled.whereSql, equals('created_at_ms < ?'));
      expect(compiled.bindings, equals(<Object?>[t.millisecondsSinceEpoch]));
    });

    test('producer compiles to produced_by = ?', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(producer: 'thinker-1'),
      );
      expect(compiled.whereSql, equals('produced_by = ?'));
      expect(compiled.bindings, equals(<Object?>['thinker-1']));
    });

    test('attribute eq with non-null value compiles to json_extract = ?',
        () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('confidence', SymbolicOp.eq, 0.9),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals('json_extract(attrs_json, ?) = ?'),
      );
      expect(
        compiled.bindings,
        equals(<Object?>[r'$.confidence', 0.9]),
      );
    });

    test('attribute eq with null compiles to json_extract IS NULL', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('archived', SymbolicOp.eq, null),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals('json_extract(attrs_json, ?) IS NULL'),
      );
      expect(compiled.bindings, equals(<Object?>[r'$.archived']));
    });

    test('attribute ne with non-null includes the NULL branch', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('status', SymbolicOp.ne, 'archived'),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals(
          '(json_extract(attrs_json, ?) != ? OR '
          'json_extract(attrs_json, ?) IS NULL)',
        ),
      );
      expect(
        compiled.bindings,
        equals(<Object?>[r'$.status', 'archived', r'$.status']),
      );
    });

    test('attribute ne with null compiles to IS NOT NULL', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('owner', SymbolicOp.ne, null),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals('json_extract(attrs_json, ?) IS NOT NULL'),
      );
      expect(compiled.bindings, equals(<Object?>[r'$.owner']));
    });

    test('lt/lte/gt/gte map to <, <=, >, >=', () {
      for (final entry in <SymbolicOp, String>{
        SymbolicOp.lt: '<',
        SymbolicOp.lte: '<=',
        SymbolicOp.gt: '>',
        SymbolicOp.gte: '>=',
      }.entries) {
        final compiled = compileSymbolicFilter(
          SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('confidence', entry.key, 0.5),
            ],
          ),
        );
        expect(
          compiled.whereSql,
          equals('json_extract(attrs_json, ?) ${entry.value} ?'),
          reason: 'op ${entry.key.name} should map to ${entry.value}',
        );
        expect(compiled.bindings, equals(<Object?>[r'$.confidence', 0.5]));
      }
    });

    test('inList compiles to json_extract IN (?, ?, ...)', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('category', SymbolicOp.inList, <String>['a', 'b', 'c']),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals('json_extract(attrs_json, ?) IN (?, ?, ?)'),
      );
      expect(
        compiled.bindings,
        equals(<Object?>[r'$.category', 'a', 'b', 'c']),
      );
    });

    test('notInList compiles to json_extract NOT IN (?, ?, ...)', () {
      final compiled = compileSymbolicFilter(
        const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('category', SymbolicOp.notInList, <String>['a']),
          ],
        ),
      );
      expect(
        compiled.whereSql,
        equals('json_extract(attrs_json, ?) NOT IN (?)'),
      );
      expect(
        compiled.bindings,
        equals(<Object?>[r'$.category', 'a']),
      );
    });

    test('multiple clauses are AND-ed in declaration order', () {
      final at = DateTime.utc(2026, 5, 30);
      final compiled = compileSymbolicFilter(
        SymbolicFilter(
          typeNames: const <String>{'Claim'},
          createdAfter: at,
          producer: 'p',
          attributes: const <AttrClause>[
            AttrClause('text', SymbolicOp.eq, 'hello'),
          ],
        ),
      );
      // Order: type → time → producer → attributes.
      expect(
        compiled.whereSql,
        equals(
          'type_name IN (?) AND created_at_ms >= ? AND produced_by = ? AND '
          'json_extract(attrs_json, ?) = ?',
        ),
      );
      expect(
        compiled.bindings,
        equals(<Object?>[
          'Claim',
          at.millisecondsSinceEpoch,
          'p',
          r'$.text',
          'hello',
        ]),
      );
    });

    test('bad field-name raises ArgumentError', () {
      expect(
        () => compileSymbolicFilter(
          const SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('bad name', SymbolicOp.eq, 1),
            ],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => compileSymbolicFilter(
          const SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('', SymbolicOp.eq, 1),
            ],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => compileSymbolicFilter(
          const SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('with.dot', SymbolicOp.eq, 1),
            ],
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('comparison op with null value raises ArgumentError', () {
      for (final op in <SymbolicOp>[
        SymbolicOp.lt,
        SymbolicOp.lte,
        SymbolicOp.gt,
        SymbolicOp.gte,
      ]) {
        expect(
          () => compileSymbolicFilter(
            SymbolicFilter(
              attributes: <AttrClause>[AttrClause('x', op, null)],
            ),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'op ${op.name} should refuse a null value',
        );
      }
    });

    test('inList / notInList with a non-list value raises ArgumentError',
        () {
      for (final op in <SymbolicOp>[
        SymbolicOp.inList,
        SymbolicOp.notInList,
      ]) {
        expect(
          () => compileSymbolicFilter(
            SymbolicFilter(
              attributes: <AttrClause>[AttrClause('x', op, 'not-a-list')],
            ),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'op ${op.name} should refuse a scalar value',
        );
      }
    });

    test('inList / notInList with an empty list raises ArgumentError', () {
      for (final op in <SymbolicOp>[
        SymbolicOp.inList,
        SymbolicOp.notInList,
      ]) {
        expect(
          () => compileSymbolicFilter(
            SymbolicFilter(
              attributes: <AttrClause>[AttrClause('x', op, const <int>[])],
            ),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'op ${op.name} should refuse an empty list',
        );
      }
    });
  });

  group('A.56 SymbolicRecall against memory.db', () {
    late Database memoryDb;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late SymbolicRecall recall;
    late int idCounter;
    late DateTime fakeNow;
    late _RecordingVectorApplier applier;

    NodeId mintId() {
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    setUp(() async {
      memoryDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);
      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );

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

      const catalog = Fts5Catalog();
      registry = NodeTypeRegistry(
        memoryDb: memoryDb,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
        ftsCatalog: catalog,
      );
      await registry.registerNodeType(_claimType());
      await registry.registerNodeType(_questionType());

      persister = NodePersister(
        memoryDb: memoryDb,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        ftsWriter: const Fts5Writer(catalog: catalog),
      );

      recall = SymbolicRecall(memoryDb: memoryDb);
    });

    tearDown(() {
      memoryDb.dispose();
    });

    // ─── DB integration ────────────────────────────────────────────

    test('typeNames filter narrows the result to the named types',
        () async {
      final claim = await _persistClaim(
        persister: persister,
        text: 'a',
        confidence: 0.5,
        key: 'k-claim',
      );
      final question = await _persistQuestion(
        persister: persister,
        prompt: 'q',
        priority: 1,
        key: 'k-q',
      );

      final claimOnly = recall.recall(
        filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
      );
      expect(claimOnly.map((h) => h.nodeId), contains(claim));
      expect(claimOnly.map((h) => h.nodeId), isNot(contains(question)));

      final questionOnly = recall.recall(
        filter: const SymbolicFilter(typeNames: <String>{'Question'}),
      );
      expect(questionOnly.map((h) => h.nodeId), contains(question));
      expect(questionOnly.map((h) => h.nodeId), isNot(contains(claim)));
    });

    test('time window [after, before) returns only rows in the range',
        () async {
      // Persist three claims at three distinct times.
      fakeNow = DateTime.utc(2026, 5, 30, 10, 0, 0);
      final early = await _persistClaim(
        persister: persister,
        text: 'early',
        confidence: 0.1,
        key: 'k-early',
      );
      fakeNow = DateTime.utc(2026, 5, 30, 12, 0, 0);
      final mid = await _persistClaim(
        persister: persister,
        text: 'mid',
        confidence: 0.5,
        key: 'k-mid',
      );
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      final late_ = await _persistClaim(
        persister: persister,
        text: 'late',
        confidence: 0.9,
        key: 'k-late',
      );

      // Half-open window: [11:00, 14:00) — includes mid, excludes early
      // (before) and late (at the exclusive upper bound).
      final hits = recall.recall(
        filter: SymbolicFilter(
          createdAfter: DateTime.utc(2026, 5, 30, 11, 0, 0),
          createdBefore: DateTime.utc(2026, 5, 30, 14, 0, 0),
        ),
      );
      final ids = hits.map((h) => h.nodeId).toSet();
      expect(ids, contains(mid));
      expect(ids, isNot(contains(early)));
      expect(ids, isNot(contains(late_)));
    });

    test('producer filter returns only rows with matching Scope.producer',
        () async {
      final mine = await _persistClaim(
        persister: persister,
        text: 'mine',
        confidence: 0.5,
        key: 'k-mine',
        producer: 'me',
      );
      final yours = await _persistClaim(
        persister: persister,
        text: 'yours',
        confidence: 0.5,
        key: 'k-yours',
        producer: 'you',
      );

      final hits = recall.recall(
        filter: const SymbolicFilter(producer: 'me'),
      );
      final ids = hits.map((h) => h.nodeId).toSet();
      expect(ids, contains(mine));
      expect(ids, isNot(contains(yours)));
    });

    test('attribute eq finds the matching row', () async {
      final target = await _persistClaim(
        persister: persister,
        text: 'pick me',
        confidence: 0.95,
        key: 'k-target',
      );
      final other = await _persistClaim(
        persister: persister,
        text: 'skip me',
        confidence: 0.42,
        key: 'k-other',
      );

      final hits = recall.recall(
        filter: const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause('confidence', SymbolicOp.eq, 0.95),
          ],
        ),
      );
      final ids = hits.map((h) => h.nodeId).toSet();
      expect(ids, contains(target));
      expect(ids, isNot(contains(other)));
    });

    test('attribute inList finds the union of matching rows', () async {
      final a = await _persistClaim(
        persister: persister,
        text: 'a',
        confidence: 0.1,
        key: 'k-a',
      );
      final b = await _persistClaim(
        persister: persister,
        text: 'b',
        confidence: 0.5,
        key: 'k-b',
      );
      final c = await _persistClaim(
        persister: persister,
        text: 'c',
        confidence: 0.9,
        key: 'k-c',
      );

      final hits = recall.recall(
        filter: const SymbolicFilter(
          attributes: <AttrClause>[
            AttrClause(
              'confidence',
              SymbolicOp.inList,
              <double>[0.1, 0.9],
            ),
          ],
        ),
      );
      final ids = hits.map((h) => h.nodeId).toSet();
      expect(ids, containsAll(<NodeId>[a, c]));
      expect(ids, isNot(contains(b)));
    });

    test('empty filter returns the newest perModeK nodes', () async {
      // Seed 4 claims at distinct times.
      final ids = <NodeId>[];
      for (var i = 0; i < 4; i++) {
        fakeNow = DateTime.utc(2026, 5, 30, 10 + i, 0, 0);
        ids.add(
          await _persistClaim(
            persister: persister,
            text: 'row-$i',
            confidence: 0.1 * i,
            key: 'k-empty-$i',
          ),
        );
      }
      final hits = recall.recall(
        filter: const SymbolicFilter(),
        perModeK: 2,
      );
      // Newest two: rows at hour 13 and 12 → ids[3] and ids[2].
      expect(hits, hasLength(2));
      expect(hits.first.nodeId, equals(ids[3]));
      expect(hits[1].nodeId, equals(ids[2]));
    });

    test('result is ordered newest-first by created_at_ms', () async {
      fakeNow = DateTime.utc(2026, 5, 30, 10, 0, 0);
      final old_ = await _persistClaim(
        persister: persister,
        text: 'old',
        confidence: 0.1,
        key: 'k-old',
      );
      fakeNow = DateTime.utc(2026, 5, 30, 12, 0, 0);
      final newer = await _persistClaim(
        persister: persister,
        text: 'newer',
        confidence: 0.5,
        key: 'k-new',
      );

      final hits = recall.recall(filter: const SymbolicFilter());
      // Newer comes first.
      final idx = <NodeId, int>{
        for (var i = 0; i < hits.length; i++) hits[i].nodeId: i,
      };
      expect(idx[newer], lessThan(idx[old_] ?? -1));
    });

    test('two rows at the same created_at_ms tie-break by id ascending',
        () async {
      // Both persist at fakeNow without bumping the clock — identical
      // created_at_ms by construction.
      final a = await _persistClaim(
        persister: persister,
        text: 'tie-a',
        confidence: 0.5,
        key: 'k-tie-a',
      );
      final b = await _persistClaim(
        persister: persister,
        text: 'tie-b',
        confidence: 0.5,
        key: 'k-tie-b',
      );

      final hits = recall.recall(filter: const SymbolicFilter());
      final tied = hits
          .where((h) => h.nodeId == a || h.nodeId == b)
          .map((h) => h.nodeId.toString())
          .toList();
      final sortedAsc = List<String>.from(tied)..sort();
      expect(tied, equals(sortedAsc),
          reason: 'Tied rows must be returned in id-ascending order.');
    });

    test('perModeK == 0 returns empty without issuing SQL', () async {
      await _persistClaim(
        persister: persister,
        text: 'present',
        confidence: 0.5,
        key: 'k-zero',
      );
      expect(
        recall.recall(filter: const SymbolicFilter(), perModeK: 0),
        isEmpty,
      );
    });

    test('perModeK negative returns empty without issuing SQL', () async {
      await _persistClaim(
        persister: persister,
        text: 'present',
        confidence: 0.5,
        key: 'k-neg',
      );
      expect(
        recall.recall(filter: const SymbolicFilter(), perModeK: -1),
        isEmpty,
      );
    });

    test('perModeK truncates the result', () async {
      for (var i = 0; i < 5; i++) {
        await _persistClaim(
          persister: persister,
          text: 'row-$i',
          confidence: 0.5,
          key: 'k-trunc-$i',
        );
      }
      final hits = recall.recall(
        filter: const SymbolicFilter(),
        perModeK: 3,
      );
      expect(hits, hasLength(3));
    });

    test('empty corpus returns empty', () async {
      final hits = recall.recall(filter: const SymbolicFilter());
      expect(hits, isEmpty);
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────

Future<NodeId> _persistClaim({
  required NodePersister persister,
  required String text,
  required double confidence,
  required String key,
  String producer = 'test',
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'text': text, 'confidence': confidence},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: producer, idempotencyKey: key),
  );
}

Future<NodeId> _persistQuestion({
  required NodePersister persister,
  required String prompt,
  required int priority,
  required String key,
  String producer = 'test',
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Question',
      values: <String, Object?>{'prompt': prompt, 'priority': priority},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: producer, idempotencyKey: key),
  );
}

NodeTypeDecl _claimType() => NodeTypeDecl(
      typeName: 'Claim',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'text': const FieldSpec(
          name: 'text',
          type: FieldType.string,
          ftsEligible: true,
        ),
        'confidence': const FieldSpec(
          name: 'confidence',
          type: FieldType.json,
          nullable: true,
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

NodeTypeDecl _questionType() => NodeTypeDecl(
      typeName: 'Question',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'prompt': const FieldSpec(
          name: 'prompt',
          type: FieldType.string,
          ftsEligible: true,
        ),
        'priority': const FieldSpec(
          name: 'priority',
          type: FieldType.integer,
          nullable: true,
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

Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

// ─── In-memory fake VectorApplier ───────────────────────────────

final class _RecordingVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> calls = <PendingVectorWrite>[];

  @override
  void apply(PendingVectorWrite write) {
    calls.add(write);
  }
}
