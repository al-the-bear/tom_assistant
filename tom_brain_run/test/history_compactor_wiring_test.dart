// HC-81 / I-2 (tom_brain_completion_plan_2 item 3) — production activation of
// the history compactor in *both* answer lanes.
//
// The compaction seam ships built but, until item 3, was not production-wired:
// `provisionBrain` constructed no `HistoryCompactor`, so neither the foreground
// answer lane nor the dreaming lanes ever folded — each session's `pending`
// batch grew unfolded (losing nothing: the durable record keeps every turn /
// firing). Item 3 wires both lanes through a single gated seam,
// `historyCompactorFor`, and ships the production `compact_history_v1.yaml`
// template under the cognition tree.
//
// This suite pins that activation, without needing a vec0 boot:
//
//   1. The shipped production template `compact_history_v1.yaml` parses and
//      carries the two history placeholders the compactor injects. A missing or
//      malformed template would otherwise degrade a fold to a safe never-fold
//      (the compactor swallows the load error) — silent, so this is a loud
//      tripwire on the artifact itself.
//   2. The shared gate `historyCompactorFor` — the single decision both lanes
//      make in `provisionBrain` — returns a real compactor exactly when the
//      production template is present, and `null` (the safe never-fold default)
//      when the cognition tree is absent or carries no template.
//   3. The foreground answer lane: the gate-built compactor folds an
//      over-threshold `ConversationHistory` (the exact object the answer lane's
//      post-back-fill `_maybeCompact` calls `compact` on) through the production
//      template and the real `SubstrateHistoryCompaction` seam.
//   4. The dreaming lane: the same gate-built compactor folds an over-threshold
//      dreaming lane through `DreamLaneSessions`.
//
// Both lane proofs drive the *production* construction (`historyCompactorFor` →
// `buildHistoryCompactor` → `SubstrateHistoryCompaction`), never a
// hand-constructed `HistoryCompactor`. The boot-level fold through the
// dispatcher's `BrainProcessConfig.historyCompactor` seam is separately pinned
// by `tom_brain_procedure/test/history_compaction_pipeline_test.dart`.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        DreamLaneSessions,
        HistoryCompactionOutcome,
        HistoryCompactionResult,
        HistoryCompactionTemplate,
        HistoryCompactionTemplateStore,
        HistoryCompactor,
        defaultCompactionTemplate;
import 'package:tom_brain_run/tom_brain_run.dart' show historyCompactorFor;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ConversationHistory, HistoryConfig, HistorySizing, HistoryTurn;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart'
    show SmokeSubstrate;
import 'package:test/test.dart';

/// The shipped production cognition tree the brain boots from on bomber. The
/// template store resolves `<dir>/compact_history_v1.yaml` under it.
Directory _productionCognitionDir() => Directory('config/bomber/cognition');

/// A dreaming lane id, sized tiny below so a few firings cross the fold
/// threshold (rawCount 1 + compactionThreshold 2 ⇒ the third firing folds).
const String _laneId = 'dream_stub_v1';

