// C.31 — RunRecorder + EffortMetrics unit tests.
//
// Drives `RunRecorder` against an in-memory stub of `TomBrainMemoryClient`
// + `StackApi` (the interface boundary, PE-10). The stub records every
// trail / persist / edge / stack call so the tests can assert the run
// recorder's full lifecycle:
//
//   - start  → trail opened, `invocation` entry, `running` marker
//              persisted, marker pushed to `inflight`.
//   - record → each primitive call / note appended to the trail in order.
//   - complete → final `ProcedureRun` persisted, `derived_from` +
//                `produced_by` edges drawn, marker removed from
//                `inflight`, final record pushed to `recent_runs`, trail
//                closed with the outcome.
//
// These are native Dart tests — no d4rt, no real memory. C.33 is the
// dedicated stub-memory integration step; C.31 proves the recorder's
// own behaviour here.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('C.31 EffortMetrics', () {
    test('defaults every field to zero', () {
      const m = EffortMetrics();
      expect(m.wallClockMs, 0);
      expect(m.llmCalls, 0);
      expect(m.inputTokens, 0);
      expect(m.outputTokens, 0);
      expect(m.toolCalls, 0);
      expect(m.memoryReads, 0);
      expect(m.memoryWrites, 0);
      expect(m, EffortMetrics.zero);
    });

    test('estimatedTokens is inputTokens + outputTokens', () {
      const m = EffortMetrics(inputTokens: 120, outputTokens: 80);
      expect(m.estimatedTokens, 200);
    });

    test('plus sums field-wise', () {
      const a = EffortMetrics(
        llmCalls: 1,
        inputTokens: 10,
        outputTokens: 5,
        memoryReads: 2,
      );
      const b = EffortMetrics(
        llmCalls: 2,
        inputTokens: 7,
        toolCalls: 3,
        memoryWrites: 4,
      );
      final sum = a.plus(b);
      expect(sum.llmCalls, 3);
      expect(sum.inputTokens, 17);
      expect(sum.outputTokens, 5);
      expect(sum.toolCalls, 3);
      expect(sum.memoryReads, 2);
      expect(sum.memoryWrites, 4);
    });

    test('withWallClockMs replaces only the wall clock', () {
      const m = EffortMetrics(llmCalls: 2, inputTokens: 9);
      final stamped = m.withWallClockMs(1234);
      expect(stamped.wallClockMs, 1234);
      expect(stamped.llmCalls, 2);
      expect(stamped.inputTokens, 9);
    });

    test('toJson carries the seven fields plus estimatedTokens', () {
      const m = EffortMetrics(
        wallClockMs: 50,
        llmCalls: 1,
        inputTokens: 30,
        outputTokens: 20,
        toolCalls: 2,
        memoryReads: 4,
        memoryWrites: 1,
      );
      expect(m.toJson(), <String, Object?>{
        'wallClockMs': 50,
        'llmCalls': 1,
        'inputTokens': 30,
        'outputTokens': 20,
        'toolCalls': 2,
        'memoryReads': 4,
        'memoryWrites': 1,
        'estimatedTokens': 50,
      });
    });

    test('value equality + hashCode', () {
      const a = EffortMetrics(llmCalls: 1, inputTokens: 2);
      const b = EffortMetrics(llmCalls: 1, inputTokens: 2);
      const c = EffortMetrics(llmCalls: 1, inputTokens: 3);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('rejects a negative field', () {
      expect(() => EffortMetrics(llmCalls: -1), throwsA(isA<AssertionError>()));
    });
  });

  group('C.31 RunRecorder', () {
    late _StubMemory memory;
    late _StubStacks stacks;
    late RunRecorder recorder;
    late DateTime clock;

    DateTime now() => clock;

    setUp(() {
      stacks = _StubStacks();
      memory = _StubMemory(stacks);
      clock = DateTime.utc(2026, 6, 1, 12, 0, 0);
      recorder = RunRecorder(memory, now: now);
    });

    RunStart startInfo({
      Map<String, Object?> arguments = const <String, Object?>{'text': 'hi'},
      NodeId? procedureNodeId,
      String? parentRunId,
    }) =>
        RunStart(
          procedureId: 'answer_with_memory_v1',
          version: 1,
          runId: 'r_abc',
          parentRunId: parentRunId,
          arguments: arguments,
          procedureNodeId: procedureNodeId,
        );

    group('start', () {
      test('opens a trail keyed to the run ref', () async {
        await recorder.start(startInfo());
        final ref = memory.openedRef!;
        expect(ref.procedureId, 'answer_with_memory_v1');
        expect(ref.runId, 'r_abc');
        expect(recorder.isOpen, isTrue);
        expect(recorder.trailId, memory.openTrailId);
      });

      test('writes an invocation entry first', () async {
        await recorder.start(
          startInfo(arguments: const <String, Object?>{'text': 'hello'}),
        );
        expect(recorder.entries, hasLength(1));
        final first = recorder.entries.first;
        expect(first.kind, TrailEntryKind.invocation);
        expect(first.payload['arguments'],
            const <String, Object?>{'text': 'hello'});
        // The invocation also reached memory.
        expect(memory.appended, hasLength(1));
        expect(memory.appended.first.kind, TrailEntryKind.invocation);
      });

      test('persists a running marker and pushes it to inflight', () async {
        await recorder.start(startInfo());
        // One persist so far: the marker.
        expect(memory.persisted, hasLength(1));
        final marker = memory.persisted.single;
        expect(marker.typeName, procedureRunNodeType);
        expect(marker.values['status'], 'running');
        expect(marker.values['runId'], 'r_abc');
        expect(marker.values['version'], 1);
        expect(marker.values['startedAt'], '2026-06-01T12:00:00.000Z');

        // The marker id is on the inflight stack.
        expect(stacks.pushes, hasLength(1));
        final push = stacks.pushes.single;
        expect(push.stackName, inflightStackName);
        expect(push.nodeId, recorder.inflightMarkerId);
        expect(push.scope!.producer, 'engine:answer_with_memory_v1:r_abc');
        expect(push.scope!.runId, 'r_abc');
      });

      test('rejects a second start', () async {
        await recorder.start(startInfo());
        expect(() => recorder.start(startInfo()), throwsStateError);
      });
    });

    group('recording before start', () {
      test('recordPrimitiveCall throws', () {
        expect(
          () => recorder.recordPrimitiveCall(
              'recall', const <String, Object?>{}, const <String, Object?>{}),
          throwsStateError,
        );
      });

      test('note throws', () {
        expect(
          () => recorder.note(
            TrailNote(category: 'x', recordedAt: clock),
          ),
          throwsStateError,
        );
      });

      test('complete throws', () {
        expect(
          () => recorder.complete(
            const RunCompletion(
                status: TrailOutcomeStatus.accepted, summary: 'x'),
          ),
          throwsStateError,
        );
      });
    });

    group('append', () {
      test('records primitive calls in order to trail + memory', () async {
        await recorder.start(startInfo());
        await recorder.recordPrimitiveCall(
          'recall',
          const <String, Object?>{'text': 'hi'},
          const <String, Object?>{'nodes': <Object?>[]},
          elapsedMs: 12,
        );
        await recorder.recordPrimitiveCall(
          'llm',
          const <String, Object?>{'prompt': 'p'},
          const <String, Object?>{'text': 'a'},
        );

        final calls = recorder.entries
            .where((e) => e.kind == TrailEntryKind.primitiveCall)
            .toList();
        expect(calls.map((e) => e.payload['primitive']),
            <String>['recall', 'llm']);
        expect(calls.first.payload['elapsedMs'], 12);
        // Memory saw invocation + two primitive calls, in order.
        expect(
          memory.appended.map((e) => e.kind),
          <TrailEntryKind>[
            TrailEntryKind.invocation,
            TrailEntryKind.primitiveCall,
            TrailEntryKind.primitiveCall,
          ],
        );
      });

      test('note sink appends a note entry carrying category + payload',
          () async {
        await recorder.start(startInfo());
        recorder.noteSink(
          TrailNote(
            category: automationCandidateCategory,
            payload: const <String, Object?>{'shape': 'repeat'},
            recordedAt: clock,
          ),
        );
        final note = recorder.entries.last;
        expect(note.kind, TrailEntryKind.note);
        expect(note.payload['category'], automationCandidateCategory);
        expect(note.payload['payload'],
            const <String, Object?>{'shape': 'repeat'});
        // Write-through reached memory synchronously.
        expect(memory.appended.last.kind, TrailEntryKind.note);
      });

      test('recordError appends an error entry', () async {
        await recorder.start(startInfo());
        await recorder.recordError('boom', 'it failed',
            details: const <String, Object?>{'where': 'recall'});
        final err = recorder.entries.last;
        expect(err.kind, TrailEntryKind.error);
        expect(err.payload['errorKind'], 'boom');
        expect(err.payload['message'], 'it failed');
      });
    });

    group('complete', () {
      test('persists the final run with effort + status + summary',
          () async {
        await recorder.start(startInfo());
        clock = clock.add(const Duration(milliseconds: 250));
        final record = await recorder.complete(
          const RunCompletion(
            status: TrailOutcomeStatus.accepted,
            summary: 'answered from memory',
            effort: EffortMetrics(
              llmCalls: 1,
              inputTokens: 100,
              outputTokens: 40,
              memoryReads: 1,
              memoryWrites: 2,
            ),
          ),
        );

        // Marker + final = two persists.
        expect(memory.persisted, hasLength(2));
        final finalNode = memory.persisted.last;
        expect(finalNode.typeName, procedureRunNodeType);
        expect(finalNode.values['status'], 'accepted');
        expect(finalNode.values['summary'], 'answered from memory');
        expect(finalNode.values['finishedAt'], '2026-06-01T12:00:00.250Z');
        final effort = finalNode.values['effort']! as Map<String, Object?>;
        expect(effort['llmCalls'], 1);
        expect(effort['estimatedTokens'], 140);
        // wall clock measured from the injected clock.
        expect(effort['wallClockMs'], 250);

        expect(record.status, TrailOutcomeStatus.accepted);
        expect(record.runNodeId, memory.persistedIds.last);
        expect(record.effort.wallClockMs, 250);
        expect(record.runId, 'r_abc');
        expect(recorder.isCompleted, isTrue);
        expect(recorder.isOpen, isFalse);
      });

      test('honours a caller-supplied wallClockMs', () async {
        await recorder.start(startInfo());
        clock = clock.add(const Duration(milliseconds: 250));
        final record = await recorder.complete(
          const RunCompletion(
            status: TrailOutcomeStatus.accepted,
            summary: 's',
            effort: EffortMetrics(wallClockMs: 999),
          ),
        );
        expect(record.effort.wallClockMs, 999);
      });

      test('moves the run from inflight to recent_runs', () async {
        await recorder.start(startInfo());
        final markerId = recorder.inflightMarkerId;
        final record = await recorder.complete(
          const RunCompletion(
              status: TrailOutcomeStatus.accepted, summary: 's'),
        );

        // inflight marker removed.
        expect(stacks.removes, hasLength(1));
        expect(stacks.removes.single.stackName, inflightStackName);
        expect(stacks.removes.single.nodeId, markerId);

        // final pushed to recent_runs (second push overall).
        expect(stacks.pushes, hasLength(2));
        final recentPush = stacks.pushes.last;
        expect(recentPush.stackName, recentRunsStackName);
        expect(recentPush.nodeId, record.runNodeId);
      });

      test('draws derived_from when the procedure is a memory node',
          () async {
        final procNode = NodeId.generate();
        await recorder.start(startInfo(procedureNodeId: procNode));
        final record = await recorder.complete(
          const RunCompletion(
              status: TrailOutcomeStatus.accepted, summary: 's'),
        );
        final derived = memory.edges
            .where((e) => e.type == EdgeType.derivedFrom)
            .toList();
        expect(derived, hasLength(1));
        expect(derived.single.from, record.runNodeId);
        expect(derived.single.to, procNode);
      });

      test('omits derived_from for a disk procedure (no node id)', () async {
        await recorder.start(startInfo());
        await recorder.complete(
          const RunCompletion(
              status: TrailOutcomeStatus.accepted, summary: 's'),
        );
        expect(
          memory.edges.where((e) => e.type == EdgeType.derivedFrom),
          isEmpty,
        );
      });

      test('draws produced_by from each result node to the run', () async {
        final r1 = NodeId.generate().value;
        final r2 = NodeId.generate().value;
        await recorder.start(startInfo());
        final record = await recorder.complete(
          RunCompletion(
            status: TrailOutcomeStatus.accepted,
            summary: 's',
            producedNodeIds: <String>[r1, r2],
          ),
        );
        final produced =
            memory.edges.where((e) => e.type == EdgeType.producedBy).toList();
        expect(produced, hasLength(2));
        expect(produced.map((e) => e.from.value), <String>[r1, r2]);
        expect(produced.every((e) => e.to == record.runNodeId), isTrue);
      });

      test('closes the trail with the outcome + effort details', () async {
        await recorder.start(startInfo());
        clock = clock.add(const Duration(milliseconds: 7));
        await recorder.complete(
          const RunCompletion(
            status: TrailOutcomeStatus.rejected,
            summary: 'critique rejected',
            effort: EffortMetrics(llmCalls: 2, inputTokens: 5, outputTokens: 5),
            producedNodeIds: <String>['n_00000000000000000000000001'],
          ),
        );
        expect(memory.closedTrailId, memory.openTrailId);
        final outcome = memory.closedOutcome!;
        expect(outcome.status, TrailOutcomeStatus.rejected);
        expect(outcome.summary, 'critique rejected');
        expect(outcome.elapsedMs, 7);
        expect((outcome.details['effort']! as Map)['estimatedTokens'], 10);
        expect(outcome.details['producedNodeIds'],
            <String>['n_00000000000000000000000001']);

        // The in-memory view ends with the outcome entry, but it is NOT
        // appended to memory (closeTrail synthesises it in storage).
        expect(recorder.entries.last.kind, TrailEntryKind.outcome);
        expect(
          memory.appended.where((e) => e.kind == TrailEntryKind.outcome),
          isEmpty,
        );
      });

      test('rejects a second complete', () async {
        await recorder.start(startInfo());
        await recorder.complete(
          const RunCompletion(
              status: TrailOutcomeStatus.accepted, summary: 's'),
        );
        expect(
          () => recorder.complete(
            const RunCompletion(
                status: TrailOutcomeStatus.accepted, summary: 's'),
          ),
          throwsStateError,
        );
      });
    });

    group('C.32 effort accumulation', () {
      test('accumulatedEffort starts at zero', () async {
        await recorder.start(startInfo());
        expect(recorder.accumulatedEffort, EffortMetrics.zero);
      });

      test('folds each recorded primitive call into the running total',
          () async {
        await recorder.start(startInfo());
        await recorder.recordPrimitiveCall(
          'recall',
          const <String, Object?>{'text': 'hi'},
          const <String, Object?>{'nodes': <Object?>[]},
        );
        await recorder.recordPrimitiveCall(
          'llm',
          const <String, Object?>{'prompt': 'p'},
          const <String, Object?>{
            'text': 'a',
            'report': <String, Object?>{'tokensIn': 90, 'tokensOut': 30},
          },
        );
        await recorder.recordPrimitiveCall(
          'persist',
          const <String, Object?>{'typeName': 'Conclusion'},
          const <String, Object?>{'id': 'n_1'},
        );
        await recorder.recordPrimitiveCall(
          'edge',
          const <String, Object?>{'type': 'produced_by'},
          const <String, Object?>{'id': 'e_1'},
        );
        await recorder.recordPrimitiveCall(
          'search',
          const <String, Object?>{'query': 'q'},
          const <String, Object?>{'hits': <Object?>[]},
        );

        final acc = recorder.accumulatedEffort;
        expect(acc.llmCalls, 1);
        expect(acc.inputTokens, 90);
        expect(acc.outputTokens, 30);
        expect(acc.estimatedTokens, 120);
        expect(acc.memoryReads, 1); // recall
        expect(acc.memoryWrites, 2); // persist + edge
        expect(acc.toolCalls, 1); // search
        // Per-call latency is never folded into the run wall clock.
        expect(acc.wallClockMs, 0);
      });

      test('complete persists the accumulated total (no caller effort)',
          () async {
        await recorder.start(startInfo());
        await recorder.recordPrimitiveCall(
          'llm',
          const <String, Object?>{},
          const <String, Object?>{
            'report': <String, Object?>{'tokensIn': 200, 'tokensOut': 50},
          },
        );
        await recorder.recordPrimitiveCall(
          'recall',
          const <String, Object?>{},
          const <String, Object?>{},
        );
        clock = clock.add(const Duration(milliseconds: 80));

        final record = await recorder.complete(
          const RunCompletion(
            status: TrailOutcomeStatus.accepted,
            summary: 'done',
          ),
        );

        final effort = memory.persisted.last.values['effort']!
            as Map<String, Object?>;
        expect(effort['llmCalls'], 1);
        expect(effort['inputTokens'], 200);
        expect(effort['outputTokens'], 50);
        expect(effort['estimatedTokens'], 250);
        expect(effort['memoryReads'], 1);
        // Wall clock comes from the measured elapsed, not the calls.
        expect(effort['wallClockMs'], 80);
        expect(record.effort.estimatedTokens, 250);
        expect(record.effort.wallClockMs, 80);
      });

      test('folds caller-supplied completion effort onto the accumulated '
          'counters', () async {
        await recorder.start(startInfo());
        await recorder.recordPrimitiveCall(
          'llm',
          const <String, Object?>{},
          const <String, Object?>{
            'report': <String, Object?>{'tokensIn': 10, 'tokensOut': 5},
          },
        );
        clock = clock.add(const Duration(milliseconds: 40));

        final record = await recorder.complete(
          const RunCompletion(
            status: TrailOutcomeStatus.accepted,
            summary: 'done',
            // The engine injects counters the recorder could not observe
            // (e.g. a nested-run rollup) plus an external wall clock.
            effort: EffortMetrics(
              llmCalls: 1,
              inputTokens: 4,
              outputTokens: 1,
              wallClockMs: 500,
            ),
          ),
        );

        expect(record.effort.llmCalls, 2); // 1 accumulated + 1 injected
        expect(record.effort.inputTokens, 14);
        expect(record.effort.outputTokens, 6);
        // A non-zero caller wall clock overrides the measured elapsed.
        expect(record.effort.wallClockMs, 500);
      });
    });

    test('full ordered trail: invocation → calls → note → outcome',
        () async {
      await recorder.start(startInfo());
      await recorder.recordPrimitiveCall('recall', const <String, Object?>{},
          const <String, Object?>{});
      recorder.note(TrailNote(category: 'progress', recordedAt: clock));
      await recorder.recordPrimitiveCall(
          'llm', const <String, Object?>{}, const <String, Object?>{});
      await recorder.complete(
        const RunCompletion(
            status: TrailOutcomeStatus.accepted, summary: 'done'),
      );
      expect(
        recorder.entries.map((e) => e.kind),
        <TrailEntryKind>[
          TrailEntryKind.invocation,
          TrailEntryKind.primitiveCall,
          TrailEntryKind.note,
          TrailEntryKind.primitiveCall,
          TrailEntryKind.outcome,
        ],
      );
    });
  });
}

