// P2.15 — persist() and trails over the concrete store.
//
// prototype_implementation_plan_2.md #15:
//   "Memory: implement `persist()` and trails. `persist(NodeDraft,
//    {Scope})` over `NodePersister` (+ vector write with recorded
//    `EmbeddingModelIdentity` when an embedding is supplied);
//    `openTrail/appendTrail/closeTrail/readTrail` over
//    `sqlite_trail_store`. Test: persist a node, read it back; vector
//    row written with identity; trail JSONL round-trip. Verify:
//    persisted Event/Conclusion nodes are retrievable by id."
//
// open() now hoists NodePersister / NodeReader / SqliteTrailStore /
// TwoDbCoordinator to store fields and installs one vector index per
// distinct embedding model among the registered node types, so a
// persist that carries an embedding can write its vector. These
// positive cases need the packaged vec0 binary (open() refuses to boot
// without it — P1.1) and are skipped, not failed, when the running
// platform has no binary under tom_binaries/sqlite_vec/<platform>/,
// mirroring p2_13 / p2_14.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, ProcedureRunRef, TrailEntry, TrailEntryKind,
        TrailOutcome, TrailOutcomeStatus, Vec;

/// The bootstrap embedding model (bootstrap_node_types.yaml
/// `embedding_defaults`). Event / Conclusion both embed under it.
const _bootstrapModelId = 'nomic-embed-text@v1.5';
const _bootstrapDims = 768;

/// A deterministic 768-dim vector so the persisted node carries a real
/// embedding under the bootstrap model. Mirrors a39's `_v768`.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors p2_13 / p2_14.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('SqliteTomBrainMemory — persist + trails (needs vec0)', () {
    test(
      'persists Event/Conclusion with embeddings, reads them back, and '
      'records the vector row with the embedding-model identity',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_persist_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final store = SqliteTomBrainMemory();
        addTearDown(store.close);
        await store.open(MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        ));

        // Persist an Event (summary/payload/occurred_at + embedding).
        final eventId = await store.persist(
          NodeDraft(
            typeName: 'Event',
            values: <String, Object?>{
              'summary': 'the user asked about persistence',
              'payload': <String, Object?>{'channel': 'cli'},
              'occurred_at': '2026-06-05T10:00:00.000Z',
            },
            embedding: _v768(seed: 3),
          ),
          scope: const Scope(producer: 'p2.15:test', idempotencyKey: 'ev-1'),
        );

        // Persist a Conclusion (statement/rationale + embedding).
        final conclusionId = await store.persist(
          NodeDraft(
            typeName: 'Conclusion',
            values: <String, Object?>{
              'statement': 'persistence works',
              'rationale': 'the row round-trips',
            },
            embedding: _v768(seed: 7),
          ),
          scope: const Scope(producer: 'p2.15:test', idempotencyKey: 'co-1'),
        );

        // Verify: both nodes retrievable by id with their content.
        final event = await store.get(eventId);
        expect(event, isNotNull, reason: 'get(eventId)');
        expect(event!.typeName, equals('Event'));
        expect(event.values['summary'],
            equals('the user asked about persistence'));

        final conclusion = await store.get(conclusionId);
        expect(conclusion, isNotNull, reason: 'get(conclusionId)');
        expect(conclusion!.typeName, equals('Conclusion'));
        expect(conclusion.values['statement'], equals('persistence works'));

        // getMany returns both in input order.
        final many = await store.getMany(<NodeId>[conclusionId, eventId]);
        expect(many.map((n) => n.id).toList(),
            equals(<NodeId>[conclusionId, eventId]));

        // Each persisted node row records the embedding-model identity.
        final memoryDb = store.debugMemoryDatabase;
        final modelIds = memoryDb
            .select(
              'SELECT embedding_model_id FROM nodes WHERE id IN (?, ?)',
              <Object?>[eventId.toString(), conclusionId.toString()],
            )
            .map((r) => r['embedding_model_id'] as String?)
            .toSet();
        expect(modelIds, equals(<String?>{_bootstrapModelId}));

        // The vector index for the bootstrap model is installed and the
        // per-model vec table carries a row for each persisted node.
        final vectorsDb = store.debugVectorsDatabase;
        final indexRows = vectorsDb.select(
          'SELECT table_name, dims FROM vector_indexes WHERE model_id = ?',
          <Object?>[_bootstrapModelId],
        );
        expect(indexRows, hasLength(1),
            reason: 'one index installed for the bootstrap model');
        expect(indexRows.first['dims'], equals(_bootstrapDims));

        final tableName = indexRows.first['table_name'] as String;
        final vecCount = vectorsDb
            .select('SELECT COUNT(*) AS n FROM "$tableName"')
            .first['n'] as int;
        expect(vecCount, equals(2),
            reason: 'a vector row was written for each persisted node');
      },
      skip: skipNoBinary,
    );

    test(
      'trail JSONL round-trips: openTrail → appendTrail → closeTrail → '
      'readTrail returns the appended entry plus the synthesised outcome',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_trail_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final store = SqliteTomBrainMemory();
        addTearDown(store.close);
        await store.open(MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        ));

        final trailId = await store.openTrail(const ProcedureRunRef(
          procedureId: 'p_answer_with_memory_v1',
          runId: 'run-p2-15',
        ));

        await store.appendTrail(
          trailId,
          TrailEntry.note('first observation', at: DateTime.utc(2026, 6, 5)),
        );

        await store.closeTrail(
          trailId,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'done',
          ),
        );

        final entries = await store.readTrail(trailId).toList();
        expect(entries.map((e) => e.kind).toList(),
            equals(<TrailEntryKind>[TrailEntryKind.note,
                TrailEntryKind.outcome]));
        expect(entries.first.payload['message'], equals('first observation'));
        expect(entries.last.payload['status'], equals('accepted'));

        // The trails index row landed after the first durable append.
        final trailRows = store.debugMemoryDatabase
            .select('SELECT status FROM trails WHERE id = ?',
                <Object?>[trailId.toString()]);
        expect(trailRows, hasLength(1));
        expect(trailRows.first['status'], equals('closed'));
      },
      skip: skipNoBinary,
    );
  });
}
