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
//   - Pin the `RoleTemplate.assemble` contract (two-channel split,
//     prompt-restructuring plan step 4): the returned
//     `WirePrompt.system` starts with `AssistantDedicationAnchor.text`
//     even though the system scaffold omits the anchor; the
//     `WirePrompt.anchorHash` equals `AnchorRegistry.currentHash`;
//     the `WirePrompt.roleId` equals the template's `id`; the
//     `WirePrompt.templateSha` is `null` (deferred to the file-backed
//     loader — see Q-B.22.3); the `system` channel carries the
//     `PERSONA:` / `OBJECTIVE:` section markers and the `OUTPUT SCHEMA:`
//     marker iff the role declares an `outputSchema`; the `user`
//     channel renders the inputs map as `key: value` lines in
//     declaration order, and is empty when `inputs` is empty.
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

    test('returned WirePrompt system starts with the anchor text', () {
      final r = makeRole();
      final p = r.assemble();
      expect(
        p.system.startsWith(AssistantDedicationAnchor.text),
        isTrue,
        reason: 'the system channel must open with the anchor '
            '(Postulate 3, invariant 1)',
      );
      // ...and so does the combined view, since system leads.
      expect(
        p.combined.startsWith(AssistantDedicationAnchor.text),
        isTrue,
      );
    });

    test('system begins with the anchor even though the scaffold omits it '
        '(ensurePrefix prepends, plan step 4)', () {
      // The in-code system scaffold (and the Phase-3 `<role>.system.md`
      // template that replaces it) never emits the anchor itself —
      // `assemble` guarantees the lead via `ensurePrefix`. Proven by
      // stripping the anchor prefix and showing the remainder is the bare
      // PERSONA scaffold, not a second anchor.
      final r = makeRole(personaText: 'SCAFFOLD-PERSONA');
      final p = r.assemble();
      expect(p.system.startsWith(AssistantDedicationAnchor.text), isTrue);
      final afterAnchor =
          p.system.substring(AssistantDedicationAnchor.text.length);
      expect(afterAnchor, startsWith('PERSONA:'),
          reason: 'the scaffold leads with PERSONA:, not another anchor block');
      expect(afterAnchor, contains('SCAFFOLD-PERSONA'));
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

    test('system channel carries PERSONA: / OBJECTIVE: markers; there is no '
        'INPUTS: scaffolding (plan step 4)', () {
      final r = makeRole(
        personaText: 'PERSONA-MARKER',
        objective: 'OBJECTIVE-MARKER',
      );
      final p = r.assemble();
      // Persona/objective bind from the registry into the system channel.
      expect(p.system, contains('PERSONA:'));
      expect(p.system, contains('PERSONA-MARKER'));
      expect(p.system, contains('OBJECTIVE:'));
      expect(p.system, contains('OBJECTIVE-MARKER'));
      // The old single-body `INPUTS:` header is gone — inputs live in the
      // user channel, rendered as bare `key: value` lines.
      expect(p.combined, isNot(contains('INPUTS:')));
    });

    test('OUTPUT SCHEMA: marker is absent when outputSchema is null', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.combined, isNot(contains('OUTPUT SCHEMA:')));
    });

    test('OUTPUT SCHEMA: marker is present when outputSchema is non-null', () {
      final r = makeRole(
        outputSchema: const <String, Object?>{'type': 'object'},
      );
      final p = r.assemble();
      expect(p.combined, contains('OUTPUT SCHEMA:'));
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
      expect(p.combined, contains('"questions"'));
      expect(p.combined, contains('"required"'));
      // The old dangling meta-reference is gone.
      expect(
        p.combined,
        isNot(contains("matching the schema declared on this role")),
      );
    });

    test('empty inputs produces an empty user half (no "(none)" scaffolding, '
        'plan step 4)', () {
      final r = makeRole();
      final p = r.assemble();
      expect(p.user, isEmpty,
          reason: 'an empty user half is legal for a system-only prompt');
      // The old single-body `(none)` placeholder is gone.
      expect(p.combined, isNot(contains('(none)')));
      // combined collapses to just the system channel when user is empty.
      expect(p.combined, equals(p.system));
    });

    test('non-empty inputs render as key: value lines in the user channel, in '
        'declaration order', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'zeta': 'last',
        'alpha': 'first',
        'middle': 42,
      });
      // Insertion order is the contract (LinkedHashMap default). The inputs
      // land in the user channel, not the system channel.
      final user = p.user;
      final iZeta = user.indexOf('zeta: last');
      final iAlpha = user.indexOf('alpha: first');
      final iMiddle = user.indexOf('middle: 42');
      expect(iZeta, greaterThanOrEqualTo(0));
      expect(iAlpha, greaterThanOrEqualTo(0));
      expect(iMiddle, greaterThanOrEqualTo(0));
      expect(iZeta < iAlpha, isTrue,
          reason: 'zeta was declared first; should appear before alpha');
      expect(iAlpha < iMiddle, isTrue,
          reason: 'alpha was declared second; should appear before middle');
      // The system channel carries only the framing, not the inputs.
      expect(p.system, isNot(contains('zeta: last')));
    });
  });

  group('Anchor invariant across the bootstrap roster', () {
    test('every bootstrap role assembles an anchored prompt for empty inputs',
        () {
      final registry = bootstrapRoleRegistry();
      for (final template in registry.templates) {
        final p = template.assemble();
        expect(
          AssistantDedicationAnchor.containsAnchor(p.combined),
          isTrue,
          reason: '${template.id} must produce an anchored body',
        );
        expect(
          p.combined.startsWith(AssistantDedicationAnchor.text),
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
          AssistantDedicationAnchor.containsAnchor(p.combined),
          isTrue,
          reason: '${template.id} must produce an anchored body with inputs',
        );
        expect(
          p.combined.startsWith(AssistantDedicationAnchor.text),
          isTrue,
          reason: '${template.id} body must START with the anchor with inputs',
        );
        expect(p.combined, contains('user_prompt: What is the capital of France?'));
        expect(p.combined, contains('thinking_trail_summary: No prior context.'));
      }
    });

    test('evaluator (the only role with outputSchema) gets the OUTPUT SCHEMA: '
        'marker', () {
      final registry = bootstrapRoleRegistry();
      final evaluator = registry.get('evaluator');
      final p = evaluator.assemble();
      expect(p.combined, contains('OUTPUT SCHEMA:'));
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
        expect(p.combined, isNot(contains('OUTPUT SCHEMA:')),
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
      final occurrences = AssistantDedicationAnchor.text.allMatches(p.combined).length;
      expect(occurrences, equals(2),
          reason: 'wrap must be idempotent at the boundary; the input value '
              'occurrence is the user-supplied second occurrence');
      // The body still starts with the anchor (the wrap-side occurrence
      // comes first, ahead of any input that contains it).
      expect(p.combined.startsWith(AssistantDedicationAnchor.text), isTrue);
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
        expect(p.combined, contains('k$i: v$i'));
      }
      // The body still opens with the anchor.
      expect(p.combined.startsWith(AssistantDedicationAnchor.text), isTrue);
    });

    test('whitespace-only input value is rendered verbatim (role layer does '
        'not trim values)', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'whitespace': '   ',
      });
      expect(p.combined, contains('whitespace:    '),
          reason: 'value is rendered as-is, including leading spaces');
    });

    test('null input value renders as the literal "null" via toString', () {
      final r = makeRole();
      final p = r.assemble(inputs: <String, Object?>{
        'maybe_null': null,
      });
      expect(p.combined, contains('maybe_null: null'));
    });

    test('empty inputs map and the no-arg call produce identical bodies', () {
      final r = makeRole();
      final p1 = r.assemble();
      final p2 = r.assemble(inputs: const <String, Object?>{});
      expect(p1.combined, equals(p2.combined));
      expect(p1.anchorHash, equals(p2.anchorHash));
    });

    test('repeated assemble calls produce stable bodies and identical hashes',
        () {
      final r = makeRole();
      final p1 = r.assemble(inputs: const {'a': 1, 'b': 2});
      final p2 = r.assemble(inputs: const {'a': 1, 'b': 2});
      expect(p1.combined, equals(p2.combined));
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
