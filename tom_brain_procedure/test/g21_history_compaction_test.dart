// History compaction acceptance suite (Plan step G.21; hub spec § 22.4,
// § 22.10).
//
// Pins the engine-side half of conversation-history compaction — the part
// access spec § 21.10 places in the engine ("the compaction call and prompt
// assembly live in the engine"):
//
//   • `HistoryCompactor` loads the `compact_history_v1` compaction template,
//     binds the `${history.compacted}` + `${history.batch}` placeholders
//     (§ 22.4) and hands the assembled scaffolds to a substrate seam (stubbed
//     here, routed through `sub.llm` at G.23).
//   • On success the rewritten summary replaces `compactedSummary` and
//     `pending` clears (`ConversationHistory.applyCompaction`).
//   • On a failed run the prior summary is kept and `pending` is **not**
//     cleared — retried next turn — with a `history.compaction.failed` note
//     (§ 22.10, never silent data loss).
//   • An over-long result is re-run once with a tightened instruction, then
//     hard-truncated to `maxCompactedChars` with a `history.compaction.truncated`
//     note (§ 22.4).
//   • The durable record survives every path (Hard principle 6).
//
// Since the retired three-layer LLM config scaffold (`prompt_template/`,
// increment 9) was removed, the compactor reads a self-contained
// `HistoryCompactionTemplate` (two scaffolds, no role / model chain). The final
// group pins that minimal template's parser + loader directly.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Writes a `compact_history_v1.yaml` whose scaffolds inject the two history
/// placeholders, into a throwaway template directory, and returns a store.
HistoryCompactionTemplateStore _templates({
  String system = r'Rewrite the running summary so it folds in the new turns. '
      r'Current summary: ${history.compacted}',
  String user = r'New turns to fold in: ${history.batch}',
}) {
  final dir = Directory.systemTemp.createTempSync('g21_tpl_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}compact_history_v1.yaml')
      .writeAsStringSync('''
system: |
  $system
user: |
  $user
''');
  return HistoryCompactionTemplateStore(dir);
}