// ── stubs ─────────────────────────────────────────────────────────

class _Push {
  _Push(this.stackName, this.nodeId, this.scope);
  final String stackName;
  final NodeId nodeId;
  final Scope? scope;
}

class _Remove {
  _Remove(this.stackName, this.nodeId);
  final String stackName;
  final NodeId nodeId;
}

class _Edge {
  _Edge(this.from, this.type, this.to);
  final NodeId from;
  final EdgeType type;
  final NodeId to;
}

/// Stub `TomBrainMemoryClient` capturing the trail / persist / edge calls
/// `RunRecorder` makes. Unused members fall through to `noSuchMethod`.
class _StubMemory implements TomBrainMemoryClient {
  _StubMemory(this._stacks);

  final _StubStacks _stacks;

  final TrailId openTrailId = TrailId.generate();
  ProcedureRunRef? openedRef;
  final List<TrailEntry> appended = <TrailEntry>[];
  TrailId? closedTrailId;
  TrailOutcome? closedOutcome;

  final List<NodeDraft> persisted = <NodeDraft>[];
  final List<NodeId> persistedIds = <NodeId>[];
  final List<_Edge> edges = <_Edge>[];

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    openedRef = run;
    return openTrailId;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    appended.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    closedTrailId = id;
    closedOutcome = outcome;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persisted.add(draft);
    final id = NodeId.generate();
    persistedIds.add(id);
    return id;
  }

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    edges.add(_Edge(from, type, to));
    return EdgeId.generate();
  }

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Stub `StackApi` capturing push / remove. Push returns a fresh
/// `StackEntryId`.
class _StubStacks implements StackApi {
  final List<_Push> pushes = <_Push>[];
  final List<_Remove> removes = <_Remove>[];

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    pushes.add(_Push(name, entry, scope));
    return StackEntryId.generate();
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    removes.add(_Remove(name, entry));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
