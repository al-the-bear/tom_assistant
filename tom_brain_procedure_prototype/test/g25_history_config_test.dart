// Extension G step 25 — the `history:` config blocks on the two existing
// config layers (`prototype_tools_mcp_extension_plan.md` step 25;
// `tom_brain_procedure_prototype_specification.md` § 22.6; access § 13.1).
//
// History config is split exactly per § 22.6:
//   (a) behavioural flags — a `history:` block on the **prompt template**
//       (`HistoryPolicy`: useLocal / useRemote / injectAsPriorTurns /
//       compactionTemplate);
//   (b) sizing knobs — a `history:` block on the **model config**
//       (`HistorySizing`: rawCount / compactionThreshold / maxCompactedTokens /
//       maxCompactedChars).
//
// The contract under test: a **missing** `history:` block on either layer
// falls back to the documented defaults (NOT an error); a **present** block is
// parsed through the canonical plain-map loader (no `YamlMap` leak); an
// ill-typed / non-positive value is a located `LlmConfigInvalid`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show HistorySizing;

/// A minimal valid prompt template body the tests prepend a `history:` block
/// to (or omit one from).
const String _templateBase = '''
id: assistant_to_user
role: assistant_to_user
models:
  - { config: gemma_4_26b, provider: omlx }
system: "S \${prompt}"
user: "U \${prompt}"
''';

/// A minimal valid model config body the tests prepend a `history:` block to.
const String _modelBase = '''
id: gemma_4_26b
providerNames:
  omlx: gemma3:27b
''';

void main() {
  group('G.25-cfg-1: prompt template — HistoryPolicy defaulting', () {
    test('a missing history: block falls back to the standard policy', () {
      final template = PromptTemplateConfig.fromYamlString(_templateBase);
      expect(template.history, const HistoryPolicy.standard());
      expect(template.history.useLocal, isTrue);
      expect(template.history.useRemote, isTrue);
      expect(template.history.injectAsPriorTurns, isTrue);
      expect(template.history.compactionTemplate, 'compact_history_v1');
    });

    test('a present history: block is parsed in full', () {
      final template = PromptTemplateConfig.fromYamlString('''
$_templateBase
history:
  useLocal: false
  useRemote: false
  injectAsPriorTurns: false
  compactionTemplate: compact_terse_v2
''');
      expect(
        template.history,
        const HistoryPolicy(
          useLocal: false,
          useRemote: false,
          injectAsPriorTurns: false,
          compactionTemplate: 'compact_terse_v2',
        ),
      );
    });

    test('a partial history: block defaults only the absent keys', () {
      final template = PromptTemplateConfig.fromYamlString('''
$_templateBase
history:
  injectAsPriorTurns: false
''');
      expect(template.history.useLocal, isTrue);
      expect(template.history.useRemote, isTrue);
      expect(template.history.injectAsPriorTurns, isFalse);
      expect(template.history.compactionTemplate, 'compact_history_v1');
    });

    test('a non-boolean flag is a located LlmConfigInvalid', () {
      // The YamlConfigReader locates type mismatches in the message (its
      // single-arg factory bakes the dotted path into the text), matching the
      // rest of the prototype's config loaders.
      expect(
        () => PromptTemplateConfig.fromYamlString('''
$_templateBase
history:
  useLocal: "yes please"
'''),
        throwsA(isA<LlmConfigInvalid>().having((e) => e.message, 'message',
            contains('prompt_template.history.useLocal'))),
      );
    });
  });

  group('G.25-cfg-3: shipped example YAML documents both history: blocks', () {
    // The *Verify* clause requires the example YAML to document both history:
    // blocks. These load the shipped files (from the project root, where the
    // test runner's CWD sits) and assert the documented values parse through
    // the canonical loaders — guarding the examples from rot.
    test('prompt_template/assistant_to_user.yaml carries the behavioural block',
        () {
      final yaml =
          File('prompt_template/assistant_to_user.yaml').readAsStringSync();
      final template = PromptTemplateConfig.fromYamlString(yaml);
      expect(
        template.history,
        const HistoryPolicy(
          useLocal: true,
          useRemote: true,
          injectAsPriorTurns: true,
          compactionTemplate: 'compact_history_v1',
        ),
      );
    });

    test('models/gemma_4_26b.yaml carries the sizing block', () {
      final yaml = File('models/gemma_4_26b.yaml').readAsStringSync();
      final model = ModelConfig.fromYamlString(yaml);
      expect(
        model.history,
        const HistorySizing(
          rawCount: 10,
          compactionThreshold: 40,
          maxCompactedTokens: 1024,
          maxCompactedChars: 6000,
        ),
      );
    });
  });

  group('G.25-cfg-2: model config — HistorySizing defaulting', () {
    test('a missing history: block falls back to the standard sizing', () {
      final model = ModelConfig.fromYamlString(_modelBase);
      expect(model.history, const HistorySizing.standard());
      expect(model.history.rawCount, 10);
      expect(model.history.compactionThreshold, 40);
      expect(model.history.maxCompactedTokens, 1024);
      expect(model.history.maxCompactedChars, 6000);
    });

    test('a present history: block is parsed in full', () {
      final model = ModelConfig.fromYamlString('''
$_modelBase
history:
  rawCount: 6
  compactionThreshold: 24
  maxCompactedTokens: 512
  maxCompactedChars: 3000
''');
      expect(
        model.history,
        const HistorySizing(
          rawCount: 6,
          compactionThreshold: 24,
          maxCompactedTokens: 512,
          maxCompactedChars: 3000,
        ),
      );
    });

    test('a partial history: block defaults only the absent knobs', () {
      final model = ModelConfig.fromYamlString('''
$_modelBase
history:
  rawCount: 4
''');
      expect(model.history.rawCount, 4);
      expect(model.history.compactionThreshold, 40);
      expect(model.history.maxCompactedTokens, 1024);
      expect(model.history.maxCompactedChars, 6000);
    });

    test('a non-positive knob is a located LlmConfigInvalid', () {
      expect(
        () => ModelConfig.fromYamlString('''
$_modelBase
history:
  rawCount: 0
'''),
        throwsA(isA<LlmConfigInvalid>()
            .having((e) => e.path, 'path', 'model.history.rawCount')),
      );
    });

    test('a non-integer knob is a located LlmConfigInvalid', () {
      // Reader-detected type mismatch ⇒ the dotted path is in the message
      // (the `_positiveOr` semantic check below carries the structured path).
      expect(
        () => ModelConfig.fromYamlString('''
$_modelBase
history:
  compactionThreshold: "lots"
'''),
        throwsA(isA<LlmConfigInvalid>().having((e) => e.message, 'message',
            contains('model.history.compactionThreshold'))),
      );
    });
  });
}