ConversationHistory _historyAtThreshold({
  HistorySizing sizing = const HistorySizing(
    rawCount: 2,
    compactionThreshold: 3,
    maxCompactedTokens: 1024,
    maxCompactedChars: 6000,
  ),
  String summary = '',
}) {
  final h = ConversationHistory(sizing: sizing, compactedSummary: summary);
  // rawCount + compactionThreshold turns ⇒ exactly threshold pending.
  for (var i = 0; i < sizing.rawCount + sizing.compactionThreshold; i++) {
    h.append(HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i'));
  }
  return h;
}

void main() {
  group('G.21-7 compaction fires and folds the batch', () {
    test('a session at threshold compacts: summary set, pending cleared', () async {
      late HistoryCompactionPrompt seen;
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (prompt) async {
          seen = prompt;
          return 'distilled summary';
        },
      );
      final h = _historyAtThreshold();
      expect(h.needsCompaction, isTrue);

      final result = await compactor.compact(h);

      expect(result.outcome, HistoryCompactionOutcome.compacted);
      expect(h.compactedSummary, 'distilled summary');
      expect(h.pending, isEmpty);
      expect(h.needsCompaction, isFalse);
      // The assembled prompt injected the pending batch (§ 22.4).
      expect(seen.user, contains('q2'));
      expect(seen.tightened, isFalse);
    });

    test('the prior summary is injected via \${history.compacted}', () async {
      late HistoryCompactionPrompt seen;
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (prompt) async {
          seen = prompt;
          return 'updated summary';
        },
      );
      final h = _historyAtThreshold(summary: 'EARLIER-CONTEXT');

      await compactor.compact(h);
      expect(seen.system, contains('EARLIER-CONTEXT'));
    });

    test('the durable record survives compaction (derivation, not deletion)',
        () async {
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (_) async => 'summary',
      );
      final h = _historyAtThreshold();
      final recordBefore = h.durableRecord.toList();

      await compactor.compact(h);

      expect(h.durableRecord, recordBefore);
      expect(h.durableRecord, hasLength(5));
    });
  });

  group('G.21-8 failed run keeps the summary and pending', () {
    test('a throwing substrate keeps the prior summary + pending, notes', () async {
      final notes = <TrailNote>[];
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (_) async => throw StateError('substrate down'),
        onNote: notes.add,
      );
      final h = _historyAtThreshold(summary: 'KEEP-ME');
      final pendingBefore = h.pending.toList();

      final result = await compactor.compact(h);

      expect(result.outcome, HistoryCompactionOutcome.failed);
      expect(h.compactedSummary, 'KEEP-ME');
      expect(h.pending, pendingBefore);
      expect(h.needsCompaction, isTrue);
      expect(notes.single.category, 'history.compaction.failed');
    });
  });

  group('G.21-9 over-long output re-runs once then truncates', () {
    test('over-long twice ⇒ re-run with tighten, then truncate + note', () async {
      const bound = 12;
      final tightenedFlags = <bool>[];
      final notes = <TrailNote>[];
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (prompt) async {
          tightenedFlags.add(prompt.tightened);
          return 'X' * 100; // always over the char bound
        },
        onNote: notes.add,
      );
      final h = _historyAtThreshold(
        sizing: const HistorySizing(
          rawCount: 2,
          compactionThreshold: 3,
          maxCompactedTokens: 100000,
          maxCompactedChars: bound,
        ),
      );

      final result = await compactor.compact(h);

      expect(result.outcome, HistoryCompactionOutcome.truncated);
      expect(h.compactedSummary, hasLength(bound));
      expect(h.pending, isEmpty); // truncation is still a completed compaction
      expect(notes.single.category, 'history.compaction.truncated');
      // First pass not tightened, the single re-run is tightened.
      expect(tightenedFlags, [false, true]);
    });

    test('an over-long first pass that fits on the tighter re-run is accepted',
        () async {
      var call = 0;
      final compactor = HistoryCompactor(
        templates: _templates(),
        substrate: (prompt) async {
          call++;
          return call == 1 ? 'X' * 100 : 'tight';
        },
      );
      final h = _historyAtThreshold(
        sizing: const HistorySizing(
          rawCount: 2,
          compactionThreshold: 3,
          maxCompactedTokens: 100000,
          maxCompactedChars: 12,
        ),
      );

      final result = await compactor.compact(h);

      expect(result.outcome, HistoryCompactionOutcome.compacted);
      expect(h.compactedSummary, 'tight');
      expect(h.pending, isEmpty);
      expect(call, 2);
    });
  });

  group('G.21-10 the self-contained compaction template', () {
    test('fromYamlString reads exactly the two scaffolds, ignoring legacy fields',
        () {
      // A document still carrying the retired layer-3 fields (id / role /
      // models) parses fine — only `system` / `user` are read.
      final template = HistoryCompactionTemplate.fromYamlString(r'''
id: compact_history_v1
role: history_compactor
models:
  - { config: gemma_4_26b, provider: ollama }
system: |
  Current summary: ${history.compacted}
user: |
  New turns: ${history.batch}
''');
      expect(
        template.system + template.user,
        allOf(contains(r'${history.compacted}'), contains(r'${history.batch}')),
      );
    });

    test('a missing scaffold field is a located LlmConfigInvalid', () {
      expect(
        () => HistoryCompactionTemplate.fromYamlString('system: only-system\n'),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('loadFromFile on an absent file throws HistoryCompactionTemplateMissing',
        () {
      final dir = Directory.systemTemp.createTempSync('g21_missing_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = HistoryCompactionTemplateStore(dir);
      expect(
        () => store.load('compact_history_v1'),
        throwsA(isA<HistoryCompactionTemplateMissing>()),
      );
    });
  });
}
