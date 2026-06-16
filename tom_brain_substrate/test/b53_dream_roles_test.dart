// The eight dreaming-agent roles (`memory_specification.md` § 9 + part f).
//
// Each dream procedure (`scripts/system/dream_*_v1.dart`) runs one dedicated
// role for its single LLM judgement:
//
//   * `extractor`           — distil an Event into an atomic Claim statement.
//   * `connector`           — judge whether a Claim's derived_from link holds.
//   * `synthesiser`         — fold recalled Claims into one Conclusion.
//   * `inquisitor`          — surface the open Question the Claims do not answer.
//   * `pruner`              — judge whether a Claim is redundant against another.
//   * `reconsolidator`      — name the conflict between two Claims.
//   * `repetition_detector` — name the recurring activity across Events.
//   * `memory_curator`      — decide what of a finished exchange is worth storing
//                             (dream-subsystem redesign part f,
//                             `scripts/system/memorize_exchange_v1.dart`).
//
// Every dreaming role is a pure text transformer: the host procedure recalls
// and persists; the role only reasons over the inline text and returns plain
// text. So each is `llmCall`-only and forbids memory read/write, tools,
// sub-thinking, and user-facing output. None declares an `outputSchema` — the
// procedures consume free text (`completion['text']`).
//
// They are a *separate, optional* roster from the six bootstrap roles —
// `bootstrapRoleRegistry()` is pinned at six by b22 — composed onto the full
// live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream()`,
// exactly as the planning roster composes via
// `bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning()`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('dream role roster', () {
    test('dreamRoleIds is the eight § 9 + part-f ids in canonical pipeline '
        'order', () {
      expect(
        dreamRoleIds,
        equals(<String>[
          'extractor',
          'connector',
          'synthesiser',
          'inquisitor',
          'pruner',
          'reconsolidator',
          'repetition_detector',
          'memory_curator',
        ]),
      );
    });

    test('dreamRoleTemplates() yields eight roles in canonical order', () {
      final templates = dreamRoleTemplates();
      expect(templates, hasLength(8));
      expect(templates.map((t) => t.id).toList(), equals(dreamRoleIds));
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
      }
    });

    test('every dream role is llmCall-only — a pure text transformer', () {
      for (final t in dreamRoleTemplates()) {
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

    test('no dream role declares an output schema (procedures read free text)',
        () {
      for (final t in dreamRoleTemplates()) {
        expect(t.outputSchema, isNull, reason: t.id);
      }
    });

    test('bootstrapDreamRoleRegistry() holds exactly the eight roles', () {
      final reg = bootstrapDreamRoleRegistry();
      expect(reg.length, 8);
      expect(reg.ids.toList(), equals(dreamRoleIds));
    });

    test('every dream role assembles anchor-first and stamps the hash', () {
      for (final t in dreamRoleTemplates()) {
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

    group('full live roster (… + planning + dream)', () {
      test('composes the thirty-one-role roster in layer order', () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream();
        // 6 core + 6 retrieval + 3 procedure + 3 creation + 5 planning + 8 dream.
        expect(reg.length, 31);
        for (final id in dreamRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The dream roster is appended last, after the planning roster.
        final ids = reg.ids.toList();
        expect(ids.sublist(ids.length - 8), equals(dreamRoleIds));
      });

      test('still carries the planning, creation, procedure, and core rosters',
          () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream();
        for (final id in planningRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        for (final id in creationRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        for (final id in procedureRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The thinking-loop roles the dream-enabled roster must still route.
        for (final id in <String>['analyser', 'sub_thinker', 'evaluator']) {
          expect(reg.contains(id), isTrue, reason: id);
        }
      });
    });
  });
}
