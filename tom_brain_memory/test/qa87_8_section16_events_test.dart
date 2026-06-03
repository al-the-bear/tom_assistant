// Q-A.87.8 — the five remaining spec § 16 `MemoryEvent` leaves.
//
// Todo #13 wires the five typed events spec § 16 promises on the single
// observability stream but that had no emission path yet:
//
//   1. `RecallCompleted`        — `RecallExecutor.recall` tail
//   2. `ClassificationComputed` — `Classifier.classify` (every call)
//   3. `CentroidUpdated`        — `CentroidStore.update` (every upsert)
//   4. `MigrationProgressed`    — `JsonFileMigrationApi.saveCursor`
//   5. `AuthorityUnreachable`   — DECLARE-ONLY (producer is build
//      step 9, the multi-machine heartbeat monitor). No emission path
//      exists yet, so this leaf is exercised by construction +
//      `toJson()` shape only, exactly as `StackOverflowDemoted` was
//      before its producer landed.
//
// Each emission test captures onto a list-backed `eventSink` — the
// same fake the cognitive-agent/shaking tests use — and asserts:
//
//   * exactly the expected number of events fired,
//   * the `kind` discriminator,
//   * the payload fields,
//   * `occurredAt` is the injected clock's time (UTC),
//   * `runId` / `causedBy` thread through from the optional `Scope`.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock, NodeId, Vec;

