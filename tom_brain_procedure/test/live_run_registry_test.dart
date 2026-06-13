// LiveRunRegistry — the process-lifetime view of in-flight runs that backs the
// Telegram `/check_usage` command. These tests pin the folding contract:
//
//   - only turn-runs (a user prompt and its sub-procedures) count; turn-less
//     background runs are excluded;
//   - the folded usage sums every open turn-run's *live* effort and names the
//     top-level run for elapsed / procedure id;
//   - `readEffort` is read fresh on each fold, so a still-accumulating run's
//     spend is reflected without re-registering it.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:test/test.dart';

void main() {
  // A small builder so each test names only the fields it cares about; the
  // effort is supplied as a live closure to mimic an open recorder.
  LiveRun run({
    required String runId,
    String procedureId = 'p',
    String? parentRunId,
    String? turnId,
    DateTime? startedAt,
    EffortMetrics Function()? readEffort,
    void Function()? cancel,
  }) {
    return LiveRun(
      runId: runId,
      procedureId: procedureId,
      parentRunId: parentRunId,
      turnId: turnId,
      startedAt: startedAt ?? DateTime(2026),
      readEffort: readEffort ?? () => EffortMetrics.zero,
      cancel: cancel,
    );
  }

  group('LiveRunRegistry', () {
    test('reports no prompt usage when nothing is open', () {
      final registry = LiveRunRegistry();
      expect(registry.hasOpenPromptRun, isFalse);
      expect(registry.currentPromptUsage(), isNull);
    });

    test('ignores turn-less background runs', () {
      final registry = LiveRunRegistry();
      registry.open(run(runId: 'bg', turnId: null));
      expect(registry.hasOpenPromptRun, isFalse);
      expect(registry.currentPromptUsage(), isNull);
    });

    test('folds the top-level run and its sub-procedures into one snapshot', () {
      final registry = LiveRunRegistry();
      registry.open(run(
        runId: 'top',
        procedureId: 'answer_with_thinking_v1',
        parentRunId: null,
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10),
        readEffort: () => EffortMetrics(
          llmCalls: 1,
          inputTokens: 100,
          outputTokens: 20,
          toolCalls: 1,
        ),
      ));
      registry.open(run(
        runId: 'child',
        procedureId: 'retrieve_v1',
        parentRunId: 'top',
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10, 0, 5),
        readEffort: () => EffortMetrics(
          llmCalls: 2,
          inputTokens: 50,
          outputTokens: 5,
        ),
      ));

      expect(registry.hasOpenPromptRun, isTrue);
      final usage = registry.currentPromptUsage()!;
      expect(usage.procedureId, 'answer_with_thinking_v1');
      expect(usage.runId, 'top');
      expect(usage.startedAt, DateTime(2026, 6, 11, 10));
      expect(usage.openRunCount, 2);
      expect(usage.effort.llmCalls, 3);
      expect(usage.effort.toolCalls, 1);
      expect(usage.effort.estimatedTokens, 175);
    });

    test('reads effort fresh on each fold (live accumulation)', () {
      final registry = LiveRunRegistry();
      var calls = 0;
      registry.open(run(
        runId: 'top',
        parentRunId: null,
        turnId: 'turn-1',
        readEffort: () {
          calls += 1;
          return EffortMetrics(toolCalls: calls);
        },
      ));

      expect(registry.currentPromptUsage()!.effort.toolCalls, 1);
      expect(registry.currentPromptUsage()!.effort.toolCalls, 2);
    });

    test('closing a run removes it from the fold', () {
      final registry = LiveRunRegistry();
      registry.open(run(runId: 'top', parentRunId: null, turnId: 'turn-1'));
      expect(registry.hasOpenPromptRun, isTrue);
      registry.close('top');
      expect(registry.hasOpenPromptRun, isFalse);
      expect(registry.currentPromptUsage(), isNull);
    });

    test('falls back to the earliest run when no top-level run is open', () {
      final registry = LiveRunRegistry();
      // Transient window the single-foreground invariant should preclude: only
      // sub-runs are open. The earliest-started run names the snapshot.
      registry.open(run(
        runId: 'child-late',
        parentRunId: 'gone',
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10, 0, 10),
      ));
      registry.open(run(
        runId: 'child-early',
        procedureId: 'retrieve_v1',
        parentRunId: 'gone',
        turnId: 'turn-1',
        startedAt: DateTime(2026, 6, 11, 10, 0, 1),
      ));

      final usage = registry.currentPromptUsage()!;
      expect(usage.runId, 'child-early');
      expect(usage.openRunCount, 2);
    });
  });

  group('LiveRunRegistry.cancelCurrentPrompt', () {
    test('returns false and cancels nothing when no prompt is open', () {
      final registry = LiveRunRegistry();
      expect(registry.cancelCurrentPrompt(), isFalse);
    });

    test('ignores a turn-less background run (returns false, no cancel)', () {
      final registry = LiveRunRegistry();
      var cancelled = false;
      registry.open(
        run(runId: 'bg', turnId: null, cancel: () => cancelled = true),
      );
      expect(registry.cancelCurrentPrompt(), isFalse);
      expect(cancelled, isFalse);
    });

    test('cancels the open foreground prompt and reports it', () {
      final registry = LiveRunRegistry();
      var topCancelled = false;
      registry.open(run(
        runId: 'top',
        parentRunId: null,
        turnId: 'turn-1',
        cancel: () => topCancelled = true,
      ));
      expect(registry.cancelCurrentPrompt(), isTrue);
      expect(topCancelled, isTrue);
    });

    test('cancels every open turn-run of the prompt', () {
      final registry = LiveRunRegistry();
      var topCancelled = false;
      var childCancelled = false;
      registry.open(run(
        runId: 'top',
        parentRunId: null,
        turnId: 'turn-1',
        cancel: () => topCancelled = true,
      ));
      registry.open(run(
        runId: 'child',
        parentRunId: 'top',
        turnId: 'turn-1',
        cancel: () => childCancelled = true,
      ));
      expect(registry.cancelCurrentPrompt(), isTrue);
      expect(topCancelled, isTrue);
      expect(childCancelled, isTrue);
    });

    test('a run with no cancel closure is a harmless no-op', () {
      final registry = LiveRunRegistry();
      registry.open(run(runId: 'top', parentRunId: null, turnId: 'turn-1'));
      // No cancel closure attached (e.g. a test/edge case run): the call still
      // reports a prompt was in flight and does not throw.
      expect(registry.cancelCurrentPrompt(), isTrue);
    });
  });
}
