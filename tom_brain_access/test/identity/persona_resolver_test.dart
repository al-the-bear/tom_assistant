// E.26 contract test — the `PersonaResolver` edge persona step.
//
// Four surfaces are exercised:
//   * Default vocabulary: `knownModels` is the shared
//     `OpenAiPersonaMapping.knownModels` list (single source of truth,
//     E.15), unmodifiable.
//   * `resolve` — recognised id: each of the three persona-as-model ids
//     round-trips to a `Persona` carrying that id and the prototype
//     substrate role `assistant_to_user`.
//   * `resolve` — defaulting: a `null`, empty, or unrecognised model id
//     falls back to `Persona.assistant()` (AC-5 — not an error).
//   * Injected vocabulary: a custom `knownModels` widens / narrows the
//     recognised set; resolution follows it; `isKnown` mirrors `resolve`.
//
// Per the E.26 scope ruling this test deliberately does NOT assert identity
// resolution (E.24), session resolution (E.25), user-knowledge enrichment
// (out of prototype scope, § 14), or dispatcher / boot wiring (E.41+).

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('PersonaResolver — default vocabulary', () {
    test('knownModels is the shared OpenAiPersonaMapping vocabulary', () {
      final resolver = PersonaResolver();
      expect(resolver.knownModels, OpenAiPersonaMapping.knownModels);
      expect(
        resolver.knownModels,
        <String>['tom-assistant', 'tom-assistant:terse', 'tom-assistant:verbose'],
      );
    });

    test('knownModels is unmodifiable', () {
      final resolver = PersonaResolver();
      expect(
        () => resolver.knownModels.add('rogue'),
        throwsUnsupportedError,
      );
    });
  });

  group('PersonaResolver.resolve — recognised id', () {
    test('base model id resolves to the assistant_to_user persona', () {
      final persona = PersonaResolver().resolve('tom-assistant');
      expect(persona.personaId, 'tom-assistant');
      expect(persona.substrateRole, 'assistant_to_user');
      expect(persona.substrateRole, Persona.defaultSubstrateRole);
    });

    test('terse variant preserves the variant id, same substrate role', () {
      final persona = PersonaResolver().resolve('tom-assistant:terse');
      expect(persona.personaId, 'tom-assistant:terse');
      expect(persona.substrateRole, 'assistant_to_user');
    });

    test('verbose variant preserves the variant id, same substrate role', () {
      final persona = PersonaResolver().resolve('tom-assistant:verbose');
      expect(persona.personaId, 'tom-assistant:verbose');
      expect(persona.substrateRole, 'assistant_to_user');
    });

    test('every prototype persona resolves to one substrate role', () {
      final resolver = PersonaResolver();
      final roles = resolver.knownModels
          .map((id) => resolver.resolve(id).substrateRole)
          .toSet();
      expect(roles, <String>{'assistant_to_user'});
    });
  });

  group('PersonaResolver.resolve — defaulting (AC-5)', () {
    test('a null model id falls back to Persona.assistant()', () {
      final persona = PersonaResolver().resolve(null);
      expect(persona, Persona.assistant());
      expect(persona.personaId, Persona.defaultPersonaId);
      expect(persona.substrateRole, Persona.defaultSubstrateRole);
    });

    test('an unrecognised model id falls back to Persona.assistant()', () {
      final persona = PersonaResolver().resolve('gpt-4o');
      expect(persona, Persona.assistant());
    });

    test('an empty model id falls back to Persona.assistant()', () {
      // The empty string is not in the vocabulary → default, not an
      // ArgumentError (the resolver never builds a Persona from it).
      final persona = PersonaResolver().resolve('');
      expect(persona, Persona.assistant());
    });

    test('isKnown is false for null / unknown / empty, true for the three',
        () {
      final resolver = PersonaResolver();
      expect(resolver.isKnown(null), isFalse);
      expect(resolver.isKnown('gpt-4o'), isFalse);
      expect(resolver.isKnown(''), isFalse);
      expect(resolver.isKnown('tom-assistant'), isTrue);
      expect(resolver.isKnown('tom-assistant:terse'), isTrue);
      expect(resolver.isKnown('tom-assistant:verbose'), isTrue);
    });
  });

  group('PersonaResolver — injected vocabulary (AccessConfig seam, E.41+)', () {
    test('a custom vocabulary is the recognised set', () {
      final resolver = PersonaResolver(knownModels: const ['tom-research']);
      expect(resolver.isKnown('tom-research'), isTrue);
      expect(resolver.resolve('tom-research').personaId, 'tom-research');
      expect(
        resolver.resolve('tom-research').substrateRole,
        Persona.defaultSubstrateRole,
      );
    });

    test('an id outside the injected vocabulary still defaults', () {
      final resolver = PersonaResolver(knownModels: const ['tom-research']);
      // The default base id is no longer recognised under this vocabulary.
      expect(resolver.isKnown('tom-assistant'), isFalse);
      expect(resolver.resolve('tom-assistant'), Persona.assistant());
    });

    test('the injected vocabulary is copied unmodifiable', () {
      final source = <String>['tom-research'];
      final resolver = PersonaResolver(knownModels: source);
      source.add('tom-research:terse');
      // The later mutation of the caller's list must not change resolution.
      expect(resolver.isKnown('tom-research:terse'), isFalse);
      expect(() => resolver.knownModels.add('x'), throwsUnsupportedError);
    });
  });
}
