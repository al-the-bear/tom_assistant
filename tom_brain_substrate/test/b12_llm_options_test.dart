// B.12 — `LlmOptions` value-class contract.
//
// Scope of this test file:
//
//   - Pin the post-B.12 field set: `(model, temperature,
//     maxOutputTokens, stopSequences, toolCatalogue, responseFormat)`.
//     A rename / drop of any field surfaces here as a compile failure.
//   - Prove the documented defaults: `model`, `temperature`,
//     `maxOutputTokens`, `responseFormat` default to `null`;
//     `stopSequences` defaults to `const <String>[]`;
//     `toolCatalogue` defaults to `ToolCatalogue.empty`.
//   - Prove `LlmOptions.empty` is a `const` all-defaults singleton
//     with the same field values as `const LlmOptions()`.
//   - Prove the `model` field carries the caller's verbatim override
//     (no coercion / normalisation) and propagates through to
//     subsequent construction.
//   - Prove `copyWith` semantics:
//       * Omitted nullable fields keep the existing value.
//       * Explicit `null` for `model`, `temperature`, `maxOutputTokens`,
//         `responseFormat` clears the field.
//       * Replacing `stopSequences` swaps the list reference; passing
//         `null` keeps the existing list (the field itself is
//         non-nullable on the class, the parameter is nullable for
//         "omit").
//       * Same for `toolCatalogue`.
//   - Prove `const` constructibility: the all-defaults instance is a
//     compile-time constant.
//
// Scope this file is NOT for:
//
//   - Router-side resolution of `LlmOptions.model` against route
//     chains. That is owned by the router (B.18+) and tested there.
//   - Provider-side downgrade notes (e.g. "responseFormat not
//     supported"). That is owned by individual providers (B.14–B.16).
//   - JSON serialisation of `LlmOptions`. The substrate's wire
//     surface speaks `WirePrompt` + provider-native shapes, not raw
//     `LlmOptions` JSON; no serialisation contract exists at B.12.

