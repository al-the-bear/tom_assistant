// I-2 (tom_brain_completion_plan_2 / verification follow-up) — production
// activation of the dream-lane history compactor.
//
// HC-82 shipped the dream-lane durable store and proved a dreaming lane folds
// through the real anchored `sub.llm` seam *in a unit test* (a temp template +
// `BootSubstrate`). The last mile left deferred was the *production* wiring:
// `provisionBrain` / `_startDreamLoop` did not construct a `HistoryCompactor`,
// so a dreaming lane's `pending` batch grew without ever folding, and no
// production `compact_history_v1.yaml` template existed in the config tree.
//
// This suite pins both halves of that last mile, without needing a vec0 boot:
//
//   1. The shipped production template `compact_history_v1.yaml` parses and
//      carries the two history placeholders the compactor injects. A missing or
//      malformed template would otherwise degrade a dreaming fold to a safe
//      never-fold (the compactor swallows the load error) — silent, so this is a
//      loud tripwire on the artifact itself.
//   2. The production builder `buildDreamHistoryCompactor` — the exact seam
//      `_startDreamLoop` now calls — produces a `HistoryCompactor` that folds an
//      over-threshold dreaming lane through the production template and the real
//      `SubstrateHistoryCompaction` path (driven here by a deterministic
//      `SmokeSubstrate` instead of a live model).

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        DreamLaneSessions,
        HistoryCompactionTemplate,
        HistoryCompactionTemplateStore,
        defaultCompactionTemplate;
import 'package:tom_brain_run/tom_brain_run.dart' show buildDreamHistoryCompactor;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show HistoryConfig, HistorySizing;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart'
    show SmokeSubstrate;
import 'package:test/test.dart';

/// The shipped production cognition tree the brain boots from on bomber. The
/// template store resolves `<dir>/compact_history_v1.yaml` under it.
Directory _productionCognitionDir() =>
    Directory('config/bomber/cognition');

/// A dreaming lane id, sized tiny below so a few firings cross the fold
/// threshold (rawCount 1 + compactionThreshold 2 ⇒ the third firing folds).
const String _laneId = 'dream_stub_v1';

void main() {
  group('I-2 — the shipped production compact_history_v1 template', () {
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

  group('I-2 — buildDreamHistoryCompactor (the production wiring seam)', () {
    test(
        'folds an over-threshold dreaming lane through the production template '
        'and the real substrate seam', () async {
      final SmokeSubstrate substrate = SmokeSubstrate()
        ..answerChunks = <String>['distilled ', 'dreaming summary'];

      // The exact construction `_startDreamLoop` now performs in production:
      // the compaction template store over the cognition tree + the anchored,
      // budgeted `SubstrateHistoryCompaction` over the booted substrate.
      final compactor = buildDreamHistoryCompactor(
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
