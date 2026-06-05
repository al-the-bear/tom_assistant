// P2.20 — cognitive-agent infrastructure, end-to-end through the
// concrete store.
//
// prototype_implementation_plan_2.md #20:
//   "Memory cognitive-agent infrastructure. Finalize the agent-support
//    layer the agents need: per-agent `AgentRegistry` scopes/write-guards,
//    idempotent writes, cursor-based `stream`, write-budget enforcement,
//    and `ShakingEvent` emission. Test: scope-violation rejection,
//    idempotent re-write is a no-op, cursor resumes, budget exhaustion
//    stops writes, shaking event emitted on contradiction. Verify: an
//    out-of-scope write is refused with `AgentScopeViolation`."
//
// The focused phase-A suites (a67 idempotency, a68 budget, a69 shaking,
// a70 scope, qa87_11 cursor durability) already lock each mechanism at
// the *component* level (NodePersister / EdgeWriter / cursor-store in
// isolation). What this file proves is that all five are live through
// the public `SqliteTomBrainMemory` surface — the seam the procedure
// engine and the cognitive agents actually call. The one piece that was
// not yet wired into the concrete store is the per-agent `AgentRegistry`
// (#20 finalises it): `registerAgent` installs a registration whose
// `writeScopes` the persister / edge-writer / stack-api enforce on every
// agent-attributed write.
//
// Like p2_15 – p2_19 these cases open the real on-disk store, which
// refuses to boot without the packaged vec0 binary (P1.1), so the group
// is skipped — not failed — when no binary is present for the platform.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        AgentRegistration,
        BrainTime,
        EdgeType,
        MemoryEvent,
        MutableTestClock,
        NodeDraft,
        NodeId,
        Scope,
        StreamCursor,
        StreamQuery,
        SymbolicFilter,
        Vec,
        WriteBudget;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 – p2_19 `_v768`. The
/// agent-infrastructure properties under test (scope, budget, idempotency,
/// cursor, shaking) are independent of the embedding *values*, so a
/// deterministic vector is sufficient — the real-embedding path is p2_19.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_19.
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

/// Builds an Event [NodeDraft] (requires an embedding).
NodeDraft _eventDraft({required String text, required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// Builds a Claim [NodeDraft] (field `statement`; requires an embedding).
/// Claim allows `contradicts` both ways, so two Claims drive the
/// contradiction shaking-event case.
NodeDraft _claimDraft({required String statement, required int seed}) =>
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'statement': statement},
      embedding: _v768(seed: seed),
    );

