// B.23 — `AssistantDedicationAnchor` injection conformance suite.
//
// Plan-step text (verbatim):
//   "B.23 Implement `AssistantDedicationAnchor` injection: every prompt
//    issued by the substrate is wrapped via
//    `tom_brain_shared.anchor.wrap(...)`. There is no path to bypass it."
//
// Scope of this test file:
//
//   - Pin the `AnchorRegistry` contract: `currentHash` is the
//     `sha256:<lowercase-hex>` of `AssistantDedicationAnchor.text`;
//     the hash format matches the per-call body hash format the
//     providers emit (B.14 / B.15 / B.16); the value is deterministic
//     across repeated calls; `currentVersion` re-exports
//     `AssistantDedicationAnchor.version`; `isCurrent(candidate)` is
//     equivalent to `candidate == currentHash`.
//   - Pin the `AnchorViolation` exception shape: implements
//     `Exception`; carries the expected / actual hashes plus the
//     provider / model / role identifiers; `toString` surfaces all
//     fields so a diagnostic dump is readable without re-reading the
//     report.
//   - Pin the `RoleTemplate.assemble` contract: the returned
//     `WirePrompt.body` starts with `AssistantDedicationAnchor.text`;
//     the `WirePrompt.anchorHash` equals `AnchorRegistry.currentHash`;
//     the `WirePrompt.roleId` equals the template's `id`; the
//     `WirePrompt.templateSha` is `null` (deferred to B.36 — see
//     Q-B.22.3); the body contains `PERSONA:` / `OBJECTIVE:` /
//     `INPUTS:` section markers; the `OUTPUT SCHEMA:` marker is
//     present iff the role declares an `outputSchema`; the inputs map
//     renders entries in declaration order or `(none)` when empty.
//   - Pin the cross-role invariant: every role in
//     `bootstrapRoleRegistry().templates` produces an anchored prompt
//     for both an empty inputs map and a populated inputs map.
//   - Pin the tampering vectors enumerated in
//     `assistant_dedication_anchor.dart`: inputs whose values
//     themselves contain the anchor text do not double-wrap; large
//     inputs maps render in order; whitespace-only values are
//     toString-rendered verbatim (the role layer does not trim);
//     `null` input values stringify via `Object.toString` as the
//     literal `null`.
//
// Out of scope (deferred to later steps):
//
//   - The provider-side anchor stamp on `LlmCallReport.anchorHash`.
//     Each provider already stamps `prompt.anchorHash` onto the
//     report (B.14 / B.15 / B.16); the cross-provider conformance
//     test at B.46 will verify every emitted report against
//     `AnchorRegistry.currentHash`.
//   - The runtime hook at the `TomBrainSubstrate` facade (B.40) that
//     raises `AnchorViolation` on every report whose `anchorHash`
//     does not equal `AnchorRegistry.currentHash`. The exception
//     type lands here; the hook lands at B.40.
//   - The `templateRef` git-sha field on `RoleTemplate` and the
//     populated `templateSha` on `WirePrompt`. Both deferred to
//     B.36 with the file-backed loader.

