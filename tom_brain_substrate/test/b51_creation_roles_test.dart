// Todo 9 (G-C4) — the three creation-subsystem roles
// (`creation_specification.md` § 6).
//
// The creation loop authors, tests, and reviews an artifact with three
// dedicated roles:
//
//   * `creator`  — the artifact author. Runs file / analyze / test tools and
//                  reads memory for context, so it carries `memoryRead` +
//                  `toolCall`. It emits the artifact draft; it does not persist
//                  (the host `create_v1` procedure does) or speak to the user.
//   * `tester`   — authors the test / success check when test-first applies.
//                  Same capability shape as `creator` (drafts a test file and
//                  runs it through the test tool).
//   * `reviewer` — the critic. A structured-verdict role (`accept | revise`),
//                  sibling to the thinking-loop `evaluator` and the
//                  `procedure_critic`. Reads memory to cite prior conclusions;
//                  never runs tools, never persists, never speaks to the user.
//
// All three carry the assistant-dedication anchor (§ 6) and never write memory
// or speak to the user. They are a *separate, optional* roster from the six
// bootstrap roles — `bootstrapRoleRegistry()` is pinned at six by b22 — composed
// onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()`, exactly as the
// procedure roster composes via `bootstrapRoleRegistryWithProcedure()`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('creation role roster', () {
    test('creationRoleIds is the three § 6 ids in canonical order', () {
      expect(
        creationRoleIds,
        equals(<String>['creator', 'tester', 'reviewer']),
      );
    });

    test('creationRoleTemplates() yields three roles in canonical order', () {
      final templates = creationRoleTemplates();
      expect(templates, hasLength(3));
      expect(templates.map((t) => t.id).toList(), equals(creationRoleIds));
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
      }
    });

    test('no creation role grants userFacingAnswer or memoryWrite', () {
      for (final t in creationRoleTemplates()) {
        expect(t.permits(AllowedAction.userFacingAnswer), isFalse,
            reason: t.id);
        expect(t.permits(AllowedAction.memoryWrite), isFalse, reason: t.id);
        expect(t.forbiddenActions.contains(AllowedAction.userFacingAnswer),
            isTrue,
            reason: t.id);
        expect(t.forbiddenActions.contains(AllowedAction.memoryWrite), isTrue,
            reason: t.id);
      }
    });

    test('creator and tester may call tools and read memory', () {
      for (final id in <String>['creator', 'tester']) {
        final t = creationRoleTemplates().firstWhere((t) => t.id == id);
        expect(t.permits(AllowedAction.toolCall), isTrue, reason: id);
        expect(t.permits(AllowedAction.memoryRead), isTrue, reason: id);
        expect(t.permits(AllowedAction.llmCall), isTrue, reason: id);
      }
    });

    test('reviewer is a structured-verdict role: no tools, reads memory', () {
      final reviewer =
          creationRoleTemplates().firstWhere((t) => t.id == 'reviewer');
      expect(reviewer.permits(AllowedAction.toolCall), isFalse);
      expect(reviewer.permits(AllowedAction.memoryRead), isTrue);
      expect(reviewer.permits(AllowedAction.llmCall), isTrue);
      expect(reviewer.outputSchema?['properties'], contains('verdict'));
    });

    test('bootstrapCreationRoleRegistry() holds exactly the three roles', () {
      final reg = bootstrapCreationRoleRegistry();
      expect(reg.length, 3);
      expect(reg.ids.toList(), equals(creationRoleIds));
    });

    test('every creation role assembles anchor-first and stamps the hash', () {
      for (final t in creationRoleTemplates()) {
        final p = t.assemble();
        expect(p.body, startsWith(AssistantDedicationAnchor.text),
            reason: t.id);
        expect(p.anchorHash, equals(AnchorRegistry.currentHash), reason: t.id);
        expect(p.roleId, equals(t.id), reason: t.id);
      }
    });

    test('bootstrapRoleRegistry() is still exactly six (b22 contract holds)',
        () {
      expect(bootstrapRoleRegistry().length, 6);
    });

    group('full live roster (retrieval + procedure + creation)', () {
      test('composes the eighteen-role roster in layer order', () {
        final reg = bootstrapRoleRegistryWithRetrievalProcedureAndCreation();
        // 6 core + 6 retrieval + 3 procedure + 3 creation.
        expect(reg.length, 18);
        for (final id in creationRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The creation roster is appended last, after the procedure roster.
        final ids = reg.ids.toList();
        expect(ids.sublist(ids.length - 3), equals(creationRoleIds));
      });

      test('still carries the procedure roster', () {
        final reg = bootstrapRoleRegistryWithRetrievalProcedureAndCreation();
        for (final id in procedureRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
      });
    });
  });
}
