// Phase-C todo 9: the booted dispatch route runs the engine-side
// `HistoryCompactor` after a turn's answer is back-filled (hub § 22.4 / § 22.10).
//
// `g21_history_compaction_test.dart` already pins the compactor in isolation
// (fold / fail-retry / over-long-truncate). This suite pins the *wiring*: a
// prompt served through the booted dispatcher, on a session whose pending batch
// has crossed `compactionThreshold`, folds that batch into the bounded summary
// and clears `pending` — and that the path is a no-op (history untouched) when
// no compactor is configured or the batch is below threshold.
//
// The harness mirrors `boot_history_injection_test.dart`: an in-process memory
// double + a prompt-answering substrate, with the live prompt riding as the last
// (answer-less) turn of the seeded `ConversationHistory`. The shared boot doubles
// (`BootMemory` / `BootSubstrate`) live in `support/boot_doubles.dart` (HC-34);
// `BootSubstrate` answers both foreground lanes (the `assistant_to_user`
// confirmation → `DONE` and the thinking lane's `evaluator` → `ACCEPT`). The
// compactor's own substrate seam is a separate one-line stub (it is injected into
// the `HistoryCompactor`, not the engine's substrate).

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        ConversationHistory,
        HistorySizing,
        HistoryTurn,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        TurnId;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';
import 'support/boot_doubles.dart';

void main() {
  late BootMemory memory;
  late BootSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = BootMemory();
    substrate = BootSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig config({HistoryCompactor? historyCompactor}) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/hist_compaction'),
        ),
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
        historyCompactor: historyCompactor,
      );

  /// A stub compaction substrate that always returns [summary] — stands in for
  /// the anchored `sub.llm` seam (G.23), independent of the engine substrate.
  HistoryCompactor compactorReturning(String summary) => HistoryCompactor(
        templates: _templates(),
        substrate: (_) async => summary,
      );

  /// A `ConversationHistory` seeded with [answeredTurns] answered turns plus one
  /// live answer-less turn (the prompt about to be served), shaped exactly as
  /// the assembler hands it to the route. Small sizing keeps the pending batch
  /// past threshold with few turns (the rawCount floor of 10 is enforced only at
  /// config parse, so the direct constructor accepts these test values).
  ConversationHistory seededHistory({
    required int answeredTurns,
    String livePrompt = 'live prompt',
  }) {
    final h = ConversationHistory(
      sizing: const HistorySizing(
        rawCount: 2,
        compactionThreshold: 3,
        maxCompactedTokens: 1024,
        maxCompactedChars: 6000,
      ),
    );
    for (var i = 0; i < answeredTurns; i++) {
      h.append(HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i'));
    }
    h.append(HistoryTurn(userPrompt: livePrompt, brainAnswer: ''));
    return h;
  }

  Access promptWithHistory(ConversationHistory history,
          {String text = 'live prompt'}) =>
      Access(
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        history: history,
        turnId: TurnId.generate(),
      );

  test('a session over threshold compacts after the answer is back-filled',
      () async {
    substrate.answerChunks = <String>['the answer'];
    // rawCount 2 + 3 answered + 1 live ⇒ pending 4 ≥ threshold 3.
    final history = seededHistory(answeredTurns: 5);
    expect(history.needsCompaction, isTrue,
        reason: 'precondition: the seeded batch is over threshold');

    final booted =
        await BrainProcessBoot.boot(config(historyCompactor: compactorReturning('distilled')));
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    // The pending batch was folded into the bounded summary and cleared.
    expect(history.compactedSummary, 'distilled');
    expect(history.pending, isEmpty);
    expect(history.needsCompaction, isFalse);
    // The live turn was still back-filled (the existing § 7.2 #4 behaviour).
    expect(history.rawWindow.last.brainAnswer, 'the answer');
  });

  test(
      'the thinking lane (second pipeline entry) also compacts after back-fill',
      () async {
    // The compaction check lives in the single two-phase route's post-back-fill
    // step (`_maybeCompact`), which runs for whichever answer branch produced
    // the answer — so it is branch-agnostic. This pins the *second* foreground
    // answer lane: a deliberation-cued prompt routes to `answer_with_thinking_v1`
    // (not `answer_with_memory_v1`), and the same over-threshold session still
    // folds and clears its pending batch.
    substrate.answerChunks = <String>['the thoughtful answer'];
    final history = seededHistory(
        answeredTurns: 5, livePrompt: 'think about how memory consolidates');
    expect(history.needsCompaction, isTrue,
        reason: 'precondition: the seeded batch is over threshold');

    final booted = await BrainProcessBoot.boot(
        config(historyCompactor: compactorReturning('distilled')));
    addTearDown(booted.shutdown);

    // "think about …" trips the deterministic cue floor, so the route selects
    // the thinking branch even though the fake router classifies `normal`.
    await booted.dispatcher.accept(
        promptWithHistory(history, text: 'think about how memory consolidates'));

    // The recursive-loop lane compacted exactly like the normal lane.
    expect(history.compactedSummary, 'distilled');
    expect(history.pending, isEmpty);
    expect(history.needsCompaction, isFalse);
    // The thinking loop's accepted draft was back-filled into the live turn.
    expect(history.rawWindow.last.brainAnswer, 'the thoughtful answer');
  });

  test('a session below threshold is not compacted', () async {
    substrate.answerChunks = <String>['the answer'];
    // rawCount 2 + 3 answered + 1 live ⇒ pending 2 < threshold 3.
    final history = seededHistory(answeredTurns: 3);
    expect(history.needsCompaction, isFalse);
    expect(history.pending, hasLength(2),
        reason: 'precondition: a non-empty batch that is still below threshold');

    final booted =
        await BrainProcessBoot.boot(config(historyCompactor: compactorReturning('distilled')));
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    // No compaction ran: the summary stays empty and the batch is intact.
    expect(history.compactedSummary, isEmpty);
    expect(history.pending, hasLength(2));
  });

  test('no compactor configured leaves an over-threshold batch untouched',
      () async {
    substrate.answerChunks = <String>['the answer'];
    final history = seededHistory(answeredTurns: 5);
    final pendingBefore = history.pending.toList();
    expect(history.needsCompaction, isTrue);

    // The prototype default: no `historyCompactor` ⇒ the answer path runs
    // exactly as before, with no compaction.
    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory(history));

    expect(history.compactedSummary, isEmpty);
    expect(history.pending, pendingBefore);
    expect(history.needsCompaction, isTrue);
    // The answer was still back-filled — only compaction is skipped.
    expect(history.rawWindow.last.brainAnswer, 'the answer');
  });
}

/// Writes a `compact_history_v1.yaml` whose scaffolds inject the two history
/// placeholders, into a throwaway directory, and returns a store.
HistoryCompactionTemplateStore _templates() {
  final dir = Directory.systemTemp.createTempSync('hist_compaction_tpl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}compact_history_v1.yaml')
      .writeAsStringSync(r'''
system: |
  Fold the new turns into the running summary. Current: ${history.compacted}
user: |
  New turns: ${history.batch}
''');
  return HistoryCompactionTemplateStore(dir);
}
