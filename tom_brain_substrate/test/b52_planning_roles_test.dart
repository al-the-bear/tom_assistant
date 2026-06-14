// Todo 8 (G-P3) — the five planning-subsystem roles
// (`planning_specification.md` § 8).
//
// The planning loop (`plan_v1`) runs five dedicated roles, one per stage:
//
//   * `planner`        — classifies the goal + frames the plan. Reads memory
//                        for context (`memoryRead`); emits the classification.
//   * `decomposer`     — the workhorse: breaks the goal into a step set. Same
//                        capability shape as `planner`.
//   * `estimator`      — orders the steps and names dependencies. The step set
//                        is fed as inputs, so it is `llmCall`-only (no
//                        `memoryRead`).
//   * `plan_evaluator` — the critic. A structured-verdict role (`accept |
//                        revise`), sibling to the thinking-loop `evaluator` and
//                        the `procedure_critic`. Reads memory, runs no tools.
//   * `re_planner`     — surgical re-planning on a shaking event. Reads the
//                        plan + observation (`memoryRead`); emits replacement
//                        steps.
//
// All five carry the assistant-dedication anchor (§ 8) and never write memory,
// speak to the user, or spawn sub-questions. They are a *separate, optional*
// roster from the six bootstrap roles — `bootstrapRoleRegistry()` is pinned at
// six by b22 — composed onto the full live roster by
// `bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning()`, exactly
// as the creation roster composes via
// `bootstrapRoleRegistryWithRetrievalProcedureAndCreation()`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('planning role roster', () {
    test('planningRoleIds is the five § 8 ids in canonical loop order', () {
      expect(
        planningRoleIds,
        equals(<String>[
          'planner',
          'decomposer',
          'estimator',
          'plan_evaluator',
          're_planner',
        ]),
      );
    });

    test('planningRoleTemplates() yields five roles in canonical order', () {
      final templates = planningRoleTemplates();
      expect(templates, hasLength(5));
      expect(templates.map((t) => t.id).toList(), equals(planningRoleIds));
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
      }
    });

    test('no planning role grants userFacingAnswer, memoryWrite, or subThinking',
        () {
      for (final t in planningRoleTemplates()) {
        expect(t.permits(AllowedAction.userFacingAnswer), isFalse, reason: t.id);
        expect(t.permits(AllowedAction.memoryWrite), isFalse, reason: t.id);
        expect(t.permits(AllowedAction.subThinking), isFalse, reason: t.id);
        for (final a in <AllowedAction>[
          AllowedAction.userFacingAnswer,
          AllowedAction.memoryWrite,
          AllowedAction.subThinking,
        ]) {
          expect(t.forbiddenActions.contains(a), isTrue, reason: '${t.id}/$a');
        }
      }
    });

    test('planner and decomposer read memory and call the LLM', () {
      for (final id in <String>['planner', 'decomposer']) {
        final t = planningRoleTemplates().firstWhere((t) => t.id == id);
        expect(t.permits(AllowedAction.llmCall), isTrue, reason: id);
        expect(t.permits(AllowedAction.memoryRead), isTrue, reason: id);
      }
    });

    test('planner classifies into the four PlanKind tokens', () {
      final planner =
          planningRoleTemplates().firstWhere((t) => t.id == 'planner');
      final props = planner.outputSchema?['properties'] as Map?;
      expect(props, contains('planKind'));
      final planKind = props!['planKind'] as Map;
      expect(
        planKind['enum'],
        equals(<String>['creation', 'research', 'decision', 'composite']),
      );
    });

    test('estimator is inputs-only: calls the LLM but reads no memory', () {
      final estimator =
          planningRoleTemplates().firstWhere((t) => t.id == 'estimator');
      expect(estimator.permits(AllowedAction.llmCall), isTrue);
      expect(estimator.permits(AllowedAction.memoryRead), isFalse);
      expect(estimator.permits(AllowedAction.toolCall), isFalse);
    });

    test('plan_evaluator is a structured-verdict role: no tools, reads memory',
        () {
      final evaluator =
          planningRoleTemplates().firstWhere((t) => t.id == 'plan_evaluator');
      expect(evaluator.permits(AllowedAction.toolCall), isFalse);
      expect(evaluator.permits(AllowedAction.memoryRead), isTrue);
      expect(evaluator.permits(AllowedAction.llmCall), isTrue);
      final props = evaluator.outputSchema?['properties'] as Map?;
      expect(props, contains('verdict'));
      expect((props!['verdict'] as Map)['enum'],
          equals(<String>['accept', 'revise']));
    });

    test('re_planner reads memory and emits replacement steps', () {
      final rePlanner =
          planningRoleTemplates().firstWhere((t) => t.id == 're_planner');
      expect(rePlanner.permits(AllowedAction.memoryRead), isTrue);
      expect(rePlanner.permits(AllowedAction.llmCall), isTrue);
      final props = rePlanner.outputSchema?['properties'] as Map?;
      expect(props, contains('steps'));
      expect(props, contains('supersedes'));
    });

    test('bootstrapPlanningRoleRegistry() holds exactly the five roles', () {
      final reg = bootstrapPlanningRoleRegistry();
      expect(reg.length, 5);
      expect(reg.ids.toList(), equals(planningRoleIds));
    });

    test('every planning role assembles anchor-first and stamps the hash', () {
      for (final t in planningRoleTemplates()) {
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

    group('full live roster (retrieval + procedure + creation + planning)', () {
      test('composes the twenty-three-role roster in layer order', () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning();
        // 6 core + 6 retrieval + 3 procedure + 3 creation + 5 planning.
        expect(reg.length, 23);
        for (final id in planningRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        // The planning roster is appended last, after the creation roster.
        final ids = reg.ids.toList();
        expect(ids.sublist(ids.length - 5), equals(planningRoleIds));
      });

      test('still carries the creation, procedure, and core rosters', () {
        final reg =
            bootstrapRoleRegistryWithRetrievalProcedureCreationAndPlanning();
        for (final id in creationRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        for (final id in procedureRoleIds) {
          expect(reg.contains(id), isTrue, reason: id);
        }
        expect(reg.contains('assistant_to_user'), isTrue);
        expect(reg.contains('analyser'), isTrue);
      });
    });
  });
}
