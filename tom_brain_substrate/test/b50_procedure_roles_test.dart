// Todo 7 (G-PR2/G-PR3) — the three procedure-subsystem roles
// (`procedure_specification.md` § 8.2 / § 10.3).
//
// The procedure subsystem authors, gates, and selects procedures with three
// dedicated roles:
//
//   * `procedure_author`   — the authoring branch (§ 8). Drafts a single d4rt
//                            source file with the structured header. Reads past
//                            procedures (recall) and runs the dry-run validator
//                            (a tool), so it carries `memoryRead` + `toolCall`.
//   * `procedure_critic`   — gates a draft / a run outcome (`accept | revise`).
//                            A structured-verdict role, like the thinking-loop
//                            `evaluator`.
//   * `procedure_selector` — tiebreaks when retrieval returns several plausible
//                            candidates. A small `llmCall`-only evaluator over a
//                            caller-supplied candidate list (memory is LLM-free,
//                            so the candidates are fed as inputs — no
//                            `memoryRead`).
//
// All three carry the assistant-dedication anchor (§ 10.3) and never write
// memory (the host procedure persists) or speak to the user (their output is
// internal). They are a *separate, optional* roster from the six bootstrap
// roles — `bootstrapRoleRegistry()` is pinned at six by b22 — composed via
// `bootstrapRoleRegistryWithProcedure()`, exactly as the retrieval roster
// composes via `bootstrapRoleRegistryWithRetrieval()`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('procedure role roster', () {
    test('procedureRoleIds is the three § 10.3 ids in canonical order', () {
      expect(
        procedureRoleIds,
        equals(<String>[
          'procedure_author',
          'procedure_critic',
          'procedure_selector',
        ]),
      );
    });

    test('procedureRoleTemplates() yields three roles in canonical order', () {
      final templates = procedureRoleTemplates();
      expect(templates, hasLength(3));
      expect(templates.map((t) => t.id).toList(), equals(procedureRoleIds));
      for (final t in templates) {
        expect(t.personaText.trim(), isNotEmpty, reason: t.id);
        expect(t.objective.trim(), isNotEmpty, reason: t.id);
      }
    });

    test('no procedure role grants userFacingAnswer or memoryWrite', () {
      for (final t in procedureRoleTemplates()) {
        expect(t.permits(AllowedAction.userFacingAnswer), isFalse,
            reason: t.id);
        expect(t.permits(AllowedAction.memoryWrite), isFalse, reason: t.id);
        // The complementary invariant: each explicitly forbids them so a
        // future ceiling-loosening cannot accidentally grant either.
        expect(t.forbiddenActions, contains(AllowedAction.userFacingAnswer),
            reason: t.id);
        expect(t.forbiddenActions, contains(AllowedAction.memoryWrite),
            reason: t.id);
      }
    });

    test('every procedure role allows llmCall', () {
      for (final t in procedureRoleTemplates()) {
        expect(t.allowedActions, contains(AllowedAction.llmCall),
            reason: t.id);
      }
    });

    test('bootstrapProcedureRoleRegistry() holds exactly the three roles', () {
      final reg = bootstrapProcedureRoleRegistry();
      expect(reg.length, equals(3));
      expect(reg.ids.toList(), equals(procedureRoleIds));
    });

    test('bootstrapRoleRegistryWithProcedure() composes 6 bootstrap + 3 '
        'procedure roles without disturbing the bootstrap roster', () {
      final composed = bootstrapRoleRegistryWithProcedure();
      expect(composed.length, equals(9));
      // The six bootstrap roles are present, unchanged.
      for (final id in prototypeRoleIds) {
        expect(composed.contains(id), isTrue, reason: id);
      }
      // The three procedure roles are present.
      for (final id in procedureRoleIds) {
        expect(composed.contains(id), isTrue, reason: id);
      }
      // The bootstrap roster itself is untouched (b22 contract holds).
      expect(bootstrapRoleRegistry().length, equals(6));
    });

    test('bootstrapRoleRegistryWithRetrievalAndProcedure() is the full live '
        'roster: 6 bootstrap + 6 retrieval + 3 procedure = 15 roles', () {
      final full = bootstrapRoleRegistryWithRetrievalAndProcedure();
      expect(full.length, equals(15));
      for (final id in prototypeRoleIds) {
        expect(full.contains(id), isTrue, reason: id);
      }
      for (final id in retrievalRoleIds) {
        expect(full.contains(id), isTrue, reason: id);
      }
      for (final id in procedureRoleIds) {
        expect(full.contains(id), isTrue, reason: id);
      }
    });
  });

  group('procedure_author', () {
    final t = bootstrapProcedureRoleRegistry().get('procedure_author');

    test('reads memory (recall past procedures) and runs the validator '
        '(a tool), but does not write memory or decompose', () {
      // Recall is the only read (§ 8.3 step 1); validate is the dry-run tool
      // (§ 8.2). It emits one source file — it does not spawn sub-questions.
      expect(t.permits(AllowedAction.llmCall), isTrue);
      expect(t.permits(AllowedAction.memoryRead), isTrue);
      expect(t.permits(AllowedAction.toolCall), isTrue);
      expect(t.forbiddenActions, contains(AllowedAction.subThinking));
    });

    test('declares a source outputSchema (one d4rt file, § 8.2)', () {
      expect(t.outputSchema, isNotNull);
      expect(t.outputSchema!['type'], equals('object'));
      expect(t.outputSchema!['required'] as List, contains('source'));
      final props = t.outputSchema!['properties'] as Map<String, Object?>;
      expect((props['source'] as Map)['type'], equals('string'));
    });
  });

  group('procedure_critic', () {
    final t = bootstrapProcedureRoleRegistry().get('procedure_critic');

    test('is a structured-verdict role: accept | revise (§ 8.3 step 5)', () {
      expect(t.outputSchema, isNotNull);
      final required = t.outputSchema!['required'] as List;
      expect(required, contains('verdict'));
      final props = t.outputSchema!['properties'] as Map<String, Object?>;
      final verdict = props['verdict'] as Map<String, Object?>;
      expect(verdict['type'], equals('string'));
      expect(verdict['enum'], equals(<String>['accept', 'revise']));
    });

    test('reads memory but does not decompose or persist', () {
      expect(t.permits(AllowedAction.memoryRead), isTrue);
      expect(t.forbiddenActions, contains(AllowedAction.subThinking));
      expect(t.permits(AllowedAction.memoryWrite), isFalse);
    });
  });

  group('procedure_selector', () {
    final t = bootstrapProcedureRoleRegistry().get('procedure_selector');

    test('selects from a caller-supplied candidate list — llmCall only, no '
        'memoryRead (memory is LLM-free; candidates are fed as inputs)', () {
      expect(t.permits(AllowedAction.llmCall), isTrue);
      expect(t.permits(AllowedAction.memoryRead), isFalse);
      expect(t.permits(AllowedAction.toolCall), isFalse);
      expect(t.permits(AllowedAction.subThinking), isFalse);
    });

    test('declares a selected + confidence outputSchema', () {
      expect(t.outputSchema, isNotNull);
      final required = t.outputSchema!['required'] as List;
      expect(required, contains('selected'));
      final props = t.outputSchema!['properties'] as Map<String, Object?>;
      expect((props['selected'] as Map)['type'], equals('string'));
      expect((props['confidence'] as Map)['type'], equals('number'));
    });
  });

  group('anchor-first assembly (§ 10.3 — all three carry the anchor)', () {
    test('every procedure role assembles with the anchor first and stamps '
        'the current anchor hash', () {
      for (final t in procedureRoleTemplates()) {
        final p = t.assemble();
        expect(p.body, startsWith(AssistantDedicationAnchor.text),
            reason: t.id);
        expect(p.anchorHash, equals(AnchorRegistry.currentHash), reason: t.id);
        expect(p.roleId, equals(t.id), reason: t.id);
      }
    });
  });
}