void main() {
  // ─────────────────────────────────────────────────────────────────
  // 1. RecallCompleted — RecallExecutor.recall
  // ─────────────────────────────────────────────────────────────────

  group('Q-A.87.8 RecallCompleted (RecallExecutor)', () {
    late List<MemoryEvent> events;
    late MutableTestClock clock;

    setUp(() {
      events = <MemoryEvent>[];
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
    });

    NodeBulkReader emptyReader() => (ids) async => const <Node>[];

    Bm25ModeFn oneBm25(NodeId id) => ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            <Bm25RecallCandidate>[
              Bm25RecallCandidate(
                nodeId: id,
                typeName: 'Concept',
                bm25Score: -1.0,
              ),
            ];

    RecallExecutor newExecutor({
      Bm25ModeFn? bm25,
      required NodeBulkReader nodeReader,
    }) =>
        RecallExecutor.fromCallables(
          bm25: bm25 ??
              ({
                required String text,
                Set<String>? typeNames,
                int perModeK = 64,
              }) =>
                  const <Bm25RecallCandidate>[],
          vector: ({
            required Vec query,
            Set<String>? typeNames,
            int perModeK = 64,
          }) =>
              const <VectorRecallCandidate>[],
          symbolic: ({
            required SymbolicFilter filter,
            int perModeK = 64,
          }) =>
              const <SymbolicRecallCandidate>[],
          graphWalk: ({
            required Set<NodeId> seeds,
            GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
            Set<String>? typeNames,
            int perModeK = 64,
          }) =>
              const <GraphWalkRecallCandidate>[],
          nodeReader: nodeReader,
          clock: clock,
          eventSink: events.add,
        );

    test('emits exactly one RecallCompleted per recall, even for empty '
        'modes', () async {
      final exec = newExecutor(nodeReader: emptyReader());

      await exec.recall(RecallQuery(modes: const {}, k: 5));

      final completed = events.whereType<RecallCompleted>().toList();
      expect(completed, hasLength(1));
      expect(completed.single.kind, equals('memory.recall-completed'));
      expect(completed.single.requestedModes, isEmpty);
      expect(completed.single.returnedCount, equals(0));
      expect(completed.single.occurredAt, equals(clock.now()));
      expect(completed.single.occurredAt.isUtc, isTrue);
    });

    test('carries the requested modes, returned count, and the report '
        'by reference', () async {
      final id = NodeId.generate(
        at: DateTime.utc(2026, 1, 1),
        randomness: List<int>.generate(16, (i) => i & 0x1F),
      );
      final node = Node(
        id: id,
        typeName: 'Concept',
        values: const <String, Object?>{},
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final exec = newExecutor(
        bm25: oneBm25(id),
        nodeReader: (ids) async => <Node>[node],
      );

      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.bm25}, text: 'x', k: 5),
      );

      final completed = events.whereType<RecallCompleted>().single;
      expect(completed.requestedModes, equals(<RecallMode>[RecallMode.bm25]));
      expect(completed.returnedCount, equals(result.nodes.length));
      // The event holds the same report the call returned to the caller.
      expect(identical(completed.report, result.report), isTrue);
    });

    test('threads runId / causedBy from the optional Scope', () async {
      final exec = newExecutor(nodeReader: emptyReader());

      await exec.recall(
        RecallQuery(modes: const {RecallMode.bm25}, text: 'x', k: 5),
        scope: const Scope(
          producer: 'test',
          runId: 'r_recall',
          causedBy: 'ev_parent',
        ),
      );

      final completed = events.whereType<RecallCompleted>().single;
      expect(completed.runId, equals('r_recall'));
      expect(completed.causedBy, equals('ev_parent'));
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 2. ClassificationComputed — Classifier.classify
  // ─────────────────────────────────────────────────────────────────

  group('Q-A.87.8 ClassificationComputed (Classifier)', () {
    late Database db;
    late MutableTestClock clock;
    late CentroidStore store;
    late List<MemoryEvent> events;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      store = CentroidStore(memoryDb: db, clock: clock);
      events = <MemoryEvent>[];
    });

    tearDown(() => db.dispose());

    void seedNodeType(String typeName, Vec centroid, {int examples = 16}) {
      store.update(
        forKey: CentroidStore.keyForNodeType(typeName),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: centroid,
        exampleCount: examples,
      );
    }

    test('emits one ClassificationComputed with null bestMatch on cold '
        'start', () {
      final c = Classifier(store: store, eventSink: events.add, clock: clock);

      c.classify(Vec.fromList(const <double>[1, 0, 0]));

      final computed =
          events.whereType<ClassificationComputed>().toList();
      expect(computed, hasLength(1));
      expect(computed.single.kind, equals('memory.classification-computed'));
      expect(computed.single.decision,
          equals(ClassificationDecision.unknown));
      expect(computed.single.bestMatch, isNull);
      expect(computed.single.bestSimilarity, equals(0.0));
      expect(computed.single.secondSimilarity, equals(0.0));
      expect(computed.single.target,
          equals(ClassificationTarget.nodeType));
      expect(computed.single.occurredAt, equals(clock.now()));
    });

    test('emits a confident ClassificationComputed carrying the bare '
        'winning key and both similarities', () {
      seedNodeType('Question', Vec.fromList(const <double>[1, 0, 0]));
      seedNodeType('Concept', Vec.fromList(const <double>[0, 1, 0]));
      final c = Classifier(store: store, eventSink: events.add, clock: clock);

      final result = c.classify(Vec.fromList(const <double>[1, 0, 0]));

      final computed = events.whereType<ClassificationComputed>().single;
      expect(result.decision, equals(ClassificationDecision.confident));
      expect(computed.decision, equals(result.decision));
      expect(computed.bestMatch, equals('Question'));
      expect(computed.bestSimilarity, equals(result.bestSimilarity));
      expect(computed.secondSimilarity, equals(result.secondSimilarity));
    });

    test('payload omits bestMatch when null and includes it otherwise', () {
      seedNodeType('Question', Vec.fromList(const <double>[1, 0, 0]));
      final c = Classifier(store: store, eventSink: events.add, clock: clock);

      c.classify(Vec.fromList(const <double>[1, 0, 0])); // confident → key
      final coldClassifier =
          Classifier(store: store, eventSink: events.add, clock: clock);
      // Re-run against an empty namespace (procedure) → unknown, no key.
      coldClassifier.classify(
        Vec.fromList(const <double>[1, 0, 0]),
        target: ClassificationTarget.procedure,
      );

      final withKey = events.whereType<ClassificationComputed>().first;
      final withoutKey = events.whereType<ClassificationComputed>().last;
      expect(withKey.payloadJson().containsKey('bestMatch'), isTrue);
      expect(withoutKey.payloadJson().containsKey('bestMatch'), isFalse);
    });

    test('threads runId / causedBy from the optional Scope', () {
      final c = Classifier(store: store, eventSink: events.add, clock: clock);

      c.classify(
        Vec.fromList(const <double>[1, 0, 0]),
        scope: const Scope(
          producer: 'test',
          runId: 'r_classify',
          causedBy: 'ev_parent',
        ),
      );

      final computed = events.whereType<ClassificationComputed>().single;
      expect(computed.runId, equals('r_classify'));
      expect(computed.causedBy, equals('ev_parent'));
    });

    test('no sink → no emission, classification still returns', () {
      seedNodeType('Question', Vec.fromList(const <double>[1, 0, 0]));
      final c = Classifier(store: store); // no eventSink

      final result = c.classify(Vec.fromList(const <double>[1, 0, 0]));

      expect(result.decision, equals(ClassificationDecision.confident));
      expect(events, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 3. CentroidUpdated — CentroidStore.update
  // ─────────────────────────────────────────────────────────────────

  group('Q-A.87.8 CentroidUpdated (CentroidStore)', () {
    late Database db;
    late MutableTestClock clock;
    late List<MemoryEvent> events;
    late CentroidStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      events = <MemoryEvent>[];
      store = CentroidStore(memoryDb: db, clock: clock, eventSink: events.add);
    });

    tearDown(() => db.dispose());

    test('first upsert emits CentroidUpdated with created=true and the '
        'row identity', () {
      store.update(
        forKey: CentroidStore.keyForNodeType('Question'),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: Vec.fromList(const <double>[1, 0, 0]),
        exampleCount: 12,
      );

      final updated = events.whereType<CentroidUpdated>().toList();
      expect(updated, hasLength(1));
      expect(updated.single.kind, equals('memory.centroid-updated'));
      expect(updated.single.forKey, equals('NodeType:Question'));
      expect(updated.single.embeddingModelId,
          equals('ollama/nomic-embed-text@1.5'));
      expect(updated.single.exampleCount, equals(12));
      expect(updated.single.dimensions, equals(3));
      expect(updated.single.created, isTrue);
    });

    test('second upsert on the same key emits created=false', () {
      final key = CentroidStore.keyForNodeType('Question');
      store.update(
        forKey: key,
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: Vec.fromList(const <double>[1, 0, 0]),
        exampleCount: 12,
      );
      store.update(
        forKey: key,
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: Vec.fromList(const <double>[0, 1, 0]),
        exampleCount: 20,
      );

      final updated = events.whereType<CentroidUpdated>().toList();
      expect(updated, hasLength(2));
      expect(updated.first.created, isTrue);
      expect(updated.last.created, isFalse);
      expect(updated.last.exampleCount, equals(20));
    });

    test('threads runId / causedBy from the optional Scope', () {
      store.update(
        forKey: CentroidStore.keyForNodeType('Question'),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: Vec.fromList(const <double>[1, 0, 0]),
        exampleCount: 12,
        scope: const Scope(
          producer: 'dream_recentroid_v1',
          runId: 'r_centroid',
          causedBy: 'ev_parent',
        ),
      );

      final updated = events.whereType<CentroidUpdated>().single;
      expect(updated.runId, equals('r_centroid'));
      expect(updated.causedBy, equals('ev_parent'));
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 4. MigrationProgressed — JsonFileMigrationApi.saveCursor
  // ─────────────────────────────────────────────────────────────────

  group('Q-A.87.8 MigrationProgressed (JsonFileMigrationApi)', () {
    late List<MemoryEvent> events;

    MemoryDirectory openDir() {
      final parent = Directory.systemTemp.createTempSync('qa87_8_migration');
      addTearDown(() {
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });
      final root = '${parent.path}${Platform.pathSeparator}brain';
      return MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
    }

    setUp(() {
      events = <MemoryEvent>[];
    });

    test('emits one MigrationProgressed per saveCursor with the '
        'post-write snapshot', () async {
      final api = JsonFileMigrationApi(
        directory: openDir(),
        eventSink: events.add,
      );
      await api.start(MigrationDecl(
        migrationId: 'restructure_question_2026_v1',
        summary: 'Reclassify Question nodes',
        candidates: const StreamQuery(filter: SymbolicFilter()),
        perCycleBudget: 200,
      ));

      await api.saveCursor('restructure_question_2026_v1', <String, Object?>{
        'processed': 140,
        'total': 1000,
        'complete': false,
      });

      final progressed = events.whereType<MigrationProgressed>().toList();
      expect(progressed, hasLength(1));
      expect(progressed.single.kind, equals('memory.migration-progressed'));
      expect(progressed.single.migrationId,
          equals('restructure_question_2026_v1'));
      expect(progressed.single.processed, equals(140));
      expect(progressed.single.total, equals(1000));
      expect(progressed.single.complete, isFalse);
      expect(progressed.single.progress, closeTo(0.14, 1e-9));
      // A cursor advance is the run-free progress case (see leaf doc).
      expect(progressed.single.runId, isNull);
    });

    test('the terminal cursor carries complete=true', () async {
      final api = JsonFileMigrationApi(
        directory: openDir(),
        eventSink: events.add,
      );
      await api.start(MigrationDecl(
        migrationId: 'restructure_question_2026_v1',
        summary: 'Reclassify Question nodes',
        candidates: const StreamQuery(filter: SymbolicFilter()),
        perCycleBudget: 200,
      ));

      await api.saveCursor('restructure_question_2026_v1', <String, Object?>{
        'processed': 1000,
        'total': 1000,
        'complete': true,
      });

      final progressed = events.whereType<MigrationProgressed>().single;
      expect(progressed.complete, isTrue);
      expect(progressed.progress, closeTo(1.0, 1e-9));
    });

    test('saveCursor on an unregistered id throws and emits nothing',
        () async {
      final api = JsonFileMigrationApi(
        directory: openDir(),
        eventSink: events.add,
      );

      await expectLater(
        api.saveCursor('restructure_missing_v1', const <String, Object?>{}),
        throwsStateError,
      );
      expect(events.whereType<MigrationProgressed>(), isEmpty);
    });

    test('start does not emit MigrationProgressed', () async {
      final api = JsonFileMigrationApi(
        directory: openDir(),
        eventSink: events.add,
      );

      await api.start(MigrationDecl(
        migrationId: 'restructure_question_2026_v1',
        summary: 'Reclassify Question nodes',
        candidates: const StreamQuery(filter: SymbolicFilter()),
        perCycleBudget: 200,
      ));

      expect(events.whereType<MigrationProgressed>(), isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 5. AuthorityUnreachable — declare-only (producer is build step 9)
  // ─────────────────────────────────────────────────────────────────

  group('Q-A.87.8 AuthorityUnreachable (declare-only leaf)', () {
    test('constructs and exposes its discriminator + payload', () {
      final event = AuthorityUnreachable(
        authorityId: 'big-beast',
        localRole: 'cognitive-worker',
        overdueMs: 4500,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );

      expect(event.kind, equals('memory.authority-unreachable'));
      expect(event.authorityId, equals('big-beast'));
      expect(event.localRole, equals('cognitive-worker'));
      expect(event.overdueMs, equals(4500));
      expect(
        event.payloadJson(),
        equals(<String, Object?>{
          'authorityId': 'big-beast',
          'localRole': 'cognitive-worker',
          'overdueMs': 4500,
        }),
      );
    });

    test('toJson composes the base envelope and is UTC-checked', () {
      final event = AuthorityUnreachable(
        authorityId: 'big-beast',
        localRole: 'mirror',
        overdueMs: 9000,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        runId: 'r_heartbeat',
        causedBy: 'ev_loss',
      );

      final json = event.toJson();
      expect(json['kind'], equals('memory.authority-unreachable'));
      expect(json['runId'], equals('r_heartbeat'));
      expect(json['causedBy'], equals('ev_loss'));
      expect(json['payload'], equals(event.payloadJson()));
    });

    test('is a MemoryEvent so it matches the typed observability '
        'stream element', () {
      final event = AuthorityUnreachable(
        authorityId: 'big-beast',
        localRole: 'mirror',
        overdueMs: 1,
        occurredAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );
      expect(event, isA<MemoryEvent>());
    });
  });
}
