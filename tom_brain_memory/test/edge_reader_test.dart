// A.37 — EdgeReader contract test.
//
// Covers `EdgeReader.edgesOf` end-to-end against a real in-memory
// SQLite engine. Validates direction filtering, type filtering,
// determinism, dangling-id tolerance, and attrs/weight round-trip.
//
// Coverage map (one `test(...)` per row):
//
//   Direction filter
//   ----------------
//   * `both` (default) returns outgoing + incoming, ordered by
//     `created_at_ms ASC, id ASC`.
//   * `outgoing` returns only edges where the id is `from`.
//   * `incoming` returns only edges where the id is `to`.
//
//   Type filter
//   -----------
//   * `types = null` returns every label.
//   * `types = <Set>{}` (explicit empty) returns `[]` without
//     touching the database (asymmetric to `null`; see Q-A.37.2).
//   * `types = <Set>{a}` returns only edges of that label.
//   * `types = <Set>{a, b}` returns the union.
//
//   Determinism
//   -----------
//   * Re-running `edgesOf` on the same store returns the rows in the
//     identical order across calls.
//   * Insertion-order vs. id-order tiebreak: two edges with the same
//     `created_at_ms` come back in `id ASC` order.
//
//   Edge cases
//   ----------
//   * `edgesOf` on a NodeId that never existed returns `[]` (no
//     throw — dangling-id tolerance per Q-A.37.1).
//   * Self-loop: an edge from a node to itself returns ONCE under
//     `both`, ONCE under `outgoing`, and ONCE under `incoming`.
//   * Empty `attrs_json` column (NULL) decodes to an empty map.
//   * Non-empty `attrs_json` round-trips.
//   * Custom `weight` round-trips.
//
// The reader is tested without going through `SqliteTomBrainMemory`
// (which doesn't exist yet). Tests construct the reader, writer, and
// registry directly using the already-tested `NodePersister` (A.34)
// for fixture nodes.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, EdgeId, FixedClock, NodeId, Vec;