import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('AnchorRegistry', () {
    test('currentHash is sha256:<lowercase-hex> of the anchor text', () {
      final expected = sha256.convert(
        utf8.encode(AssistantDedicationAnchor.text),
      );
      expect(AnchorRegistry.currentHash, equals('sha256:$expected'));
    });

    test('currentHash starts with the sha256: prefix and matches the format '
        'providers emit', () {
      final hash = AnchorRegistry.currentHash;
      expect(hash, startsWith('sha256:'));
      // 64 lowercase hex chars after the prefix.
      final hex = hash.substring('sha256:'.length);
      expect(hex.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hex), isTrue,
          reason: 'hex digest must be lowercase, 64 chars, hex only');
    });

    test('currentHash is deterministic across calls (cache invariant)', () {
      final a = AnchorRegistry.currentHash;
      final b = AnchorRegistry.currentHash;
      final c = AnchorRegistry.currentHash;
      expect(a, equals(b));
      expect(b, equals(c));
      expect(identical(a, b), isTrue,
          reason: 'cached value should be returned by identity, not recomputed');
    });

    test('currentVersion re-exports AssistantDedicationAnchor.version', () {
      expect(
        AnchorRegistry.currentVersion,
        equals(AssistantDedicationAnchor.version),
      );
    });

    test('isCurrent returns true for the current hash', () {
      expect(AnchorRegistry.isCurrent(AnchorRegistry.currentHash), isTrue);
    });

    test('isCurrent returns false for any other string', () {
      expect(AnchorRegistry.isCurrent(''), isFalse);
      expect(AnchorRegistry.isCurrent('sha256:0'), isFalse);
      expect(
        AnchorRegistry.isCurrent('sha256:${'0' * 64}'),
        isFalse,
      );
      // A hash with the right shape but the wrong content.
      final wrong = sha256.convert(utf8.encode('not the anchor'));
      expect(
        AnchorRegistry.isCurrent('sha256:$wrong'),
        isFalse,
      );
    });
  });

  group('AnchorViolation', () {
    test('implements Exception and exposes all fields', () {
      const v = AnchorViolation(
        expected: 'sha256:aaa',
        actual: 'sha256:bbb',
        providerId: 'ollama',
        modelId: 'gemma3:27b',
        roleId: 'assistant_to_user',
      );
      expect(v, isA<Exception>());
      expect(v.expected, equals('sha256:aaa'));
      expect(v.actual, equals('sha256:bbb'));
      expect(v.providerId, equals('ollama'));
      expect(v.modelId, equals('gemma3:27b'));
      expect(v.roleId, equals('assistant_to_user'));
    });

    test('toString surfaces every field for diagnostic dumps', () {
      const v = AnchorViolation(
        expected: 'sha256:expected-hash',
        actual: 'sha256:actual-hash',
        providerId: 'openai_passthrough',
        modelId: 'gpt-4o-mini',
        roleId: 'evaluator',
      );
      final s = v.toString();
      expect(s, contains('AnchorViolation('));
      expect(s, contains('roleId: evaluator'));
      expect(s, contains('providerId: openai_passthrough'));
      expect(s, contains('modelId: gpt-4o-mini'));
      expect(s, contains('expected: sha256:expected-hash'));
      expect(s, contains('actual: sha256:actual-hash'));
    });
  });

  group('RoleTemplate.assemble', () {
    RoleTemplate makeRole({
      String id = 'r',
      String personaText = 'I am the role.',
      String objective = 'Do the role thing.',
      Set<AllowedAction> allowedActions = const {AllowedAction.llmCall},
      Map<String, Object?>? outputSchema,
    }) {
      return RoleTemplate(
        id: id,
        personaText: personaText,
        objective: objective,
        allowedActions: allowedActions,
        outputSchema: outputSchema,
      );
    }

    test('returned WirePrompt body starts with the anchor text', () {
      final r = makeRole();
      final p = r.assemble();
      expect(
        p.body.startsWith(AssistantDedicationAnchor.text),
        isTrue,
        reason: 'body must open with the anchor (Postulate 3, invariant 1)',
      );
    });

    test('returned WirePrompt anchorHash equals AnchorRegistry.currentHash', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.anchorHash, equals(AnchorRegistry.currentHash));
    });

    test('returned WirePrompt roleId equals the template id', () {
      final r = makeRole(id: 'analyser');
      final p = r.assemble();
      expect(p.roleId, equals('analyser'));
    });

    test('returned WirePrompt templateSha is null (deferred to B.36)', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.templateSha, isNull);
    });

    test('body contains PERSONA:, OBJECTIVE:, and INPUTS: section markers', () {
      final r = makeRole(
        personaText: 'PERSONA-MARKER',
        objective: 'OBJECTIVE-MARKER',
      );
      final p = r.assemble();
      expect(p.body, contains('PERSONA:'));
      expect(p.body, contains('PERSONA-MARKER'));
      expect(p.body, contains('OBJECTIVE:'));
      expect(p.body, contains('OBJECTIVE-MARKER'));
      expect(p.body, contains('INPUTS:'));
    });

    test('OUTPUT SCHEMA: marker is absent when outputSchema is null', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.body, isNot(contains('OUTPUT SCHEMA:')));
    });

    test('OUTPUT SCHEMA: marker is present when outputSchema is non-null', () {
      final r = makeRole(
        outputSchema: const <String, Object?>{'type': 'object'},
      );
      final p = r.assemble();
      expect(p.body, contains('OUTPUT SCHEMA:'));
    });

    test('OUTPUT SCHEMA: section embeds the actual schema JSON so the model '
        'uses the declared key names (not a dangling meta-reference)', () {
      // A role whose schema names a specific key (`questions`). A live model
      // can only emit that exact key if the schema itself is in the prompt —
      // the old "matching the schema declared on this role's outputSchema"
      // meta-reference left the model to guess (it returned `clarifying_
      // questions`, which then failed parsing).
      final r = makeRole(
        outputSchema: const <String, Object?>{
          'type': 'object',
          'required': <String>['questions'],
          'properties': <String, Object?>{
            'questions': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{'type': 'string'},
            },
          },
        },
      );
      final p = r.assemble();
      // The real schema is embedded verbatim (JSON-encoded), so the declared
      // key names reach the model.
      expect(p.body, contains('"questions"'));
      expect(p.body, contains('"required"'));
      // The old dangling meta-reference is gone.
      expect(
        p.body,
        isNot(contains("matching the schema declared on this role")),
      );
    });

    test('empty inputs renders the literal "(none)" placeholder', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.body, contains('INPUTS:'));
      expect(p.body, contains('(none)'));
    });

    test('non-empty inputs renders entries in declaration order', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'zeta': 'last',
        'alpha': 'first',
        'middle': 42,
      });
      // Insertion order is the contract (LinkedHashMap default).
      final body = p.body;
      final iZeta = body.indexOf('zeta: last');
      final iAlpha = body.indexOf('alpha: first');
      final iMiddle = body.indexOf('middle: 42');
      expect(iZeta, greaterThanOrEqualTo(0));
      expect(iAlpha, greaterThanOrEqualTo(0));
      expect(iMiddle, greaterThanOrEqualTo(0));
      expect(iZeta < iAlpha, isTrue,
          reason: 'zeta was declared first; should appear before alpha');
      expect(iAlpha < iMiddle, isTrue,
          reason: 'alpha was declared second; should appear before middle');
      // (none) must not appear when inputs is populated.
      expect(p.body, isNot(contains('(none)')));
    });
  });

  group('Anchor invariant across the bootstrap roster', () {
    test('every bootstrap role assembles an anchored prompt for empty inputs',
        () {
      final registry = bootstrapRoleRegistry();
      for (final template in registry.templates) {
        final p = template.assemble();
        expect(
          AssistantDedicationAnchor.containsAnchor(p.body),
          isTrue,
          reason: '${template.id} must produce an anchored body',
        );
        expect(
          p.body.startsWith(AssistantDedicationAnchor.text),
          isTrue,
          reason: '${template.id} body must START with the anchor',
        );
        expect(
          p.anchorHash,
          equals(AnchorRegistry.currentHash),
          reason: '${template.id} must stamp the current anchor hash',
        );
        expect(
          p.roleId,
          equals(template.id),
          reason: '${template.id} must stamp its own role id',
        );
      }
    });

    test(
        'every bootstrap role assembles an anchored prompt for populated inputs',
        () {
      final registry = bootstrapRoleRegistry();
      for (final template in registry.templates) {
        final p = template.assemble(inputs: <String, Object?>{
          'user_prompt': 'What is the capital of France?',
          'thinking_trail_summary': 'No prior context.',
        });
        expect(
          AssistantDedicationAnchor.containsAnchor(p.body),
          isTrue,
          reason: '${template.id} must produce an anchored body with inputs',
        );
        expect(
          p.body.startsWith(AssistantDedicationAnchor.text),
          isTrue,
          reason: '${template.id} body must START with the anchor with inputs',
        );
        expect(p.body, contains('user_prompt: What is the capital of France?'));
        expect(p.body, contains('thinking_trail_summary: No prior context.'));
      }
    });

    test('evaluator (the only role with outputSchema) gets the OUTPUT SCHEMA: '
        'marker', () {
      final registry = bootstrapRoleRegistry();
      final evaluator = registry.get('evaluator');
      final p = evaluator.assemble();
      expect(p.body, contains('OUTPUT SCHEMA:'));
    });

    test(
        'roles without outputSchema do not get the OUTPUT SCHEMA: marker', () {
      final registry = bootstrapRoleRegistry();
      for (final id in const [
        'assistant_to_user',
        'analyser',
        'sub_thinker',
        'recaller',
        'researcher',
      ]) {
        final t = registry.get(id);
        expect(t.outputSchema, isNull,
            reason: '$id should not declare an outputSchema');
        final p = t.assemble();
        expect(p.body, isNot(contains('OUTPUT SCHEMA:')),
            reason: '$id assembled body should not carry the marker');
      }
    });
  });

  group('Tampering vectors', () {
    RoleTemplate makeRole() => RoleTemplate(
          id: 'tamper_test',
          personaText: 'persona',
          objective: 'objective',
          allowedActions: const {AllowedAction.llmCall},
        );

    test('input value containing the anchor text does not double-wrap the body',
        () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'pre_anchored': AssistantDedicationAnchor.text,
      });
      // The anchor appears at the top (from `wrap`) and once as the
      // input value — total two occurrences, NOT three.
      final occurrences = AssistantDedicationAnchor.text.allMatches(p.body).length;
      expect(occurrences, equals(2),
          reason: 'wrap must be idempotent at the boundary; the input value '
              'occurrence is the user-supplied second occurrence');
      // The body still starts with the anchor (the wrap-side occurrence
      // comes first, ahead of any input that contains it).
      expect(p.body.startsWith(AssistantDedicationAnchor.text), isTrue);
      // The anchor hash is still the current one.
      expect(p.anchorHash, equals(AnchorRegistry.currentHash));
    });

    test('large inputs map renders all entries in order', () {
      final r = makeRole();
      final inputs = <String, Object?>{
        for (var i = 0; i < 50; i++) 'k$i': 'v$i',
      };
      final p = r.assemble(inputs: inputs);
      for (var i = 0; i < 50; i++) {
        expect(p.body, contains('k$i: v$i'));
      }
      // The body still opens with the anchor.
      expect(p.body.startsWith(AssistantDedicationAnchor.text), isTrue);
    });

    test('whitespace-only input value is rendered verbatim (role layer does '
        'not trim values)', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'whitespace': '   ',
      });
      expect(p.body, contains('whitespace:    '),
          reason: 'value is rendered as-is, including leading spaces');
    });

    test('null input value renders as the literal "null" via toString', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'maybe_null': null,
      });
      expect(p.body, contains('maybe_null: null'));
    });

    test('empty inputs map and the no-arg call produce identical bodies', () {
      final r = makeRole();
      final p1 = r.assemble();
      final p2 = r.assemble(inputs: const <String, Object?>{});
      expect(p1.body, equals(p2.body));
      expect(p1.anchorHash, equals(p2.anchorHash));
    });

    test('repeated assemble calls produce stable bodies and identical hashes',
        () {
      final r = makeRole();
      final p1 = r.assemble(inputs: const {'a': 1, 'b': 2});
      final p2 = r.assemble(inputs: const {'a': 1, 'b': 2});
      expect(p1.body, equals(p2.body));
      expect(p1.anchorHash, equals(p2.anchorHash));
      expect(p1.roleId, equals(p2.roleId));
    });
  });

  group('Top-level barrel re-exports', () {
    test('AnchorRegistry is exported from package:tom_brain_substrate', () {
      // If the import at the top of this file compiles, the type is
      // exported. The body-of-the-test assertion below makes the
      // re-export visible to the test reporter.
      expect(AnchorRegistry.currentHash, isNotEmpty);
    });

    test('AnchorViolation is exported from package:tom_brain_substrate', () {
      const v = AnchorViolation(
        expected: 'a',
        actual: 'b',
        providerId: 'p',
        modelId: 'm',
        roleId: 'r',
      );
      expect(v, isA<Exception>());
    });
  });
}