/// A budget that permits everything — used when a test exercises a
/// non-budget mechanism but still registers an agent.
WriteBudget _unboundedBudget() =>
    WriteBudget(maxNodes: 1000, maxEdges: 1000, maxStackEntries: 1000);

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

  /// A fresh real-store config rooted in a unique temp dir, with
  /// teardown registered for the directory.
  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_20_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  group('SqliteTomBrainMemory — cognitive-agent infrastructure (needs vec0)',
      () {
    test('out-of-scope agent write is refused with AgentScopeViolation; '
        'in-scope write succeeds', () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      // An agent permitted to write Claims but nothing else.
      store.registerAgent(AgentRegistration(
        agentName: 'claims_only',
        procedureId: 'dream_extract_v1',
        defaultBudget: _unboundedBudget(),
        readScopes: const <String>{AgentRegistration.globalWildcard},
        writeScopes: <String>{AgentRegistration.nodeScope('Claim')},
      ));

      // In-scope: a Claim is allowed.
      final claimId = await store.persist(
        _claimDraft(statement: 'within scope', seed: 1),
        scope: const Scope(
          producer: 'p2.20:test',
          agentName: 'claims_only',
          idempotencyKey: 'claim-1',
        ),
      );
      expect(claimId, isA<NodeId>());

      // Out-of-scope: an Event is refused — the Verify clause for #20.
      await expectLater(
        () => store.persist(
          _eventDraft(text: 'outside scope', seed: 2),
          scope: const Scope(
            producer: 'p2.20:test',
            agentName: 'claims_only',
            idempotencyKey: 'event-1',
          ),
        ),
        throwsA(isA<AgentScopeViolation>()),
      );

      // The refused write left nothing behind: the Event was never
      // persisted, so no Event row is readable.
      final stats = await store.stats();
      expect(stats.nodeCountByType['Event'] ?? 0, equals(0),
          reason: 'a scope-denied write must not create a row');
    });

    test('an unregistered agent name is refused with AgentScopeViolation',
        () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      // No registerAgent call — the name resolves to nothing.
      await expectLater(
        () => store.persist(
          _claimDraft(statement: 'who am I', seed: 3),
          scope: const Scope(
            producer: 'p2.20:test',
            agentName: 'ghost',
            idempotencyKey: 'ghost-1',
          ),
        ),
        throwsA(isA<AgentScopeViolation>()),
      );
    });

    test('a non-agent write (no agentName) bypasses scope enforcement',
        () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      // No agent registered, no agentName on the scope: the bootstrap /
      // dispatcher write path is unguarded by construction.
      final id = await store.persist(
        _eventDraft(text: 'system write', seed: 4),
        scope: const Scope(producer: 'p2.20:test', idempotencyKey: 'sys-1'),
      );
      expect(id, isA<NodeId>());
    });

    test('idempotent re-persist returns the same NodeId and does not '
        're-charge the budget', () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      // maxNodes:1 — one real write exhausts it; an idempotent re-write
      // must NOT consume the (now-zero) remaining budget.
      await store.beginRun(
        runId: 'run-idem',
        budget: WriteBudget(maxNodes: 1, maxEdges: 0, maxStackEntries: 0),
      );

      const scope = Scope(
        producer: 'p2.20:test',
        runId: 'run-idem',
        idempotencyKey: 'same-key',
      );
      final first = await store.persist(_claimDraft(statement: 'x', seed: 5),
          scope: scope);
      final second = await store.persist(_claimDraft(statement: 'x', seed: 5),
          scope: scope);

      expect(second, equals(first),
          reason: 'a repeated idempotency key returns the original id');

      final remaining = await store.remainingBudget('run-idem');
      expect(remaining, isNotNull);
      expect(remaining!.maxNodes, equals(0),
          reason: 'the first write charged one unit; the idempotent re-write '
              'charged nothing (it would have driven the counter negative)');
    });

    test('cursor-based stream resumes from the durable checkpoint',
        () async {
      final clock =
          MutableTestClock(BrainTime.fromMs(DateTime.utc(2026, 6, 5, 12).millisecondsSinceEpoch));
      final store = SqliteTomBrainMemory(clock: clock);
      await store.open(freshConfig());
      addTearDown(store.close);

      // First cohort, all stamped at T0.
      for (var i = 0; i < 3; i++) {
        await store.persist(
          _eventDraft(text: 'first-$i', seed: 10 + i),
          scope: Scope(producer: 'p2.20:test', idempotencyKey: 'first-$i'),
        );
      }

      // Full walk under a named stream id — checkpoints after each batch.
      final firstWalk = await store
          .stream(const StreamQuery(
            filter: SymbolicFilter(typeNames: <String>{'Event'}),
            batchSize: 2,
            resumeFrom: StreamCursor(streamId: 'walk', payload: <String, Object?>{}),
          ))
          .toList();
      expect(firstWalk, hasLength(3));

      // Second cohort, stamped strictly later so they sort after the
      // checkpoint regardless of id ordering.
      clock.advance(const Duration(minutes: 1));
      final secondIds = <NodeId>{};
      for (var i = 0; i < 2; i++) {
        secondIds.add(await store.persist(
          _eventDraft(text: 'second-$i', seed: 20 + i),
          scope: Scope(producer: 'p2.20:test', idempotencyKey: 'second-$i'),
        ));
      }

      // Re-walk the same stream id with an empty in-query cursor: the
      // store prefers the durable checkpoint and resumes from it, so only
      // the newly-added cohort comes back.
      final secondWalk = await store
          .stream(const StreamQuery(
            filter: SymbolicFilter(typeNames: <String>{'Event'}),
            batchSize: 2,
            resumeFrom: StreamCursor(streamId: 'walk', payload: <String, Object?>{}),
          ))
          .toList();

      expect(secondWalk, hasLength(2),
          reason: 'resume yields only the rows written after the checkpoint');
      expect(secondWalk.map((n) => n.id).toSet(), equals(secondIds),
          reason: 'exactly the second cohort, none of the already-walked rows');
    });

    test('budget exhaustion stops further writes with WriteBudgetExceeded',
        () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      await store.beginRun(
        runId: 'run-budget',
        budget: WriteBudget(maxNodes: 2, maxEdges: 0, maxStackEntries: 0),
      );

      Future<NodeId> write(String key, int seed) => store.persist(
            _claimDraft(statement: key, seed: seed),
            scope: Scope(
              producer: 'p2.20:test',
              runId: 'run-budget',
              idempotencyKey: key,
            ),
          );

      await write('b1', 30); // 1st of 2 — ok
      await write('b2', 31); // 2nd of 2 — ok

      await expectLater(
        () => write('b3', 32), // exhausted
        throwsA(isA<WriteBudgetExceeded>()),
      );
    });

    test('contradicts edge emits a ContradictionDetected shaking event',
        () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      final seen = <MemoryEvent>[];
      final sub = store.events().listen(seen.add);
      addTearDown(sub.cancel);

      final a = await store.persist(
        _claimDraft(statement: 'the sky is blue', seed: 40),
        scope: const Scope(producer: 'p2.20:test', idempotencyKey: 'claim-a'),
      );
      final b = await store.persist(
        _claimDraft(statement: 'the sky is green', seed: 41),
        scope: const Scope(producer: 'p2.20:test', idempotencyKey: 'claim-b'),
      );

      await store.edge(
        a,
        EdgeType.contradicts,
        b,
        scope: const Scope(producer: 'p2.20:test', idempotencyKey: 'contra-1'),
      );

      // Let the broadcast stream deliver the queued events.
      await Future<void>.delayed(Duration.zero);

      expect(seen.whereType<ContradictionDetected>(), hasLength(1),
          reason: 'a contradicts edge raises exactly one shaking event');
      final shaking = seen.whereType<ContradictionDetected>().single;
      expect(shaking.from, equals(a));
      expect(shaking.to, equals(b));
      expect(shaking.fromTypeName, equals('Claim'));
      expect(shaking.toTypeName, equals('Claim'));
    });
  }, skip: skipNoBinary);
}