void main() {
  group('A.37 EdgeReader.edgesOf', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late EdgeWriter writer;
    late EdgeReader reader;
    late int nodeIdCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;

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
      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      nodeIdCounter = 0;
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
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validSource());
      await registry.registerNodeType(_validConclusion());

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
      );

      writer = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
      );

      reader = EdgeReader(memoryDb: db);
    });

    tearDown(() {
      db.dispose();
    });

    Future<NodeId> persistClaim(String text, {required String key}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: key.hashCode),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    Future<NodeId> persistSource(String url, {required String key}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Source',
          values: <String, Object?>{'url': url},
          embedding: _v768(seed: key.hashCode + 7),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    Future<NodeId> persistConclusion(String text, {required String key}) {
      return persister.persist(
        NodeDraft(
          typeName: 'Conclusion',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: key.hashCode + 13),
        ),
        scope: Scope(producer: 'test', idempotencyKey: key),
      );
    }

    // ─── Direction filter ────────────────────────────────────────────

    test('default direction=both returns outgoing AND incoming', () async {
      final claim = await persistClaim('seed', key: 'c1');
      final src1 = await persistSource('https://a.example', key: 's1');
      final src2 = await persistSource('https://b.example', key: 's2');
      final conclusion =
          await persistConclusion('summary', key: 'cn1');

      // Outgoing: claim --derived_from--> src1
      final e1 = await writer.edge(claim, EdgeType.derivedFrom, src1);
      // Outgoing: claim --evidence_for--> conclusion
      final e2 =
          await writer.edge(claim, EdgeType.evidenceFor, conclusion);
      // Incoming: src2 --evidence_for--> claim
      final e3 = await writer.edge(src2, EdgeType.evidenceFor, claim);

      final edges = await reader.edgesOf(claim);
      expect(edges.map((e) => e.id), containsAll(<EdgeId>[e1, e2, e3]));
      expect(edges, hasLength(3));
    });

    test('direction=outgoing returns only from-edges', () async {
      final claim = await persistClaim('seed', key: 'c2');
      final src1 = await persistSource('https://x.example', key: 's3');
      final src2 = await persistSource('https://y.example', key: 's4');

      final e1 = await writer.edge(claim, EdgeType.derivedFrom, src1);
      await writer.edge(src2, EdgeType.evidenceFor, claim); // incoming

      final edges = await reader.edgesOf(
        claim,
        direction: EdgeDirection.outgoing,
      );
      expect(edges.map((e) => e.id), equals(<EdgeId>[e1]));
      expect(edges.single.from, equals(claim));
      expect(edges.single.to, equals(src1));
    });

    test('direction=incoming returns only to-edges', () async {
      final claim = await persistClaim('seed', key: 'c3');
      final src1 = await persistSource('https://m.example', key: 's5');
      final src2 = await persistSource('https://n.example', key: 's6');

      await writer.edge(claim, EdgeType.derivedFrom, src1); // outgoing
      final e2 = await writer.edge(src2, EdgeType.evidenceFor, claim);

      final edges = await reader.edgesOf(
        claim,
        direction: EdgeDirection.incoming,
      );
      expect(edges.map((e) => e.id), equals(<EdgeId>[e2]));
      expect(edges.single.from, equals(src2));
      expect(edges.single.to, equals(claim));
    });

    // ─── Type filter ─────────────────────────────────────────────────

    test('types=null returns every label', () async {
      final claim = await persistClaim('seed', key: 'c4');
      final src = await persistSource('https://k.example', key: 's7');
      final conc = await persistConclusion('summary', key: 'cn2');

      await writer.edge(claim, EdgeType.derivedFrom, src);
      await writer.edge(claim, EdgeType.evidenceFor, conc);

      final edges = await reader.edgesOf(claim);
      expect(
        edges.map((e) => e.type).toSet(),
        equals(<EdgeType>{EdgeType.derivedFrom, EdgeType.evidenceFor}),
      );
    });

    test('types=<Set>{} returns [] without touching the database',
        () async {
      final claim = await persistClaim('seed', key: 'c5');
      final src = await persistSource('https://q.example', key: 's8');
      await writer.edge(claim, EdgeType.derivedFrom, src);

      // Sanity: with the default filter there IS an edge.
      expect(await reader.edgesOf(claim), hasLength(1));

      // Explicit empty set is the "no labels match" filter.
      final edges = await reader.edgesOf(
        claim,
        types: const <EdgeType>{},
      );
      expect(edges, isEmpty);
    });

    test('types=<Set>{one} returns only that label', () async {
      final claim = await persistClaim('seed', key: 'c6');
      final src = await persistSource('https://r.example', key: 's9');
      final conc = await persistConclusion('summary', key: 'cn3');

      await writer.edge(claim, EdgeType.derivedFrom, src);
      await writer.edge(claim, EdgeType.evidenceFor, conc);

      final edges = await reader.edgesOf(
        claim,
        types: const <EdgeType>{EdgeType.derivedFrom},
      );
      expect(edges, hasLength(1));
      expect(edges.single.type, equals(EdgeType.derivedFrom));
      expect(edges.single.to, equals(src));
    });

    test('types=<Set>{a,b} returns the union', () async {
      final claim = await persistClaim('seed', key: 'c7');
      final src = await persistSource('https://t.example', key: 's10');
      final conc = await persistConclusion('summary', key: 'cn4');
      final src2 = await persistSource('https://u.example', key: 's11');

      await writer.edge(claim, EdgeType.derivedFrom, src);
      await writer.edge(claim, EdgeType.evidenceFor, conc);
      await writer.edge(src2, EdgeType.evidenceFor, claim);
      // The mentions edge is rejected by the registry — Claim's
      // allowedOutgoing is {derivedFrom, evidenceFor}. So we cannot
      // sneak in a third unrelated label without expanding the
      // fixture; the union-of-two case is the right scope.

      final edges = await reader.edgesOf(
        claim,
        types: const <EdgeType>{EdgeType.derivedFrom, EdgeType.evidenceFor},
      );
      expect(edges, hasLength(3));
      expect(
        edges.map((e) => e.type).toSet(),
        equals(<EdgeType>{EdgeType.derivedFrom, EdgeType.evidenceFor}),
      );
    });

    // ─── Determinism ─────────────────────────────────────────────────

    test('repeated edgesOf calls return identical order', () async {
      final claim = await persistClaim('seed', key: 'c8');
      final src = await persistSource('https://o.example', key: 's12');
      final conc = await persistConclusion('summary', key: 'cn5');

      await writer.edge(claim, EdgeType.derivedFrom, src);
      await writer.edge(claim, EdgeType.evidenceFor, conc);

      final first = await reader.edgesOf(claim);
      final second = await reader.edgesOf(claim);
      expect(
        second.map((e) => e.id).toList(),
        equals(first.map((e) => e.id).toList()),
      );
    });

    test('same-timestamp edges tiebreak by id ASC', () async {
      // All inserts use fakeNow, so every row shares created_at_ms.
      // The ORDER BY tiebreak is `id ASC`.
      final claim = await persistClaim('seed', key: 'c9');
      final src1 = await persistSource('https://1.example', key: 's13');
      final src2 = await persistSource('https://2.example', key: 's14');
      final src3 = await persistSource('https://3.example', key: 's15');

      final e1 = await writer.edge(claim, EdgeType.derivedFrom, src1);
      final e2 = await writer.edge(claim, EdgeType.derivedFrom, src2);
      final e3 = await writer.edge(claim, EdgeType.derivedFrom, src3);

      final ids = <EdgeId>[e1, e2, e3]
        ..sort((a, b) => a.toString().compareTo(b.toString()));

      final edges = await reader.edgesOf(claim);
      expect(edges.map((e) => e.id).toList(), equals(ids));
    });

    // ─── Edge cases ──────────────────────────────────────────────────

    test('edgesOf on a never-persisted id returns [] (no throw)',
        () async {
      final phantom = NodeId.generate();
      expect(await reader.edgesOf(phantom), isEmpty);
      expect(
        await reader.edgesOf(phantom, direction: EdgeDirection.outgoing),
        isEmpty,
      );
      expect(
        await reader.edgesOf(phantom, direction: EdgeDirection.incoming),
        isEmpty,
      );
      expect(
        await reader.edgesOf(
          phantom,
          types: const <EdgeType>{EdgeType.derivedFrom},
        ),
        isEmpty,
      );
    });

    test('self-loop returns the row exactly once under direction=both',
        () async {
      // Conclusion --derived_from--> Conclusion: Conclusion's
      // allowedOutgoing includes derivedFrom; Conclusion's
      // allowedIncoming does NOT include derivedFrom (it accepts only
      // evidenceFor). So a Conclusion → Conclusion derived_from edge
      // would be rejected.
      //
      // Use Claim → Claim with evidenceFor instead: Claim's
      // allowedOutgoing AND allowedIncoming both include evidenceFor.
      final claim = await persistClaim('reflexive', key: 'csl');
      final e1 = await writer.edge(claim, EdgeType.evidenceFor, claim);

      final both = await reader.edgesOf(claim);
      expect(both, hasLength(1));
      expect(both.single.id, equals(e1));

      final out = await reader.edgesOf(
        claim,
        direction: EdgeDirection.outgoing,
      );
      expect(out.map((e) => e.id), equals(<EdgeId>[e1]));

      final inc = await reader.edgesOf(
        claim,
        direction: EdgeDirection.incoming,
      );
      expect(inc.map((e) => e.id), equals(<EdgeId>[e1]));
    });

    test('empty attrs_json column decodes to empty map', () async {
      final claim = await persistClaim('seed', key: 'cae');
      final src = await persistSource('https://e.example', key: 'sae');
      await writer.edge(claim, EdgeType.derivedFrom, src);

      final edges = await reader.edgesOf(claim);
      expect(edges.single.attrs, isEmpty);
      // Sanity: the column itself is NULL.
      final row =
          db.select('SELECT attrs_json FROM edges').first;
      expect(row['attrs_json'], isNull);
    });

    test('non-empty attrs round-trip into Edge.attrs', () async {
      // PlanStep dependencies are not in the fixture set above; reuse
      // a Claim --evidence_for--> Claim self-edge with a custom attrs
      // bag instead. attrs are an opaque map at the storage layer.
      final claim = await persistClaim('seed', key: 'cae2');
      final attrs = <String, Object?>{'kind': 'depends_on', 'rank': 3};
      await writer.edge(
        claim,
        EdgeType.evidenceFor,
        claim,
        attrs: attrs,
      );

      final edges = await reader.edgesOf(claim);
      expect(edges.single.attrs, equals(attrs));
    });

    test('custom weight round-trips', () async {
      final claim = await persistClaim('seed', key: 'cw');
      final src = await persistSource('https://w.example', key: 'sw');
      await writer.edge(
        claim,
        EdgeType.derivedFrom,
        src,
        weight: 0.42,
      );

      final edges = await reader.edgesOf(claim);
      expect(edges.single.weight, closeTo(0.42, 1e-9));
    });

    test('reader sees rows committed by writer (no caching)', () async {
      final claim = await persistClaim('seed', key: 'cnc');
      final src = await persistSource('https://nc.example', key: 'snc');

      expect(await reader.edgesOf(claim), isEmpty);
      await writer.edge(claim, EdgeType.derivedFrom, src);
      expect(await reader.edgesOf(claim), hasLength(1));
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
      // Outgoing: derivedFrom, evidenceFor.
      allowedOutgoing: const <EdgeType>{
        EdgeType.derivedFrom,
        EdgeType.evidenceFor,
      },
      // Incoming: evidenceFor (Source/Claim → Claim) — note both
      // outgoing AND incoming include evidenceFor, which permits the
      // self-loop test fixture.
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
      // Source receives derivedFrom (Claim --derivedFrom--> Source).
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
