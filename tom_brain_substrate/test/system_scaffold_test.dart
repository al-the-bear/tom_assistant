// Prompt-restructuring plan step 6 — the shared role-preamble *system
// scaffold*.
//
// Plan-step text (verbatim, the test obligation):
//   "Tests: assembled system part equals the expected layout for a role
//    with an output schema and for one without (the `?` slot vanishes)."
//
// Scope of this test file:
//
//   - Pin `SystemScaffold.render` directly: the exact assembled bytes for
//     a free-text role (no output-schema section) and for a structured
//     role (with the fully composed `OUTPUT SCHEMA:` section). The optional
//     `${output_schema?}` slot must *vanish* — no `OUTPUT SCHEMA:` header,
//     no trailing whitespace — when the section is empty.
//   - Pin the same layout end-to-end through `RoleTemplate.assemble`: the
//     `WirePrompt.system` (after `ensurePrefix`) equals the anchor followed
//     by the rendered scaffold, byte-for-byte, for a role with and without
//     an `outputSchema`.
//   - Pin that the rendered scaffold already leads with the anchor (via the
//     `${role.anchor}` placeholder), so `ensurePrefix` is idempotent and the
//     two views agree.
//   - Pin `SystemScaffold.template` carries the literal placeholders an
//     operator edits (`${role.anchor}`, `${persona}`, `${objective}`,
//     `${output_schema?}`) — the framing is data, not Dart.

import 'dart:convert' show jsonEncode;

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  // The expected `OUTPUT SCHEMA:` section, kept here as the one place the
  // test states the structured-output wording. `RoleTemplate` composes the
  // same bytes internally; if the wording changes, both this constant and
  // the production string move together (and the assertions catch a drift).
  String expectedSchemaSection(Map<String, Object?> schema) =>
      '\n\nOUTPUT SCHEMA:\n'
      'Respond with a single JSON object — and nothing else: no prose, no '
      'markdown code fences, no commentary — that conforms to this JSON '
      'schema:\n'
      '${jsonEncode(schema)}';

  group('SystemScaffold.render', () {
    test('free-text role: the ?-slot vanishes (no OUTPUT SCHEMA, no trailing '
        'whitespace)', () {
      final rendered = SystemScaffold.render(
        persona: 'I am the analyser.',
        objective: 'Decompose the prompt.',
      );

      // Exact layout: anchor, then PERSONA / OBJECTIVE, nothing after.
      expect(
        rendered,
        equals(
          '${AssistantDedicationAnchor.text}'
          'PERSONA:\n'
          'I am the analyser.\n'
          '\n'
          'OBJECTIVE:\n'
          'Decompose the prompt.',
        ),
      );
      // The optional slot truly vanished — no header, no dangling newline.
      expect(rendered, isNot(contains('OUTPUT SCHEMA:')));
      expect(rendered.endsWith('Decompose the prompt.'), isTrue,
          reason: 'no trailing whitespace where the ?-slot was');
    });

    test('structured role: the ?-slot renders the supplied OUTPUT SCHEMA '
        'section verbatim', () {
      const schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'questions': <String, Object?>{'type': 'array'},
        },
      };
      final rendered = SystemScaffold.render(
        persona: 'I am the analyser.',
        objective: 'Decompose the prompt.',
        outputSchemaSection: expectedSchemaSection(schema),
      );

      expect(
        rendered,
        equals(
          '${AssistantDedicationAnchor.text}'
          'PERSONA:\n'
          'I am the analyser.\n'
          '\n'
          'OBJECTIVE:\n'
          'Decompose the prompt.'
          '${expectedSchemaSection(schema)}',
        ),
      );
    });

    test('rendered scaffold already leads with the anchor text', () {
      final rendered = SystemScaffold.render(
        persona: 'P',
        objective: 'O',
      );
      expect(rendered.startsWith(AssistantDedicationAnchor.text), isTrue);
    });

    test('template exposes the editable placeholders (framing is data)', () {
      expect(SystemScaffold.template, contains(r'${role.anchor}'));
      expect(SystemScaffold.template, contains(r'${persona}'));
      expect(SystemScaffold.template, contains(r'${objective}'));
      expect(SystemScaffold.template, contains(r'${output_schema?}'));
    });
  });

  group('RoleTemplate.assemble system layout (step 6 end-to-end)', () {
    RoleTemplate makeRole({Map<String, Object?>? outputSchema}) => RoleTemplate(
          id: 'analyser',
          personaText: 'I am the analyser.',
          objective: 'Decompose the prompt.',
          allowedActions: const {AllowedAction.llmCall},
          outputSchema: outputSchema,
        );

    test('role without an output schema: system equals the anchored, '
        'schema-less layout', () {
      final p = makeRole().assemble();
      expect(
        p.system,
        equals(
          '${AssistantDedicationAnchor.text}'
          'PERSONA:\n'
          'I am the analyser.\n'
          '\n'
          'OBJECTIVE:\n'
          'Decompose the prompt.',
        ),
      );
    });

    test('role with an output schema: system equals the anchored layout plus '
        'the OUTPUT SCHEMA section', () {
      const schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'verdict': <String, Object?>{'type': 'string'},
        },
      };
      final p = makeRole(outputSchema: schema).assemble();
      expect(
        p.system,
        equals(
          '${AssistantDedicationAnchor.text}'
          'PERSONA:\n'
          'I am the analyser.\n'
          '\n'
          'OBJECTIVE:\n'
          'Decompose the prompt.'
          '${expectedSchemaSection(schema)}',
        ),
      );
    });

    test('the schema-less and schema-bearing systems differ only by the '
        'appended section', () {
      const schema = <String, Object?>{'type': 'object'};
      final without = makeRole().assemble().system;
      final withSchema = makeRole(outputSchema: schema).assemble().system;
      expect(withSchema, equals('$without${expectedSchemaSection(schema)}'));
    });
  });
}