import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  group('B.12 / LlmOptions field set + defaults', () {
    test(
      'default constructor leaves every nullable knob null and every '
      'collection knob at its documented empty default',
      () {
        const opts = LlmOptions();

        expect(opts.model, isNull);
        expect(opts.temperature, isNull);
        expect(opts.maxOutputTokens, isNull);
        expect(opts.responseFormat, isNull);
        expect(opts.stopSequences, isEmpty);
        expect(opts.toolCatalogue.isEmpty, isTrue);
        expect(opts.toolCatalogue, same(ToolCatalogue.empty));
      },
    );

    test('LlmOptions.empty is the all-defaults const singleton', () {
      const fresh = LlmOptions();

      expect(LlmOptions.empty.model, isNull);
      expect(LlmOptions.empty.temperature, isNull);
      expect(LlmOptions.empty.maxOutputTokens, isNull);
      expect(LlmOptions.empty.responseFormat, isNull);
      expect(LlmOptions.empty.stopSequences, isEmpty);
      expect(LlmOptions.empty.toolCatalogue.isEmpty, isTrue);

      // The const default constructor and `LlmOptions.empty` share
      // the canonical const instance — Dart's const canonicalisation
      // guarantees this.
      expect(identical(fresh, LlmOptions.empty), isTrue);
    });

    test('every field round-trips when set on the constructor', () {
      const tool = ToolDescriptor(
        name: 'web_search',
        description: 'Search the public web.',
        parametersSchema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'query': <String, Object?>{'type': 'string'},
          },
          'required': <String>['query'],
        },
      );
      const catalogue = ToolCatalogue(<ToolDescriptor>[tool]);
      const opts = LlmOptions(
        model: 'gemma3:27b',
        temperature: 0.7,
        maxOutputTokens: 2048,
        stopSequences: <String>['<|end|>', '\n\nHuman:'],
        toolCatalogue: catalogue,
        responseFormat: <String, Object?>{
          'type': 'json_schema',
          'json_schema': <String, Object?>{
            'name': 'answer',
            'schema': <String, Object?>{'type': 'object'},
          },
        },
      );

      expect(opts.model, 'gemma3:27b');
      expect(opts.temperature, 0.7);
      expect(opts.maxOutputTokens, 2048);
      expect(opts.stopSequences, <String>['<|end|>', '\n\nHuman:']);
      expect(opts.toolCatalogue.tools, hasLength(1));
      expect(opts.toolCatalogue.tools.single.name, 'web_search');
      expect(opts.responseFormat, isNotNull);
      expect(opts.responseFormat!['type'], 'json_schema');
    });

    test('const constructor produces a compile-time-constant instance', () {
      // If this constructor stopped being const-callable (e.g. by
      // taking a non-const default for any field), this would fail
      // at compile time and never reach runtime.
      const a = LlmOptions(model: 'gemma3:27b', temperature: 0.0);
      const b = LlmOptions(model: 'gemma3:27b', temperature: 0.0);

      expect(identical(a, b), isTrue,
          reason: 'const-canonicalisation must merge structurally identical '
              'LlmOptions instances.');
    });
  });

  group('B.12 / LlmOptions.model — caller override surface', () {
    test('model is verbatim — no trimming, casing, or normalisation', () {
      const opts = LlmOptions(model: '  Gemma3:27B  ');

      expect(opts.model, '  Gemma3:27B  ');
    });

    test(
      'distinct model strings yield distinct field values (no aliasing across '
      'instances)',
      () {
        const a = LlmOptions(model: 'gemma3:27b');
        const b = LlmOptions(model: 'llama3.1:70b');

        expect(a.model, 'gemma3:27b');
        expect(b.model, 'llama3.1:70b');
        expect(identical(a, b), isFalse);
      },
    );

    test(
      'null model carries through as null (router resolves via role default)',
      () {
        const opts = LlmOptions(temperature: 0.2);

        expect(opts.model, isNull);
      },
    );
  });

  group('B.12 / LlmOptions.copyWith semantics', () {
    test('omitting all parameters returns an equivalent-field copy', () {
      const original = LlmOptions(
        model: 'gemma3:27b',
        temperature: 0.5,
        maxOutputTokens: 1024,
        stopSequences: <String>['<|end|>'],
        responseFormat: <String, Object?>{'type': 'json'},
      );

      final copy = original.copyWith();

      expect(copy.model, original.model);
      expect(copy.temperature, original.temperature);
      expect(copy.maxOutputTokens, original.maxOutputTokens);
      expect(copy.stopSequences, original.stopSequences);
      expect(copy.toolCatalogue, same(original.toolCatalogue));
      expect(copy.responseFormat, original.responseFormat);
    });

    test('explicit null clears nullable fields (model)', () {
      const original = LlmOptions(model: 'gemma3:27b', temperature: 0.5);

      final cleared = original.copyWith(model: null);

      expect(cleared.model, isNull);
      // Other fields untouched.
      expect(cleared.temperature, 0.5);
    });

    test('explicit null clears nullable fields (temperature)', () {
      const original = LlmOptions(model: 'gemma3:27b', temperature: 0.5);

      final cleared = original.copyWith(temperature: null);

      expect(cleared.temperature, isNull);
      expect(cleared.model, 'gemma3:27b');
    });

    test('explicit null clears nullable fields (maxOutputTokens)', () {
      const original = LlmOptions(maxOutputTokens: 2048);

      final cleared = original.copyWith(maxOutputTokens: null);

      expect(cleared.maxOutputTokens, isNull);
    });

    test('explicit null clears nullable fields (responseFormat)', () {
      const original = LlmOptions(
        responseFormat: <String, Object?>{'type': 'json'},
      );

      final cleared = original.copyWith(responseFormat: null);

      expect(cleared.responseFormat, isNull);
    });

    test('replacement value overrides original (model)', () {
      const original = LlmOptions(model: 'gemma3:27b');

      final replaced = original.copyWith(model: 'llama3.1:70b');

      expect(replaced.model, 'llama3.1:70b');
    });

    test('replacement value overrides original (stopSequences)', () {
      const original = LlmOptions(stopSequences: <String>['<|end|>']);

      final replaced = original.copyWith(
        stopSequences: const <String>['STOP', '\n\nUser:'],
      );

      expect(replaced.stopSequences, <String>['STOP', '\n\nUser:']);
    });

    test('omitting stopSequences keeps the original list reference', () {
      const original = LlmOptions(stopSequences: <String>['<|end|>']);

      final copy = original.copyWith();

      expect(copy.stopSequences, same(original.stopSequences),
          reason: 'omitting stopSequences must not allocate a new list.');
    });

    test('replacement value overrides original (toolCatalogue)', () {
      const tool = ToolDescriptor(
        name: 'web_fetch',
        description: 'Fetch a URL.',
        parametersSchema: <String, Object?>{'type': 'object'},
      );
      const catalogue = ToolCatalogue(<ToolDescriptor>[tool]);
      const original = LlmOptions();

      final replaced = original.copyWith(toolCatalogue: catalogue);

      expect(replaced.toolCatalogue.tools, hasLength(1));
      expect(replaced.toolCatalogue.tools.single.name, 'web_fetch');
    });

    test('copyWith does not mutate the source instance', () {
      const original = LlmOptions(
        model: 'gemma3:27b',
        temperature: 0.5,
        stopSequences: <String>['<|end|>'],
      );

      original.copyWith(model: 'llama3.1:70b', temperature: null);

      expect(original.model, 'gemma3:27b');
      expect(original.temperature, 0.5);
      expect(original.stopSequences, <String>['<|end|>']);
    });
  });

  group('B.12 / LlmOptions surface reachability', () {
    test('LlmOptions is exported from the top-level package barrel', () {
      // The single test-file import line is
      //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
      // — reaching `LlmOptions` and `ToolCatalogue` under that
      // constraint proves the api/ surface re-exports both.
      const opts = LlmOptions(model: 'x');
      expect(opts, isA<LlmOptions>());
      expect(ToolCatalogue.empty, isA<ToolCatalogue>());
    });
  });
}
