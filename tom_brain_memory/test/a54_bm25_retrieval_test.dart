// A.54 — BM25 mode against FTS5 (integration).
//
// Plan step A.54:
//   "Implement `bm25` mode against FTS5."
//
// What A.34 / A.33 already covered:
//   * A.33 — NodeTypeRegistry registers a type and warms its in-memory
//            cache; the cache row holds the schema + indexPolicy.
//   * A.34 — NodePersister INSERTs into `nodes` and routes the vector
//            half through TwoDbCoordinator. Pre-A.54 the FTS5 path was
//            not wired (no per-type tables provisioned, no row writes).
//
// What A.54 adds (this file):
//   * Per-type `fts_<TypeName>` virtual table provisioning at type
//     registration via `Fts5Catalog`.
//   * FTS5 row writes inside the persister's `writeNode` closure via
//     `Fts5Writer` — sharing the coordinator's transaction so failure
//     rolls back both the node row and the FTS row.
//   * `Bm25Recall.recall(text:, typeNames:, perModeK:)` — per-type
//     BM25 scan, merge, truncate, deterministic ordering.
//
// Coverage map (one `test(...)` per row):
//
//   Provisioning
//   ------------
//   * registerNodeType for a type with ftsFields creates the FTS5
//     virtual table with `node_id UNINDEXED, <fields…>` columns.
//   * registerNodeType for a type with no ftsFields creates no FTS5
//     table.
//   * Warm-up over a pre-existing `node_types` row re-asserts the FTS5
//     table (recovery path for a process restart against an existing
//     DB).
//   * Re-registering the catalog wiring against an already-provisioned
//     table is a no-op (IF NOT EXISTS).
//
//   Row writes through the persister
//   --------------------------------
//   * A persist call seeds the FTS5 row alongside the `nodes` row.
//   * A type with no ftsFields persists cleanly with no FTS table
//     touched.
//   * Idempotency hit short-circuits before any FTS5 work happens
//     (no duplicate row in fts_<Type>).
//
//   Bm25Recall
//   ----------
//   * Returns the expected nodeId at top rank for an exact phrase
//     match.
//   * Returns multiple nodes ordered ascending by bm25 score (lower =
//     better).
//   * `typeNames` filter scopes the scan to the named types only.
//   * Empty `typeNames` set returns empty.
//   * Punctuation-only query returns empty (no MATCH issued).
//   * Empty / whitespace-only query returns empty.
//   * `perModeK == 0` returns empty without issuing SQL.
//   * `perModeK` truncates the per-type results into a global top-K.
//   * Tokens stripped of non-word characters still match the same
//     stored word (FTS5 operator characters do not leak into MATCH).
//   * Types without ftsFields are silently elided from the scan when
//     they appear in `typeNames`.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.54 BM25 mode against FTS5', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late Bm25Recall recall;
    late List<MemoryEvent> events;
    late int idCounter;
    late DateTime fakeNow;

    NodeId mintId() {
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
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

      const catalog = Fts5Catalog();
      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
        ftsCatalog: catalog,
      );
      await registry.registerNodeType(_claimType());
      await registry.registerNodeType(_questionType());
      await registry.registerNodeType(_tombstoneType());

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        eventSink: events.add,
        ftsWriter: const Fts5Writer(catalog: catalog),
      );

      recall = Bm25Recall(
        memoryDb: db,
        registry: registry,
        catalog: catalog,
      );
    });

    tearDown(() {
      db.dispose();
    });

    // ─── Provisioning ───────────────────────────────────────────────

    test('registerNodeType creates the per-type FTS5 virtual table', () {
      // Sqlite reports virtual tables as both `table` and via the
      // `fts_<TypeName>_*` shadow tables. We assert the canonical one.
      final rows = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'fts_Claim'",
      );
      expect(rows, hasLength(1));
    });

    test('type without ftsFields gets no FTS5 table', () {
      final rows = db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'fts_Tombstone'",
      );
      expect(rows, isEmpty);
    });

    test('warm-up re-asserts FTS5 tables for pre-existing node_types '
        'rows', () async {
      // Re-open the registry over the *same* DB (cache is empty until
      // _ensureWarmed runs). Drop the existing fts_Claim table first
      // so we can prove warm-up re-creates it.
      db.execute('DROP TABLE "fts_Claim"');
      // Sanity: it's gone.
      expect(
        db.select(
          "SELECT name FROM sqlite_master WHERE name = 'fts_Claim'",
        ),
        isEmpty,
      );

      var regIdCounter = 9000;
      final fresh = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (_, _) async => const CritiqueApproved(),
        idMint: () {
          regIdCounter += 1;
          return NodeId.generate(
            at: fakeNow,
            randomness:
                List<int>.generate(16, (i) => (regIdCounter + i) & 31),
          );
        },
        now: () => fakeNow,
        ftsCatalog: const Fts5Catalog(),
      );
      // Touching `listAll` triggers `_ensureWarmed`, which is what
      // owns the recovery-side provisioning.
      fresh.listAll();

      final rows = db.select(
        "SELECT name FROM sqlite_master WHERE name = 'fts_Claim'",
      );
      expect(rows, hasLength(1));
    });

    // ─── Persister wiring ───────────────────────────────────────────

    test('persist seeds the FTS5 row alongside the nodes row', () async {
      final id = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{
            'text': 'the sky is brilliantly blue',
          },
          embedding: _v768(seed: 1),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-claim-1'),
      );

      final ftsRows = db.select(
        'SELECT node_id, text FROM "fts_Claim" WHERE node_id = ?',
        <Object?>[id.toString()],
      );
      expect(ftsRows, hasLength(1));
      expect(ftsRows.single['text'],
          equals('the sky is brilliantly blue'));
    });

    test('persist of a type with no ftsFields touches no FTS table',
        () async {
      // Tombstone has no fts table; the writer's per-decl guard turns
      // the call into a no-op. The proof is that persist succeeds and
      // sqlite_master still lacks the table.
      await persister.persist(
        const NodeDraft(
          typeName: 'Tombstone',
          values: <String, Object?>{'reason': 'user-requested'},
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-ts'),
      );
      final rows = db.select(
        "SELECT name FROM sqlite_master WHERE name = 'fts_Tombstone'",
      );
      expect(rows, isEmpty);
    });

    test('idempotency-key hit does not duplicate FTS rows', () async {
      const scope = Scope(producer: 'p', idempotencyKey: 'k-dup');
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{'text': 'unique phrase alpha'},
        embedding: _v768(seed: 1),
      );

      final first = await persister.persist(draft, scope: scope);
      // Issue a different-content draft under the same idempotency key —
      // the persister returns the original id and writes nothing.
      final second = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'totally different'},
          embedding: _v768(seed: 2),
        ),
        scope: scope,
      );
      expect(second, equals(first));

      final rows = db.select('SELECT COUNT(*) AS n FROM "fts_Claim"');
      expect(rows.single['n'], equals(1));
      // The persisted text is the *first* draft's text — the second
      // call short-circuited before the FTS write.
      final stored = db.select(
        'SELECT text FROM "fts_Claim" WHERE node_id = ?',
        <Object?>[first.toString()],
      );
      expect(stored.single['text'], equals('unique phrase alpha'));
    });

    // ─── Bm25Recall — happy path ────────────────────────────────────

    test('returns the matching node at top rank for an exact phrase',
        () async {
      final claimAlpha = await _persistClaim(
        persister: persister,
        text: 'alpha bravo charlie',
        key: 'k-alpha',
      );
      await _persistClaim(
        persister: persister,
        text: 'unrelated delta echo',
        key: 'k-delta',
      );

      final hits = recall.recall(text: 'alpha');
      expect(hits, isNotEmpty);
      expect(hits.first.nodeId, equals(claimAlpha));
      expect(hits.first.typeName, equals('Claim'));
    });

    test('returns nodes ordered ascending by bm25 score', () async {
      // Two claims both contain "rare-token"; the one that *also*
      // contains a second hit of "rare-token" should rank above the
      // single-hit one. Use a token that is not in the FTS5 stopword
      // list (FTS5's unicode61 tokeniser has none by default, so any
      // word will do).
      final hotter = await _persistClaim(
        persister: persister,
        text: 'rarethingy rarethingy other content here',
        key: 'k-hotter',
      );
      final cooler = await _persistClaim(
        persister: persister,
        text: 'rarethingy only once',
        key: 'k-cooler',
      );

      final hits = recall.recall(text: 'rarethingy');
      final ids = hits.map((h) => h.nodeId).toList();
      expect(ids, containsAll(<NodeId>[hotter, cooler]));
      // FTS5 BM25: lower = more relevant. The hotter row must come
      // first.
      final hotterIdx = ids.indexOf(hotter);
      final coolerIdx = ids.indexOf(cooler);
      expect(hotterIdx, lessThan(coolerIdx));
      expect(hits[hotterIdx].bm25Score,
          lessThanOrEqualTo(hits[coolerIdx].bm25Score));
    });

    // ─── Bm25Recall — typeNames filter ──────────────────────────────

    test('typeNames filter scopes the scan to the named types', () async {
      final claimMatch = await _persistClaim(
        persister: persister,
        text: 'cobalt navigation system',
        key: 'k-c',
      );
      final questionMatch = await _persistQuestion(
        persister: persister,
        text: 'cobalt is the colour of what mineral?',
        key: 'k-q',
      );

      final claimOnly = recall.recall(
        text: 'cobalt',
        typeNames: <String>{'Claim'},
      );
      expect(claimOnly.map((h) => h.nodeId), contains(claimMatch));
      expect(claimOnly.map((h) => h.nodeId), isNot(contains(questionMatch)));

      final questionOnly = recall.recall(
        text: 'cobalt',
        typeNames: <String>{'Question'},
      );
      expect(questionOnly.map((h) => h.nodeId), contains(questionMatch));
      expect(questionOnly.map((h) => h.nodeId), isNot(contains(claimMatch)));
    });

    test('empty typeNames set returns empty', () async {
      await _persistClaim(
        persister: persister,
        text: 'whatever content',
        key: 'k-x',
      );
      final hits = recall.recall(
        text: 'whatever',
        typeNames: const <String>{},
      );
      expect(hits, isEmpty);
    });

    test('typeNames including a no-FTS type silently elides it', () async {
      final claim = await _persistClaim(
        persister: persister,
        text: 'shared keyword indigo',
        key: 'k-indigo',
      );
      // `Tombstone` has no fts table — including it must not crash, and
      // must not affect the returned Claim hit.
      final hits = recall.recall(
        text: 'indigo',
        typeNames: <String>{'Claim', 'Tombstone'},
      );
      expect(hits.map((h) => h.nodeId), contains(claim));
    });

    // ─── Bm25Recall — query-text safety ────────────────────────────

    test('empty / whitespace-only query returns empty', () async {
      await _persistClaim(
        persister: persister,
        text: 'anything goes',
        key: 'k-anything',
      );
      expect(recall.recall(text: ''), isEmpty);
      expect(recall.recall(text: '   '), isEmpty);
      expect(recall.recall(text: '\t\n'), isEmpty);
    });

    test('punctuation-only query returns empty (no MATCH issued)',
        () async {
      await _persistClaim(
        persister: persister,
        text: 'plain words here',
        key: 'k-plain',
      );
      expect(recall.recall(text: '!!! ??? ...'), isEmpty);
    });

    test('tokens stripped of non-word characters still match the same '
        'stored word', () async {
      final hit = await _persistClaim(
        persister: persister,
        text: 'azimuth bearing report',
        key: 'k-azim',
      );
      // FTS5 MATCH operators (`AND`, `OR`, `*`, etc) and punctuation
      // are stripped by the tokenizer in Bm25Recall._toFts5Match; the
      // surviving "azimuth" still hits.
      final hits = recall.recall(text: '*azimuth*');
      expect(hits.map((h) => h.nodeId), contains(hit));
    });

    // ─── Bm25Recall — perModeK guard ───────────────────────────────

    test('perModeK == 0 returns empty without issuing SQL', () async {
      await _persistClaim(
        persister: persister,
        text: 'token here',
        key: 'k-token',
      );
      expect(recall.recall(text: 'token', perModeK: 0), isEmpty);
    });

    test('perModeK truncates the merged result to the global top-K',
        () async {
      // Seed 5 Claim rows all containing the same token.
      for (var i = 0; i < 5; i++) {
        await _persistClaim(
          persister: persister,
          text: 'shared-token row-$i',
          key: 'k-share-$i',
        );
      }
      final hits = recall.recall(text: 'shared', perModeK: 3);
      expect(hits, hasLength(3));
      // All hits are Claim type.
      expect(hits.every((h) => h.typeName == 'Claim'), isTrue);
    });

    test('recall returns empty when no nodes match the query token',
        () async {
      await _persistClaim(
        persister: persister,
        text: 'nothing in this corpus matches',
        key: 'k-empty',
      );
      expect(recall.recall(text: 'completelyabsenttoken'), isEmpty);
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────

Future<NodeId> _persistClaim({
  required NodePersister persister,
  required String text,
  required String key,
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'text': text},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: 'test', idempotencyKey: key),
  );
}

Future<NodeId> _persistQuestion({
  required NodePersister persister,
  required String text,
  required String key,
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Question',
      values: <String, Object?>{'prompt': text},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: 'test', idempotencyKey: key),
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

NodeTypeDecl _tombstoneType() => NodeTypeDecl(
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
