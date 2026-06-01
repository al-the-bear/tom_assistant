// C.37 — cooperative-preemption subphase (C.9) integration tests.
//
// C.34–C.36 each pinned their own object in isolation:
//   - `preemption_state_test.dart`  → the shared `PreemptionState`.
//   - `yield_primitive_test.dart`   → `YieldPrimitive` against that state.
//   - `step_deadline_test.dart`     → `StepDeadline` racing a step.
//
// C.37 is the subphase's *integration* step, pinning the three things the
// plan names together (`prototype_implementation_plan.md` § C.9, C.37):
//
//   1. a foreground signal triggers a yield — a background loop that calls
//      `yield_if_foreground_waiting()` between steps parks at its *next*
//      checkpoint when a foreground arrives mid-step, never mid-step;
//   2. resume after the foreground completes — the parked background loop
//      continues from where it parked once the coordinator signals resume,
//      and the checkpoint is reusable for the rest of the loop;
//   3. deadline expiry produces a truncated-step trail entry — a step that
//      runs past its `StepDeadline` is force-yielded, and the integrated
//      path (which C.36 deferred to here) maps that `StepTruncated` onto a
//      `step_truncated` trail note plus a `preempted` run outcome on the
//      `RunRecorder`'s trail.
//
// The deadline→trail mapping is exercised here through a small test-local
// step-runner (`_DeadlineStepRunner`). It is deliberately *not* production
// code: wiring `StepDeadline.guard` into real `runProcedure` step execution
// — and owning the `StepTruncated → RunCompletion(preempted) + note` mapping
// — is the engine step-runner's job at C.38. C.37 proves the integrated
// behaviour the engine will rely on; C.38 supplies the engine wiring.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('C.37 foreground signal triggers yield, then resume', () {
    test('a background loop parks at its next checkpoint and resumes', () async {
      // A background "procedure" that runs five steps, calling the
      // cooperative checkpoint between every one — exactly how a background
      // loop yields to a waiting foreground (spec § 9, PE-5).
      final state = PreemptionState();
      final checkpoint = YieldPrimitive(state: state);
      final stepsRun = <int>[];

      Future<void> background() async {
        for (var step = 1; step <= 5; step++) {
          stepsRun.add(step);
          await checkpoint.yieldIfForegroundWaiting();
        }
      }

      // A foreground arrives while the background still has steps to run, so
      // the very next checkpoint must park. (The background runs its first
      // step synchronously, then hits the checkpoint with the foreground
      // waiting.)
      state.requestForegroundPreemption();
      final loop = background();

      // The loop parks at the checkpoint after step 1: it must not run the
      // remaining steps while the foreground is waiting.
      await pumpEventQueue();
      expect(
        stepsRun,
        <int>[1],
        reason: 'the background yields at the first checkpoint and parks',
      );
      expect(state.isForegroundWaiting, isTrue);

      // Resume after the foreground completes: the loop continues from where
      // it parked and finishes the remaining steps, the checkpoint now idle.
      state.signalResume();
      await loop;
      expect(stepsRun, <int>[1, 2, 3, 4, 5]);
      expect(state.isForegroundWaiting, isFalse);
    });

    test('a checkpoint reached before resume completes when resume fires',
        () async {
      // The foreground is already waiting when the background reaches the
      // checkpoint: it parks, and only the resume signal releases it.
      final state = PreemptionState()..requestForegroundPreemption();
      final checkpoint = YieldPrimitive(state: state);

      var resumed = false;
      final parked = checkpoint.yieldIfForegroundWaiting().then((_) {
        resumed = true;
      });

      await pumpEventQueue();
      expect(resumed, isFalse, reason: 'parked while the foreground waits');

      state.signalResume();
      await parked;
      expect(resumed, isTrue);
    });
  });

  group('C.37 deadline expiry produces a truncated-step trail entry', () {
    late _StatefulMemory memory;
    late RunRecorder recorder;
    late DateTime clock;
    late _FakeTimer scheduled;

    DateTime now() => clock;

    StepDeadline newDeadline({Duration limit = const Duration(seconds: 60)}) =>
        StepDeadline(
          limit: limit,
          timerFactory: (duration, onExpire) =>
              scheduled = _FakeTimer(duration, onExpire),
        );

    setUp(() async {
      memory = _StatefulMemory();
      clock = DateTime.utc(2026, 6, 1, 12, 0, 0);
      recorder = RunRecorder(memory, now: now);
      await recorder.start(
        const RunStart(
          procedureId: 'long_running_v1',
          version: 1,
          runId: 'r_c37_1',
          arguments: <String, Object?>{'goal': 'something slow'},
        ),
      );
    });

    test('a step that overruns is recorded as a truncated step + preempted run',
        () async {
      final deadline = newDeadline(limit: const Duration(seconds: 30));
      final runner = _DeadlineStepRunner(recorder: recorder, clock: now);

      // A step that never finishes within the test; the deadline fires.
      final never = Completer<void>();
      final guarded = runner.runStep(deadline, never.future);
      scheduled.fire();
      final outcome = await guarded;

      expect(outcome, isA<StepTruncated<void>>());

      // The step-runner wrote a `step_truncated` note carrying the breached
      // limit, then closed the run as `preempted`.
      final record = await runner.closeAsTruncated(outcome);
      expect(record.status, TrailOutcomeStatus.preempted);

      final entries = await memory.readTrail(record.trailId).toList();

      // A `step_truncated` note appears on the trail.
      final notes = entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == stepTruncatedNoteCategory)
          .toList();
      expect(notes, hasLength(1), reason: 'exactly one truncated-step note');
      final notePayload = notes.single.payload['payload']! as Map;
      expect(notePayload['limitMs'], 30 * 1000);

      // The trail closes on a `preempted` outcome.
      final closing = entries.last;
      expect(closing.kind, TrailEntryKind.outcome);
      expect(closing.payload['status'], 'preempted');
    });

    test('a step that finishes within the deadline is not truncated', () async {
      final deadline = newDeadline();
      final runner = _DeadlineStepRunner(recorder: recorder, clock: now);

      final outcome = await runner.runStep(deadline, Future<void>.value());
      expect(outcome, isA<StepCompleted<void>>());

      // The cooperative path: the run closes normally, with no truncated-step
      // note on its trail.
      final record = await recorder.complete(
        const RunCompletion(
          status: TrailOutcomeStatus.accepted,
          summary: 'finished in time',
        ),
      );
      final entries = await memory.readTrail(record.trailId).toList();
      final truncationNotes = entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == stepTruncatedNoteCategory);
      expect(truncationNotes, isEmpty);
      expect(entries.last.payload['status'], 'accepted');
    });
  });
}

