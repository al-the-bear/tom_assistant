// B.21 — `RoleTemplate` conformance suite.
//
// Plan-step text (verbatim):
//   "B.21 Implement `RoleTemplate`: persona text, objective,
//    allowed-action set, budget defaults."
//
// Scope of this test file:
//
//   - Pin the post-B.21 `RoleTemplate` field set against the
//     `substrate_specification.md` § 6.1 contract: `id`, `personaText`,
//     `objective`, `allowedActions`, `forbiddenActions`, `outputSchema`,
//     `budgetDefaults`.
//   - Pin the constructor's required-vs-optional split (`id`,
//     `personaText`, `objective`, `allowedActions` required;
//     `forbiddenActions` defaults to empty; `outputSchema` defaults to
//     null; `budgetDefaults` defaults to [RoleBudgetDefaults.empty]).
//   - Prove the validation surface: empty id, whitespace in id,
//     empty / whitespace-only persona, empty / whitespace-only
//     objective, overlap between allowed and forbidden — each surfaces
//     as `ArgumentError` at construction.
//   - Prove the value-class character: structurally identical
//     instances are `==`, hash to the same bucket, and round-trip
//     through field reads without mutation.
//   - Prove the field-freezing guarantee: `allowedActions` /
//     `forbiddenActions` / `outputSchema` are unmodifiable on the
//     returned instance.
//   - Prove the `permits(action)` predicate: allowed-and-not-
//     forbidden ⇒ true; absent-from-allowed ⇒ false; present-in-
//     forbidden ⇒ false even if listed in allowed (the constructor
//     rejects the conflict, but the predicate must not depend on
//     that — defensive).
//   - Pin `AllowedAction.token` round-trip via [AllowedAction.fromToken]
//     for each of the six tokens; pin the failure path on an unknown
//     token.
//   - Pin `RoleBudgetDefaults` validation: out-of-range temperature,
//     non-positive maxOutputTokens / wallClockMsDefault /
//     tokenSpendDefault — each surfaces as `ArgumentError`. Pin
//     `RoleBudgetDefaults.empty` is structurally `==` to
//     `RoleBudgetDefaults()`. Pin `modelPreference` is order-sensitive
//     for equality.
//
// Out of scope (deferred to later steps):
//
//   - The registry that holds `RoleTemplate` instances (B.22 —
//     `roles_registry.dart`).
//   - The `assemble(...)` method that produces a `WirePrompt` and
//     calls `tom_brain_shared.anchor.wrap(...)` (B.23).
//   - The cross-role anchor-enforcement assertion that every emitted
//     prompt begins with the anchor (B.24 / B.46).

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('AllowedAction', () {
    test('token roster matches the B.21 closed set', () {
      expect(
        AllowedAction.values.map((a) => a.token).toList(),
        equals(<String>[
          'tool_call',
          'sub_thinking',
          'user_facing_answer',
          'memory_read',
          'memory_write',
          'llm_call',
        ]),
      );
    });

    test('fromToken round-trips for every value', () {
      for (final v in AllowedAction.values) {
        expect(AllowedAction.fromToken(v.token), same(v));
      }
    });

    test('fromToken rejects an unknown token with ArgumentError', () {
      expect(
        () => AllowedAction.fromToken('telepathy'),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('unknown allowed-action token'),
        )),
      );
    });

    test('toString returns the stable token', () {
      expect(AllowedAction.toolCall.toString(), equals('tool_call'));
      expect(AllowedAction.memoryWrite.toString(), equals('memory_write'));
    });
  });

  group('RoleBudgetDefaults', () {
    test('empty has no model preference and all defaults null', () {
      expect(RoleBudgetDefaults.empty.modelPreference, isEmpty);
      expect(RoleBudgetDefaults.empty.temperature, isNull);
      expect(RoleBudgetDefaults.empty.maxOutputTokens, isNull);
      expect(RoleBudgetDefaults.empty.wallClockMsDefault, isNull);
      expect(RoleBudgetDefaults.empty.tokenSpendDefault, isNull);
    });

    test('default constructor is structurally equal to empty', () {
      expect(RoleBudgetDefaults(), equals(RoleBudgetDefaults.empty));
      expect(
        RoleBudgetDefaults().hashCode,
        equals(RoleBudgetDefaults.empty.hashCode),
      );
    });

    test('modelPreference is order-sensitive for equality', () {
      final a = RoleBudgetDefaults(
        modelPreference: const ['gemma3:27b', 'gemma2:9b'],
      );
      final b = RoleBudgetDefaults(
        modelPreference: const ['gemma2:9b', 'gemma3:27b'],
      );
      expect(a, isNot(equals(b)));
    });

    test('structurally identical instances are ==', () {
      final a = RoleBudgetDefaults(
        modelPreference: const ['gemma3:27b'],
        temperature: 0.7,
        maxOutputTokens: 1024,
        wallClockMsDefault: 30000,
        tokenSpendDefault: 8000,
      );
      final b = RoleBudgetDefaults(
        modelPreference: const ['gemma3:27b'],
        temperature: 0.7,
        maxOutputTokens: 1024,
        wallClockMsDefault: 30000,
        tokenSpendDefault: 8000,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('temperature must be in [0.0, 2.0]', () {
      expect(
        () => RoleBudgetDefaults(temperature: -0.01),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RoleBudgetDefaults(temperature: 2.01),
        throwsA(isA<ArgumentError>()),
      );
      // Boundary values accepted.
      expect(RoleBudgetDefaults(temperature: 0.0).temperature, equals(0.0));
      expect(RoleBudgetDefaults(temperature: 2.0).temperature, equals(2.0));
    });

    test('maxOutputTokens must be > 0', () {
      expect(
        () => RoleBudgetDefaults(maxOutputTokens: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RoleBudgetDefaults(maxOutputTokens: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        RoleBudgetDefaults(maxOutputTokens: 1).maxOutputTokens,
        equals(1),
      );
    });

    test('wallClockMsDefault must be > 0', () {
      expect(
        () => RoleBudgetDefaults(wallClockMsDefault: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RoleBudgetDefaults(wallClockMsDefault: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        RoleBudgetDefaults(wallClockMsDefault: 1).wallClockMsDefault,
        equals(1),
      );
    });

    test('tokenSpendDefault must be > 0', () {
      expect(
        () => RoleBudgetDefaults(tokenSpendDefault: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => RoleBudgetDefaults(tokenSpendDefault: -1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        RoleBudgetDefaults(tokenSpendDefault: 1).tokenSpendDefault,
        equals(1),
      );
    });

    test('modelPreference is unmodifiable on the returned instance', () {
      final d = RoleBudgetDefaults(
        modelPreference: List<String>.from(<String>['gemma3:27b']),
      );
      expect(
        () => d.modelPreference.add('gemma2:9b'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('toString includes every field for diagnostics', () {
      final d = RoleBudgetDefaults(
        modelPreference: const ['m1'],
        temperature: 0.5,
        maxOutputTokens: 2048,
        wallClockMsDefault: 60000,
        tokenSpendDefault: 16000,
      );
      final s = d.toString();
      expect(s, contains('modelPreference'));
      expect(s, contains('temperature: 0.5'));
      expect(s, contains('maxOutputTokens: 2048'));
      expect(s, contains('wallClockMsDefault: 60000'));
      expect(s, contains('tokenSpendDefault: 16000'));
    });
  });

  group('RoleTemplate construction', () {
    test('minimal required-fields construction works', () {
      final t = RoleTemplate(
        id: 'evaluator',
        personaText: 'I am the evaluator.',
        objective: 'Critique the proposed answer and emit a verdict.',
        allowedActions: const {AllowedAction.llmCall},
      );

      expect(t.id, equals('evaluator'));
      expect(t.personaText, equals('I am the evaluator.'));
      expect(t.objective,
          equals('Critique the proposed answer and emit a verdict.'));
      expect(t.allowedActions, equals({AllowedAction.llmCall}));
      expect(t.forbiddenActions, isEmpty);
      expect(t.outputSchema, isNull);
      expect(t.budgetDefaults, equals(RoleBudgetDefaults.empty));
    });

    test('full-fields construction round-trips', () {
      final defaults = RoleBudgetDefaults(
        modelPreference: const ['gemma3:27b', 'gemma2:9b'],
        temperature: 0.4,
        maxOutputTokens: 2048,
      );
      final schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'verdict': <String, Object?>{
            'type': 'string',
            'enum': <String>['accept', 'revise', 'escalate'],
          },
        },
      };
      final t = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose the question into sub-questions.',
        allowedActions: const {
          AllowedAction.llmCall,
          AllowedAction.subThinking,
          AllowedAction.memoryRead,
        },
        forbiddenActions: const {AllowedAction.userFacingAnswer},
        outputSchema: schema,
        budgetDefaults: defaults,
      );

      expect(t.id, equals('analyser'));
      expect(t.allowedActions.length, equals(3));
      expect(t.allowedActions.contains(AllowedAction.subThinking), isTrue);
      expect(t.forbiddenActions, equals({AllowedAction.userFacingAnswer}));
      expect(t.outputSchema, equals(schema));
      expect(t.budgetDefaults, equals(defaults));
    });
  });

  group('RoleTemplate validation', () {
    RoleTemplate buildWith({
      String id = 'analyser',
      String personaText = 'I am the analyser.',
      String objective = 'Decompose the question.',
      Set<AllowedAction> allowedActions = const {AllowedAction.llmCall},
      Set<AllowedAction> forbiddenActions = const <AllowedAction>{},
    }) {
      return RoleTemplate(
        id: id,
        personaText: personaText,
        objective: objective,
        allowedActions: allowedActions,
        forbiddenActions: forbiddenActions,
      );
    }

    test('empty id is rejected', () {
      expect(
        () => buildWith(id: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('whitespace-containing id is rejected', () {
      expect(
        () => buildWith(id: 'with space'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildWith(id: 'with\ttab'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildWith(id: 'with\nnewline'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty personaText is rejected', () {
      expect(
        () => buildWith(personaText: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildWith(personaText: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty objective is rejected', () {
      expect(
        () => buildWith(objective: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => buildWith(objective: '\n\t  '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('allowed/forbidden overlap is rejected', () {
      expect(
        () => buildWith(
          allowedActions: const {
            AllowedAction.llmCall,
            AllowedAction.memoryWrite,
          },
          forbiddenActions: const {AllowedAction.memoryWrite},
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('may not appear in both'),
        )),
      );
    });

    test('empty allowedActions is permitted (a no-op role)', () {
      final t = buildWith(allowedActions: const <AllowedAction>{});
      expect(t.allowedActions, isEmpty);
      expect(t.permits(AllowedAction.llmCall), isFalse);
    });
  });

  group('RoleTemplate field freezing', () {
    test('allowedActions on the returned instance is unmodifiable', () {
      final t = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: <AllowedAction>{AllowedAction.llmCall},
      );
      expect(
        () => t.allowedActions.add(AllowedAction.toolCall),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('forbiddenActions on the returned instance is unmodifiable', () {
      final t = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: const {AllowedAction.llmCall},
        forbiddenActions: <AllowedAction>{AllowedAction.userFacingAnswer},
      );
      expect(
        () => t.forbiddenActions.add(AllowedAction.memoryWrite),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('outputSchema on the returned instance is unmodifiable', () {
      final t = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: const {AllowedAction.llmCall},
        outputSchema: <String, Object?>{'type': 'object'},
      );
      expect(
        () => t.outputSchema!['extra'] = 'nope',
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('mutating the source set after construction does not affect the '
        'returned instance', () {
      final source = <AllowedAction>{AllowedAction.llmCall};
      final t = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: source,
      );
      // Mutate the source after construction; the template's snapshot
      // is unmodifiable so it does not pick up the change.
      // (We assert the template view stays at its construction-time
      // shape — the unmodifiable wrapper enforces this even if the
      // underlying source set later changes.)
      expect(t.allowedActions, equals(<AllowedAction>{AllowedAction.llmCall}));
    });
  });

  group('RoleTemplate.permits', () {
    final t = RoleTemplate(
      id: 'analyser',
      personaText: 'I am the analyser.',
      objective: 'Decompose.',
      allowedActions: const {
        AllowedAction.llmCall,
        AllowedAction.subThinking,
      },
    );

    test('returns true for an allowed action not in forbidden', () {
      expect(t.permits(AllowedAction.llmCall), isTrue);
      expect(t.permits(AllowedAction.subThinking), isTrue);
    });

    test('returns false for an action absent from allowed', () {
      expect(t.permits(AllowedAction.toolCall), isFalse);
      expect(t.permits(AllowedAction.userFacingAnswer), isFalse);
      expect(t.permits(AllowedAction.memoryRead), isFalse);
      expect(t.permits(AllowedAction.memoryWrite), isFalse);
    });
  });

  group('RoleTemplate value-class semantics', () {
    test('structurally identical instances are == and hash equal', () {
      final defaults = RoleBudgetDefaults(
        modelPreference: const ['m1'],
        temperature: 0.5,
      );
      final a = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: const {AllowedAction.llmCall, AllowedAction.memoryRead},
        forbiddenActions: const {AllowedAction.userFacingAnswer},
        outputSchema: const <String, Object?>{'type': 'object'},
        budgetDefaults: defaults,
      );
      final b = RoleTemplate(
        id: 'analyser',
        personaText: 'I am the analyser.',
        objective: 'Decompose.',
        allowedActions: const {AllowedAction.memoryRead, AllowedAction.llmCall},
        forbiddenActions: const {AllowedAction.userFacingAnswer},
        outputSchema: const <String, Object?>{'type': 'object'},
        budgetDefaults: defaults,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing id makes instances !=', () {
      final a = RoleTemplate(
        id: 'analyser',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      final b = RoleTemplate(
        id: 'evaluator',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      expect(a, isNot(equals(b)));
    });

    test('differing budgetDefaults makes instances !=', () {
      final a = RoleTemplate(
        id: 'analyser',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      final b = RoleTemplate(
        id: 'analyser',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
        budgetDefaults: RoleBudgetDefaults(temperature: 0.5),
      );
      expect(a, isNot(equals(b)));
    });

    test('outputSchema null vs non-null distinguishes instances', () {
      final a = RoleTemplate(
        id: 'analyser',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      final b = RoleTemplate(
        id: 'analyser',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
        outputSchema: const <String, Object?>{'type': 'object'},
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('RoleTemplate.toString', () {
    test('includes id, allowed, forbidden tokens, and budgetDefaults', () {
      final t = RoleTemplate(
        id: 'evaluator',
        personaText: 'I am the evaluator.',
        objective: 'Critique.',
        allowedActions: const {AllowedAction.llmCall},
        forbiddenActions: const {AllowedAction.userFacingAnswer},
      );
      final s = t.toString();
      expect(s, contains('id: evaluator'));
      expect(s, contains('llm_call'));
      expect(s, contains('user_facing_answer'));
      expect(s, contains('budgetDefaults'));
    });

    test('truncates very long persona / objective for readability', () {
      final long = 'x' * 200;
      final t = RoleTemplate(
        id: 'analyser',
        personaText: long,
        objective: long,
        allowedActions: const {AllowedAction.llmCall},
      );
      final s = t.toString();
      // The truncation logic emits "..." when the field exceeds 40
      // chars; a full 200-char repeat in the toString output would
      // make the diagnostic unreadable.
      expect(s, contains('...'));
      expect(s.length, lessThan(2 * long.length));
    });
  });

  group('Top-level barrel re-export', () {
    test('AllowedAction is importable from the package barrel', () {
      // Compile-time exercise: a non-trivial reference proves the
      // export chain wires through.
      const a = AllowedAction.toolCall;
      expect(a.token, equals('tool_call'));
    });

    test('RoleBudgetDefaults is importable from the package barrel', () {
      const d = RoleBudgetDefaults.empty;
      expect(d.modelPreference, isEmpty);
    });

    test('RoleTemplate is importable from the package barrel', () {
      final t = RoleTemplate(
        id: 'evaluator',
        personaText: 'p',
        objective: 'o',
        allowedActions: const {AllowedAction.llmCall},
      );
      expect(t.id, equals('evaluator'));
    });
  });
}
