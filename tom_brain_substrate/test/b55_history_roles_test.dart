// The single conversation-history role (`tom_brain_procedure_specification.md`
// § 22.4, completion-plan item 4 / HC-81).
//
// The engine-side `HistoryCompactor` folds a session's pending verbatim turns
// into its running summary under one dedicated role, `history_compactor` — the
// first-class home that replaced the earlier `recaller` stopgap. Like every
// dreaming role it is a pure text transformer: the compactor resolves the
// `compact_history_v1` scaffolds into the inline prompt and persists the
// rewritten summary; the role only reasons over the inline text and returns
// plain text. So it is `llmCall`-only, forbids memory read/write, tools,
// sub-thinking, and user-facing output, and declares no `outputSchema`.
//
// It is a *separate, optional* roster from the six bootstrap roles —
// `bootstrapRoleRegistry()` is pinned at six by b22 — composed onto the full
// live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory()`,
// exactly as the dream roster composes via
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('history role roster', () {
    test('historyRoleIds is the single history_compactor id', () {
      expect(historyRoleIds, equals(<String>['history_compactor']));
    });

    test('historyRoleTemplates() yields the one role', () {
      final templates = historyRoleTemplates();
      expect(templates, hasLength(1));
      expect(templates.map((t) => t.id).toList(), equals(historyRoleIds));
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
      }
    });

    test('the history role is llmCall-only — a pure text transformer', () {
      for (final t in historyRoleTemplates()) {
        expect(t.permits(AllowedAction.llmCall), isTrue, reason: t.id);
        for (final a in <AllowedAction>[
          AllowedAction.userFacingAnswer,
          AllowedAction.memoryRead,
          AllowedAction.memoryWrite,
          AllowedAction.toolCall,
          AllowedAction.subThinking,
        ]) {
          expect(t.permits(a), isFalse, reason: '${t.id}/$a');
          expect(t.forbiddenActions.contains(a), isTrue, reason: '${t.id}/$a');
        }
      }
    });

    test('the history role declares no output schema (compactor reads free '
        'text)', () {
      for (final t in historyRoleTemplates()) {
        expect(t.outputSchema, isNull, reason: t.id);
      }
    });

    test('bootstrapHistoryRoleRegistry() holds exactly the one role', () {
      final reg = bootstrapHistoryRoleRegistry();
      expect(reg.length, 1);
      expect(reg.ids.toList(), equals(historyRoleIds));
    });

    test('the history role assembles anchor-first and stamps the hash', () {
      for (final t in historyRoleTemplates()) {
        final p = t.assemble();
        expect(p.combined, startsWith(AssistantDedicationAnchor.text),
            reason: t.id);
        expect(p.anchorHash, equals(AnchorRegistry.currentHash), reason: t.id);
        expect(p.roleId, equals(t.id), reason: t.id);
      }
    });

    test('bootstrapRoleRegistry() is still exactly six (b22 contract holds)',
        () {
      expect(bootstrapRoleRegistry().length, 6);
    });

    group('full live roster (… + dream + history)', () {
      test('composes the thirty-two-role roster in layer order', () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory();
        // 6 core + 6 retrieval + 3 procedure + 3 creation + 5 planning +
        // 8 dream + 1 history.
        expect(reg.length, 32);
        for (final id in historyRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The history roster is appended last, after the dream roster.
        final ids = reg.ids.toList();
        expect(ids.sublist(ids.length - 1), equals(historyRoleIds));
      });

      test('still carries the dream and core rosters', () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory();
        for (final id in dreamRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The thinking-loop roles the history-enabled roster must still route.
        for (final id in <String>['analyser', 'sub_thinker', 'evaluator']) {
          expect(reg.contains(id), isTrue, reason: id);
        }
      });
    });
  });
}
