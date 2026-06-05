// P2.17 — the remaining client methods over the concrete store.
//
// prototype_implementation_plan_2.md #17:
//   "Memory: implement the remaining client methods. edge, StackApi
//    (list/create/push/peek/pop/update/remove), classify/updateCentroid/
//    findUncertain, registerNodeType/getNodeType, demote/forget,
//    stream(StreamQuery), events(), stats(). Test: one focused test per
//    method (contract conformance against TomBrainMemoryClient)."
//
// open() now assembles the edge writer/reader, the classification trio
// (CentroidStore + Classifier + UncertainFinder), the node-lifecycle
// manager, the stack API, the migration API, the stream-cursor store,
// the write-budget tracker, the event bus and the stats collector, then
// delegates each formerly-deferred override to its owner. These cases
// drive the REAL store across the full client surface.
//
// Like p2_16 these cases need the packaged vec0 binary (open() refuses
// to boot without it — P1.1) and are skipped, not failed, when the
// running platform has no binary under tom_binaries/sqlite_vec.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        ClassificationDecision,
        DemotionReason,
        EdgeDirection,
        EdgeType,
        ForgetReason,
        MemoryEvent,
        NodeDraft,
        NodeId,
        StreamQuery,
        SymbolicFilter,
        Vec,
        WriteBudget;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 `_v768`.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16.
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

  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_p2_17_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(
      root: root.path,
      binariesRoot: vecRoot!,
    ));
    return store;
  }

  /// Persists an Event carrying [text] / `_v768(seed:)`. Optional
  /// [runId] attaches a budget-charged scope.
  Future<NodeId> persistEvent(
    SqliteTomBrainMemory store, {
    required String text,
    required int seed,
    required String key,
    String? runId,
  }) {
    return store.persist(
      NodeDraft(
        typeName: 'Event',
        values: <String, Object?>{
          'summary': text,
          'payload': const <String, Object?>{},
          'occurred_at': '2026-06-05T10:00:00.000Z',
        },
        embedding: _v768(seed: seed),
      ),
      scope: Scope(
        producer: 'p2.17:test',
        idempotencyKey: key,
        runId: runId,
      ),
    );
  }

  group('SqliteTomBrainMemory — remaining methods (needs vec0)', () {
    test('edge + edgesOf round-trip a mentions edge between two Events',
        () async {
      final store = await openStore();
      final from = await persistEvent(store, text: 'from', seed: 1, key: 'a');
      final to = await persistEvent(store, text: 'to', seed: 2, key: 'b');

      final edgeId = await store.edge(
        from,
        EdgeType.mentions,
        to,
        scope: const Scope(producer: 'p2.17:test', idempotencyKey: 'e1'),
      );
      expect(edgeId, isNotNull);

      final outgoing = await store.edgesOf(from, direction: EdgeDirection.outgoing);
      expect(outgoing, hasLength(1));
      expect(outgoing.single.from, equals(from));
      expect(outgoing.single.to, equals(to));
      expect(outgoing.single.type, equals(EdgeType.mentions));
    });

    test('stacks push/peek/list operate on a bootstrap stack', () async {
      final store = await openStore();
      final node = await persistEvent(store, text: 'inflight', seed: 3, key: 'n');

      final entryId = await store.stacks.push(inflightStackName, node);
      expect(entryId, isNotNull);

      final peeked = await store.stacks.peek(inflightStackName);
      expect(peeked, hasLength(1));
      expect(peeked.single.nodeId, equals(node));

      final summaries = await store.stacks.list();
      final inflight =
          summaries.firstWhere((s) => s.name == inflightStackName);
      expect(inflight.size, equals(1));
    });

    test('classify + updateCentroid return a confident match for Event',
        () async {
      final store = await openStore();
      // Cold-start gate is 8 examples: persist 8 Events so the Event
      // centroid clears the gate once updated.
      for (var i = 0; i < 8; i++) {
        await persistEvent(store, text: 'ev$i', seed: 7, key: 'c$i');
      }
      await store.updateCentroid('Event', _v768(seed: 7));

      final result = await store.classify(_v768(seed: 7));
      expect(result.bestMatch, equals('Event'));
      expect(result.decision, equals(ClassificationDecision.confident));
    });

    test('findUncertain returns a NodeId list without throwing', () async {
      final store = await openStore();
      for (var i = 0; i < 8; i++) {
        await persistEvent(store, text: 'u$i', seed: 7, key: 'u$i');
      }
      await store.updateCentroid('Event', _v768(seed: 7));

      final uncertain = await store.findUncertain(
        forKey: 'Event',
        low: 0.0,
        high: 1.0,
      );
      expect(uncertain, isA<List<NodeId>>());
    });

    test('demote keeps the node addressable by id', () async {
      final store = await openStore();
      final id = await persistEvent(store, text: 'demote', seed: 4, key: 'd');

      await store.demote(id, DemotionReason.prunerDecision);

      // Demotion is reversible — the row stays queryable by id.
      final node = await store.get(id);
      expect(node, isNotNull);
      expect(node!.id, equals(id));
    });

    test('forget removes the node from the read path', () async {
      final store = await openStore();
      final id = await persistEvent(store, text: 'forget', seed: 5, key: 'f');

      await store.forget(id, ForgetReason.userRequested);

      final node = await store.get(id);
      expect(node, isNull);
    });

    test('stream yields the persisted Events matching the filter', () async {
      final store = await openStore();
      final ids = <NodeId>{};
      for (var i = 0; i < 3; i++) {
        ids.add(await persistEvent(store, text: 's$i', seed: 10 + i, key: 's$i'));
      }

      final streamed = <NodeId>{};
      await for (final node in store.stream(const StreamQuery(
        filter: SymbolicFilter(typeNames: <String>{'Event'}),
        batchSize: 2,
      ))) {
        streamed.add(node.id);
      }

      expect(streamed, containsAll(ids));
    });

    test('events() surfaces a MemoryEvent after a persist', () async {
      final store = await openStore();
      final received = <MemoryEvent>[];
      final sub = store.events().listen(received.add);
      addTearDown(sub.cancel);

      await persistEvent(store, text: 'evented', seed: 6, key: 'ev');
      // Let the event microtask drain.
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotEmpty);
    });

    test('stats() reports node, edge and stack counts', () async {
      final store = await openStore();
      final a = await persistEvent(store, text: 'a', seed: 1, key: 'a');
      final b = await persistEvent(store, text: 'b', seed: 2, key: 'b');
      await store.edge(a, EdgeType.mentions, b,
          scope: const Scope(producer: 'p2.17:test', idempotencyKey: 'e'));
      await store.stacks.push(inflightStackName, a);

      final stats = await store.stats();
      expect(stats.nodeCountByType['Event'], greaterThanOrEqualTo(2));
      expect(stats.edgeCountByType['mentions'], equals(1));
      expect(stats.stackSizes[inflightStackName], equals(1));
    });

    test('beginRun/remainingBudget/endRun track a run write budget',
        () async {
      final store = await openStore();
      const runId = 'run-1';
      await store.beginRun(
        runId: runId,
        budget: WriteBudget(maxNodes: 5, maxEdges: 5, maxStackEntries: 5),
      );

      final initial = await store.remainingBudget(runId);
      expect(initial?.maxNodes, equals(5));

      await persistEvent(store,
          text: 'charged', seed: 8, key: 'b1', runId: runId);
      final afterWrite = await store.remainingBudget(runId);
      expect(afterWrite?.maxNodes, equals(4));

      await store.endRun(runId);
      expect(await store.remainingBudget(runId), isNull);
    });

    test('migrations.start registers a migration visible in status',
        () async {
      final store = await openStore();
      const id = 'mig-1';
      await store.migrations.start(MigrationDecl(
        migrationId: id,
        summary: 're-centroid Event nodes',
        candidates: const StreamQuery(
          filter: SymbolicFilter(typeNames: <String>{'Event'}),
        ),
        perCycleBudget: 32,
      ));

      final status = await store.migrations.status(id);
      expect(status, isNotNull);
      expect(status!.migrationId, equals(id));

      final inProgress = await store.migrations.listInProgress();
      expect(inProgress.map((s) => s.migrationId), contains(id));
    });
  }, skip: skipNoBinary);
}