// ── A test-local step-runner ────────────────────────────────────────
//
// Stands in for the engine step-runner C.38 will own. Runs one step under a
// `StepDeadline`; on `StepTruncated` it knows how to close the run the way
// the engine will: a `step_truncated` note on the trail plus a `preempted`
// run outcome. This is a test double — it exists to prove the integrated
// behaviour, not to ship.
final class _DeadlineStepRunner {
  _DeadlineStepRunner({required this.recorder, required this.clock});

  final RunRecorder recorder;
  final DateTime Function() clock;

  /// Races [step] against [deadline] and returns which side won.
  Future<StepOutcome<T>> runStep<T>(StepDeadline deadline, Future<T> step) =>
      deadline.guard<T>(step);

  /// Maps a [StepTruncated] outcome onto the trail: a `step_truncated` note
  /// carrying the breached limit, then a `preempted` run close-out.
  Future<ProcedureRunRecord> closeAsTruncated(StepOutcome<void> outcome) async {
    final truncated = outcome as StepTruncated<void>;
    recorder.note(
      TrailNote(
        category: stepTruncatedNoteCategory,
        recordedAt: clock(),
        payload: <String, Object?>{'limitMs': truncated.limit.inMilliseconds},
      ),
    );
    return recorder.complete(
      RunCompletion(
        status: TrailOutcomeStatus.preempted,
        summary: 'step exceeded ${truncated.limit.inSeconds}s deadline',
      ),
    );
  }
}

// ── A `Timer` test double ───────────────────────────────────────────
//
// Mirrors `step_deadline_test.dart`'s fake: captures the scheduled callback
// and fires it on demand so the deadline is driven deterministically.
final class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;

  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read
// back: trails are ordered entry logs (`closeTrail` synthesises the outcome
// line, matching real memory), stacks are push/peek/remove containers, and
// persisted nodes are resolvable by id. Unimplemented members fall through
// to `noSuchMethod`.
class _StatefulMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  @override
  StackApi get stacks => _stacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('appendTrail on an unopened trail: $id');
    }
    if (_closedTrails.contains(id)) {
      throw StateError('appendTrail on a closed trail: $id');
    }
    entries.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('closeTrail on an unopened trail: $id');
    }
    entries.add(TrailEntry.outcome(outcome));
    _closedTrails.add(id);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final entries = _trails[id];
    if (entries == null) {
      return Stream<TrailEntry>.error(
        StateError('readTrail on an unknown trail: $id'),
      );
    }
    return Stream<TrailEntry>.fromIterable(List<TrailEntry>.of(entries));
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async =>
      EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _InMemoryStacks implements StackApi {
  final Map<String, List<StackEntry>> _stacks = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_stacks[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _stacks[name] ?? const <StackEntry>[];
    final active = entries
        .where((e) => e.status == StackEntryStatus.active)
        .toList(growable: false);
    return active.length <= k ? active : active.sublist(0, k);
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _stacks[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _stacks[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
