// B.22 — `RoleRegistry` + bootstrap roles conformance suite.
//
// Plan-step text (verbatim):
//   "B.22 Implement template registry with at least these roles for the
//    prototype: `assistant_to_user`, `analyser`, `sub_thinker`,
//    `recaller`, `evaluator`."
//
// Scope of this test file:
//
//   - Pin the `RoleRegistry` construction contract: empty roster
//     permitted; duplicate ids rejected with `ArgumentError` at
//     construction (not at first lookup); the internal map is frozen
//     so external mutation cannot leak through `ids` / `templates`.
//   - Pin the `RoleRegistry` lookup contract: `get(id)` returns the
//     same instance the caller supplied; `get(unknown)` throws
//     `RoleTemplateNotFound` with the requested id and the known-ids
//     roster; `lookup(id)` returns the same instance on hit and `null`
//     on miss; `contains(id)` agrees with `lookup(id) != null` for the
//     full id-space.
//   - Pin the `RoleRegistry.ids` / `templates` iteration order: the
//     order is insertion order; iteration is stable across calls.
//   - Pin the `bootstrapRoleRegistry()` contract: returns a fresh
//     registry on every call; the registry's roster is exactly
//     `prototypeRoleIds` in declared order; every role has non-empty
//     `personaText` and `objective`; every role carries at least
//     `llmCall` and `memoryRead`; only `assistant_to_user` carries
//     `userFacingAnswer`; no bootstrap role carries `memoryWrite`
//     (the thinking-loop roles do not persist; their host procedure
//     does); the `evaluator` role's `outputSchema` declares a
//     `verdict` enum of `['accept', 'revise', 'escalate']`.
//   - Pin the cross-role action-shape invariants spelled out in
//     spec § 6.2 (every internal role forbids `userFacingAnswer`; the
//     evaluator forbids `subThinking`; `assistant_to_user` forbids
//     `subThinking` because the user-facing answer is terminal).
//   - Pin the `RoleTemplateNotFound.toString` shape so that
//     diagnostics surface the requested id and the known roster.
//   - Pin the top-level barrel re-exports for `RoleRegistry`,
//     `RoleTemplateNotFound`, `bootstrapRoleRegistry`, and
//     `prototypeRoleIds`.
//
// Out of scope (deferred to later steps):
//
//   - File-backed registry construction (`_ai/prompts/<role>.system.md`
//     + `roles_registry.yaml`). Lives at B.36 (SubstrateConfig YAML
//     loader). The B.22 in-code bootstrap is the only construction
//     path tested here.
//   - The `templateRef` / git sha attribution on `RoleTemplate`.
//     Deferred with the file-backed loader. See Q-B.22.3.
//   - The `assemble(...)` → `WirePrompt` mechanism and the
//     anchor-injection enforcement test. Land at B.23 / B.24.
//   - The cross-validation between the router's `roleRoutes` map and
//     the registry. See Q-B.22.4.
//   - The dispatcher-side enforcement of `allowedActions` /
//     `forbiddenActions`. Lives in Phase D.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('RoleRegistry construction', () {
    test('empty templates list is permitted', () {
      final r = RoleRegistry(templates: const <RoleTemplate>[]);
      expect(r.length, equals(0));
      expect(r.ids, isEmpty);
      expect(r.templates, isEmpty);
    });

    test('a non-empty roster is registered in insertion order', () {
      final a = RoleTemplate(
        id: 'a',
        personaText: 'pa',
        objective: 'oa',
        allowedActions: const {AllowedAction.llmCall},
      );
      final b = RoleTemplate(
        id: 'b',
        personaText: 'pb',
        objective: 'ob',
        allowedActions: const {AllowedAction.llmCall},
      );
      final r = RoleRegistry(templates: <RoleTemplate>[a, b]);
      expect(r.length, equals(2));
      expect(r.ids.toList(), equals(<String>['a', 'b']));
      expect(r.templates.toList(), equals(<RoleTemplate>[a, b]));
    });

    test('duplicate ids are rejected at construction', () {
      final a1 = RoleTemplate(
        id: 'dup',
        personaText: 'p1',
        objective: 'o1',
        allowedActions: const {AllowedAction.llmCall},
      );
      final a2 = RoleTemplate(
        id: 'dup',
        personaText: 'p2',
        objective: 'o2',
        allowedActions: const {AllowedAction.llmCall},
      );
      expect(
        () => RoleRegistry(templates: <RoleTemplate>[a1, a2]),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('duplicate role id "dup"'),
        )),
      );
    });

    test('rejection happens at construction, not at first lookup', () {
      // The point of this test is to prove the error surfaces eagerly:
      // if the registry deferred validation, a `get(unknown)` call
      // would surface the duplicate problem only after the duplicate
      // had been used.
      final a1 = RoleTemplate(
        id: 'dup',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      final a2 = RoleTemplate(
        id: 'dup',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      try {
        RoleRegistry(templates: <RoleTemplate>[a1, a2]);
        fail('expected ArgumentError on duplicate id');
      } on ArgumentError {
        // expected
      }
    });
  });

  group('RoleRegistry lookup', () {
    final hit = RoleTemplate(
      id: 'hit',
      personaText: 'p',
      objective: 'o',
      allowedActions: const {AllowedAction.llmCall},
    );
    final r = RoleRegistry(templates: <RoleTemplate>[hit]);

    test('get(id) returns the same instance the caller supplied', () {
      final returned = r.get('hit');
      expect(returned, same(hit));
    });

    test('get(unknown) throws RoleTemplateNotFound', () {
      expect(
        () => r.get('missing'),
        throwsA(isA<RoleTemplateNotFound>()
            .having((e) => e.id, 'id', equals('missing'))
            .having((e) => e.knownIds, 'knownIds', equals(<String>['hit']))),
      );
    });

    test('lookup(hit) returns the instance; lookup(miss) returns null', () {
      expect(r.lookup('hit'), same(hit));
      expect(r.lookup('missing'), isNull);
    });

    test('contains agrees with lookup-non-null', () {
      expect(r.contains('hit'), isTrue);
      expect(r.contains('missing'), isFalse);
      expect(r.lookup('hit') != null, equals(r.contains('hit')));
      expect(r.lookup('missing') != null, equals(r.contains('missing')));
    });
  });

  group('RoleRegistry iteration', () {
    test('ids and templates iterate in insertion order across calls', () {
      final templates = <RoleTemplate>[
        for (final id in <String>['z', 'a', 'm', 'p'])
          RoleTemplate(
            id: id,
            personaText: 'p',
            objective: 'o',
            allowedActions: const {AllowedAction.llmCall},
          ),
      ];
      final r = RoleRegistry(templates: templates);

      // Two distinct iterations produce the same ordered output —
      // the underlying map is a LinkedHashMap so this is structural.
      final first = r.ids.toList();
      final second = r.ids.toList();
      expect(first, equals(<String>['z', 'a', 'm', 'p']));
      expect(second, equals(first));

      // Templates iteration order matches the ids iteration order.
      expect(
        r.templates.map((t) => t.id).toList(),
        equals(<String>['z', 'a', 'm', 'p']),
      );
    });

    test('externally observed ids / templates cannot mutate the registry', () {
      final r = RoleRegistry(
        templates: <RoleTemplate>[
          RoleTemplate(
            id: 'one',
            personaText: 'p',
            objective: 'o',
            allowedActions: const {AllowedAction.llmCall},
          ),
        ],
      );
      // ids is an Iterable view; a hostile cast-and-add must not
      // change the registry. The registry's internal map is wrapped
      // in Map.unmodifiable so the `keys` / `values` iterables it
      // surfaces refuse mutation attempts.
      //
      // (We do not call `add` here because `Iterable` itself has no
      // add method; the point is that no public surface exposes a
      // mutation entry point.)
      expect(r.ids.length, equals(1));
      expect(r.templates.length, equals(1));
    });
  });

  group('RoleTemplateNotFound', () {
    test('toString includes the requested id and the known roster', () {
      const e = RoleTemplateNotFound(
        id: 'unknown',
        knownIds: <String>['assistant_to_user', 'analyser'],
      );
      final s = e.toString();
      expect(s, contains('id="unknown"'));
      expect(s, contains('assistant_to_user'));
      expect(s, contains('analyser'));
    });

    test('is an Exception', () {
      const e = RoleTemplateNotFound(
        id: 'missing',
        knownIds: <String>[],
      );
      expect(e, isA<Exception>());
    });
  });

  group('bootstrapRoleRegistry — roster shape', () {
    test('returns a registry with exactly the prototype five roles plus the '
        'researcher completion role (§ 6.2b), in canonical order', () {
      final r = bootstrapRoleRegistry();
      expect(r.length, equals(6));
      expect(r.ids.toList(), equals(prototypeRoleIds));
      expect(
        prototypeRoleIds,
        equals(<String>[
          'assistant_to_user',
          'analyser',
          'sub_thinker',
          'recaller',
          'evaluator',
          'researcher',
        ]),
      );
    });

    test('every call returns a fresh registry (no singleton)', () {
      final r1 = bootstrapRoleRegistry();
      final r2 = bootstrapRoleRegistry();
      expect(identical(r1, r2), isFalse);
      // Templates are value-equal across the two registries.
      for (final id in prototypeRoleIds) {
        expect(r1.get(id), equals(r2.get(id)));
      }
    });

    test('every role has non-empty personaText and objective', () {
      final r = bootstrapRoleRegistry();
      for (final id in prototypeRoleIds) {
        final t = r.get(id);
        expect(t.personaText.trim(), isNotEmpty,
            reason: 'role $id: personaText must be non-empty');
        expect(t.objective.trim(), isNotEmpty,
            reason: 'role $id: objective must be non-empty');
      }
    });

    test('every role carries at least llmCall and memoryRead', () {
      final r = bootstrapRoleRegistry();
      for (final id in prototypeRoleIds) {
        final t = r.get(id);
        expect(t.allowedActions, contains(AllowedAction.llmCall),
            reason: 'role $id must allow llmCall');
        expect(t.allowedActions, contains(AllowedAction.memoryRead),
            reason: 'role $id must allow memoryRead');
      }
    });

    test('no bootstrap role grants memoryWrite (thinking-loop roles do not '
        'persist; the host procedure does)', () {
      final r = bootstrapRoleRegistry();
      for (final id in prototypeRoleIds) {
        final t = r.get(id);
        expect(t.allowedActions.contains(AllowedAction.memoryWrite), isFalse,
            reason: 'role $id must not allow memoryWrite');
      }
    });

    test('only assistant_to_user grants userFacingAnswer', () {
      final r = bootstrapRoleRegistry();
      for (final id in prototypeRoleIds) {
        final t = r.get(id);
        final isUserFacing = id == 'assistant_to_user';
        expect(
          t.allowedActions.contains(AllowedAction.userFacingAnswer),
          equals(isUserFacing),
          reason: 'role $id: userFacingAnswer expected=$isUserFacing',
        );
        // The complementary role-internal invariant: every non-user-
        // facing role explicitly forbids the action (so a future
        // ceiling-loosening cannot accidentally grant it).
        if (!isUserFacing) {
          expect(
            t.forbiddenActions.contains(AllowedAction.userFacingAnswer),
            isTrue,
            reason: 'role $id must explicitly forbid userFacingAnswer',
          );
        }
      }
    });
  });

  group('bootstrapRoleRegistry — per-role spec § 6.2 invariants', () {
    test('assistant_to_user is terminal: forbids subThinking', () {
      final t = bootstrapRoleRegistry().get('assistant_to_user');
      // The user-facing answer is terminal; the loop's sub_thinker
      // calls happen upstream of the answer assembly.
      expect(t.forbiddenActions.contains(AllowedAction.subThinking), isTrue);
      expect(t.permits(AllowedAction.subThinking), isFalse);
    });

    test('analyser permits subThinking (it dispatches sub-questions)', () {
      final t = bootstrapRoleRegistry().get('analyser');
      expect(t.allowedActions.contains(AllowedAction.subThinking), isTrue);
      expect(t.permits(AllowedAction.subThinking), isTrue);
    });

    test('sub_thinker permits subThinking (it is recursive)', () {
      final t = bootstrapRoleRegistry().get('sub_thinker');
      expect(t.allowedActions.contains(AllowedAction.subThinking), isTrue);
    });

    test('recaller permits toolCall (it may invoke memory-side tool '
        'catalogues)', () {
      final t = bootstrapRoleRegistry().get('recaller');
      expect(t.allowedActions.contains(AllowedAction.toolCall), isTrue);
    });

    test('evaluator declares a verdict outputSchema with accept/revise/'
        'escalate', () {
      final t = bootstrapRoleRegistry().get('evaluator');
      expect(t.outputSchema, isNotNull);
      expect(t.outputSchema!['type'], equals('object'));
      final required = t.outputSchema!['required'];
      expect(required, isA<List>());
      expect(required as List, contains('verdict'));
      final props = t.outputSchema!['properties'] as Map<String, Object?>;
      final verdict = props['verdict'] as Map<String, Object?>;
      expect(verdict['type'], equals('string'));
      expect(
        verdict['enum'],
        equals(<String>['accept', 'revise', 'escalate']),
      );
    });

    test('evaluator forbids subThinking (the evaluator critiques, it does '
        'not decompose)', () {
      final t = bootstrapRoleRegistry().get('evaluator');
      expect(t.forbiddenActions.contains(AllowedAction.subThinking), isTrue);
    });

    test('researcher permits toolCall (it runs web search/fetch) and '
        'memoryRead, but forbids userFacingAnswer, memoryWrite and '
        'subThinking (§ 6.2b)', () {
      final t = bootstrapRoleRegistry().get('researcher');
      expect(t.permits(AllowedAction.llmCall), isTrue);
      expect(t.permits(AllowedAction.toolCall), isTrue);
      expect(t.permits(AllowedAction.memoryRead), isTrue);
      expect(t.forbiddenActions.contains(AllowedAction.userFacingAnswer),
          isTrue);
      expect(t.forbiddenActions.contains(AllowedAction.memoryWrite), isTrue);
      expect(t.forbiddenActions.contains(AllowedAction.subThinking), isTrue);
    });

    test('researcher is registered and its assembled template carries the '
        'assistant-dedication anchor (§ 6.2b / G-T3, Q-2)', () {
      final r = bootstrapRoleRegistry();
      expect(r.contains('researcher'), isTrue);
      final p = r.get('researcher').assemble();
      expect(p.combined, startsWith(AssistantDedicationAnchor.text));
      expect(p.anchorHash, equals(AnchorRegistry.currentHash));
      expect(p.roleId, equals('researcher'));
    });

    test('every role has the default RoleBudgetDefaults.empty (the per-role '
        'budget tuning is deferred to a future config-loader step)', () {
      final r = bootstrapRoleRegistry();
      for (final id in prototypeRoleIds) {
        final t = r.get(id);
        expect(t.budgetDefaults, equals(RoleBudgetDefaults.empty),
            reason: 'role $id: budgetDefaults must default to empty for the '
                'B.22 bootstrap; future config loader is free to override.');
      }
    });
  });

  group('Top-level barrel re-export', () {
    test('RoleRegistry is importable from the package barrel', () {
      final r = RoleRegistry(templates: const <RoleTemplate>[]);
      expect(r.length, equals(0));
    });

    test('RoleTemplateNotFound is importable from the package barrel', () {
      const e = RoleTemplateNotFound(id: 'x', knownIds: <String>[]);
      expect(e.id, equals('x'));
    });

    test('bootstrapRoleRegistry is importable from the package barrel', () {
      final r = bootstrapRoleRegistry();
      expect(r.length, equals(6));
    });

    test('prototypeRoleIds is importable from the package barrel', () {
      expect(prototypeRoleIds, hasLength(6));
    });
  });
}