void main() {
  group('item 3 — the shipped production compact_history_v1 template', () {
    test('parses and carries both history placeholders', () async {
      final store = HistoryCompactionTemplateStore(_productionCognitionDir());

      final HistoryCompactionTemplate template =
          await store.load(defaultCompactionTemplate);

      // Both scaffolds are present and non-empty …
      expect(template.system.trim(), isNotEmpty);
      expect(template.user.trim(), isNotEmpty);
      // … and the two placeholders the compactor binds are reachable: the
      // running summary in the system scaffold, the new batch in the user one.
      expect(template.system, contains(r'${history.compacted}'));
      expect(template.user, contains(r'${history.batch}'));
    });
  });

  group('item 3 — historyCompactorFor (the shared gate both lanes wire in)', () {
    test('returns a compactor when the production template is present', () {
      final compactor = historyCompactorFor(
        templatesDir: _productionCognitionDir(),
        substrate: SmokeSubstrate(),
      );
      expect(compactor, isNotNull);
    });

    test('returns null when no cognition tree is configured (templatesDir null)',
        () {
      final compactor = historyCompactorFor(
        templatesDir: null,
        substrate: SmokeSubstrate(),
      );
      expect(compactor, isNull,
          reason: 'no template ⇒ the safe never-fold default');
    });

    test('returns null when the tree carries no compact_history_v1 template', () {
      final empty = Directory.systemTemp.createTempSync('no_compaction_tpl_');
      addTearDown(() => empty.deleteSync(recursive: true));

      final compactor = historyCompactorFor(
        templatesDir: empty,
        substrate: SmokeSubstrate(),
      );
      expect(compactor, isNull,
          reason: 'an absent template degrades to never-fold, not a throw');
    });
  });

  group('item 3 — the foreground answer lane folds through the gate-built '
      'compactor', () {
    test(
        'an over-threshold ConversationHistory folds its pending batch into a '
        'non-empty summary through the production template + substrate seam',
        () async {
      final SmokeSubstrate substrate = SmokeSubstrate()
        ..answerChunks = <String>['distilled ', 'answer-lane summary'];

      // The exact compactor `provisionBrain` wires into the foreground lane's
      // `BrainProcessConfig.historyCompactor` seam: the shared gate over the
      // production cognition tree + the incoming substrate.
      final HistoryCompactor? compactor = historyCompactorFor(
        templatesDir: _productionCognitionDir(),
        substrate: substrate,
      );
      expect(compactor, isNotNull);

      // A session whose pending batch is over threshold — shaped exactly as the
      // answer lane holds it when `_maybeCompact` runs after a turn's back-fill.
      final history = ConversationHistory(
        sizing: const HistorySizing(
          rawCount: 2,
          compactionThreshold: 3,
          maxCompactedTokens: 1024,
          maxCompactedChars: 6000,
        ),
      );
      for (var i = 0; i < 5; i++) {
        history.append(HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i'));
      }
      expect(history.needsCompaction, isTrue,
          reason: 'precondition: the seeded batch is over threshold');

      final HistoryCompactionResult result = await compactor!.compact(history);

      // The fold ran through the production seam: a non-empty rewritten summary,
      // a cleared pending batch — derivation, not deletion (the durable record
      // keeps every turn).
      expect(result.outcome, HistoryCompactionOutcome.compacted);
      expect(history.compactedSummary, 'distilled answer-lane summary');
      expect(history.pending, isEmpty);
      expect(history.durableRecord, hasLength(5));
      // The compaction completion actually reached the substrate, carrying the
      // assembled production scaffolds as its single prompt input.
      expect(substrate.lastPrompt, isNotNull);
    });
  });

  group('item 3 — the dreaming lane folds through the gate-built compactor', () {
    test(
        'an over-threshold dreaming lane folds through the production template '
        'and the real substrate seam', () async {
      final SmokeSubstrate substrate = SmokeSubstrate()
        ..answerChunks = <String>['distilled ', 'dreaming summary'];

      // The same gate-built compactor the dream loop wires into
      // `DreamLaneSessions.compactor`.
      final compactor = historyCompactorFor(
        templatesDir: _productionCognitionDir(),
        substrate: substrate,
      );

      // Size the lane tiny so the third firing's append crosses the threshold.
      const tiny = HistoryConfig(
        lanes: <String, HistorySizing>{
          _laneId: HistorySizing(rawCount: 1, compactionThreshold: 2),
        },
      );
      final sessions = DreamLaneSessions(
        historyConfig: tiny,
        compactor: compactor,
      );

      for (var i = 0; i < 3; i++) {
        await sessions.recordFiring(
          _laneId,
          trigger: 'dream cycle $i',
          outcome: 'did work on source-$i',
        );
      }

      final history = sessions.peek(_laneId)!;
      // The lane folded its pending batch into the substrate's rewritten
      // summary — derivation, not deletion: the durable record keeps every
      // firing.
      expect(history.compactedSummary, 'distilled dreaming summary');
      expect(history.pending, isEmpty);
      expect(history.durableRecord, hasLength(3));
      // The compaction completion actually reached the substrate, carrying the
      // assembled production scaffolds as its single prompt input.
      expect(substrate.lastPrompt, isNotNull);
    });
  });
}
