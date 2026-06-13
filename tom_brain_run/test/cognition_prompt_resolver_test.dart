// Parity test for the §7.4 cognition glue (`buildPromptResolver` /
// `buildRouteChainResolver`).
//
// Increment 6 (`prompt_configuration.md` §6 / §12) migrated the normal answer
// path onto `sub.run('assist_user.answer_with_memory.assembly', inputs:)`. In
// production the host `PromptResolver` is built by [buildPromptResolver] over
// the loaded `CognitionConfig` (the committed `config/bomber/cognition` tree);
// the procedure-side acceptance suites fake the same seam with
// `AnswerParityPrompts`. This test pins the production glue to the *same*
// assembled body the fake reproduces (§12 parity), reading the real committed
// template off disk so the template + glue + sub-renderers are exercised
// together.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ResolvedPrompt;
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        BrainBuiltins,
        CognitionConfigLoader,
        buildPromptResolver,
        buildRouteChainResolver;
import 'package:tom_brain_substrate/tom_brain_substrate.dart' show RouteEntry;
import 'package:test/test.dart';

/// The committed cognition config tree this test loads the prompt off disk
/// from. `Directory.current` is the package root under `dart test` / testkit.
String _cognitionRoot() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    ).absolute.path;

/// Reproduces the pre-increment-6 `_assemblePrompt` output (the same text the
/// `AnswerParityPrompts` fake reproduces), leaving the `${tools.catalogue}`
/// marker for the `SubstrateBridge.run` renderer.
String _expectedBody({
  required Object? recall,
  required Object? text,
  required Object? priorTurns,
  required Object? reminder,
}) {
  const catalogueMarker = r'${tools.catalogue}';
  final history = _renderPriorTurns(priorTurns);

  var context = '';
  if (recall is Map) {
    final nodes = recall['nodes'];
    if (nodes is List) {
      for (final node in nodes) {
        if (node is Map) {
          final values = node['values'];
          if (values is Map && values['text'] != null) {
            context += '- ${values['text']}\n';
          }
        }
      }
    }
  }
  final preamble = context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';

  final reminderBlock =
      (reminder is String && reminder.isNotEmpty) ? '\n$reminder\n' : '';

  return '$catalogueMarker${_todoDisciplineBlock()}$history$preamble'
      'User prompt:\n$text$reminderBlock';
}

String _todoDisciplineBlock() =>
    'Task tracking — you MUST manage your own todo list with these tools:\n'
    '  call:todo.add{text: "Read CLAUDE.md"}     -> returns {id: "t1"}\n'
    '  call:todo.list{}                          -> lists entries with their ids\n'
    '  call:todo.update{id: "t1", done: true}    -> mark an entry finished\n'
    '  call:todo.remove{id: "t1"}                -> drop an entry by its id\n'
    'Always use the id returned by todo.add — never the text — for '
    'update/remove. Before you start, break the request into todos with '
    'todo.add. As you complete each step, mark it done with todo.update. You '
    'are NOT finished until every todo is done; do not claim completion while '
    'open todos remain.\n\n';

String _renderPriorTurns(Object? priorTurns) {
  if (priorTurns is! List || priorTurns.isEmpty) return '';
  var rendered = '';
  for (final turn in priorTurns) {
    if (turn is! Map) continue;
    final user = turn['user'];
    final assistant = turn['assistant'];
    if (user != null && '$user'.isNotEmpty) rendered += 'User: $user\n';
    if (assistant != null && '$assistant'.isNotEmpty) {
      rendered += 'Assistant: $assistant\n';
    }
  }
  return rendered.isEmpty ? '' : 'Conversation so far:\n$rendered\n';
}

BrainBuiltins _builtins(String configRoot) => BrainBuiltins(
      hostname: 'bomber',
      trailFolder: '',
      configFolder: configRoot,
      memoryRoot: '/tmp/mem',
      scriptsFolder: '/tmp/scripts',
    );

void main() {
  const promptId = 'assist_user.answer_with_memory.assembly';

  group('§7.4 cognition glue — buildPromptResolver parity', () {
    late final String configRoot;
    setUpAll(() => configRoot = _cognitionRoot());

    test('reproduces the parity body for a full set of inputs', () async {
      final cfg = CognitionConfigLoader.loadFromDir(configRoot);
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));

      final recall = <String, Object?>{
        'nodes': <Object?>[
          <String, Object?>{
            'values': <String, Object?>{'text': 'fact A'},
          },
          <String, Object?>{
            'values': <String, Object?>{'text': 'fact B'},
          },
        ],
      };
      final priorTurns = <Object?>[
        <String, Object?>{'user': 'hello', 'assistant': 'hi there'},
      ];
      const text = 'What is the plan?';
      const reminder = '<reminder>open todos: finish step 2</reminder>';

      final ResolvedPrompt? resolved = await resolve(promptId, {
        'text': text,
        'recall': recall,
        'priorTurns': priorTurns,
        'open_todo_reminder': reminder,
      });

      expect(resolved, isNotNull);
      expect(
        resolved!.templateBody,
        _expectedBody(
          recall: recall,
          text: text,
          priorTurns: priorTurns,
          reminder: reminder,
        ),
      );
      // The `${tools.catalogue}` marker survives placeholder resolution
      // (rendered later by SubstrateBridge.run from the tool policy).
      expect(resolved.templateBody, contains(r'${tools.catalogue}'));
      // The main procedure's settings flow through: user-facing role, the
      // `assistant` default route, the full tool catalogue (tools: all), the
      // default tool-loop cap.
      expect(resolved.role, 'assistant_to_user');
      expect(resolved.llmRoute, 'assistant');
      expect(resolved.tools, isNotEmpty);
      expect(resolved.maxToolLoops, 6);
    });

    test('reproduces the parity body with empty recall / no prior turns / no '
        'reminder', () async {
      final cfg = CognitionConfigLoader.loadFromDir(configRoot);
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));

      const text = 'Single-shot question.';
      final ResolvedPrompt? resolved = await resolve(promptId, {
        'text': text,
        'recall': const <String, Object?>{'nodes': <Object?>[]},
        'priorTurns': const <Object?>[],
        'open_todo_reminder': '',
      });

      expect(resolved, isNotNull);
      expect(
        resolved!.templateBody,
        _expectedBody(
          recall: const <String, Object?>{'nodes': <Object?>[]},
          text: text,
          priorTurns: const <Object?>[],
          reminder: '',
        ),
      );
    });

    test('does not re-interpret a \${...} token inside user text', () async {
      final cfg = CognitionConfigLoader.loadFromDir(configRoot);
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));

      // A user prompt that itself contains a placeholder-looking token must be
      // carried through verbatim, never resolved as a binding.
      const text = r'Explain ${memory_root} and ${unknownBinding} please.';
      final ResolvedPrompt? resolved = await resolve(promptId, {
        'text': text,
        'recall': const <String, Object?>{'nodes': <Object?>[]},
        'priorTurns': const <Object?>[],
        'open_todo_reminder': '',
      });

      expect(resolved, isNotNull);
      expect(resolved!.templateBody, contains(text));
    });

    test('returns null for an unregistered prompt id', () async {
      final cfg = CognitionConfigLoader.loadFromDir(configRoot);
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      expect(await resolve('no.such.prompt', const {}), isNull);
    });
  });

  group('§9 thinking-path glue — buildPromptResolver over the real templates',
      () {
    late final String configRoot;
    setUpAll(() => configRoot = _cognitionRoot());

    const base = 'assist_user.answer_with_thinking';

    final recall = <String, Object?>{
      'nodes': <Object?>[
        <String, Object?>{
          'values': <String, Object?>{'text': 'fact A'},
        },
      ],
    };
    const analysis = 'Analysis: the answer must cover X and Y.';
    const subReasoning = 'Sub-reasoning: X depends on Z.';
    const text = 'How does memory consolidate?';
    const rejection =
        'Attempt 1:\nDraft:\nthe bad draft\nCritique:\nREJECT missing Y\n\n';

    Future<ResolvedPrompt?> resolveStage(
      String stage,
      Map<String, Object?> inputs,
    ) async {
      final cfg = CognitionConfigLoader.loadFromDir(configRoot);
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      return resolve('$base.$stage', inputs);
    }

    test('synthesis is the tool-enabled "normal prompt": catalogue survives, '
        'role + route inherited, bindings rendered', () async {
      final resolved = await resolveStage('synthesis', {
        'text': text,
        'recall': recall,
        'priorTurns': const <Object?>[],
        'rejection_context': '',
        'analysis': analysis,
        'sub_reasoning': subReasoning,
      });

      expect(resolved, isNotNull);
      // §9: synthesis inherits the user-facing role + assistant route + tools:all.
      expect(resolved!.role, 'assistant_to_user');
      expect(resolved.llmRoute, 'assistant');
      expect(resolved.tools, isNotEmpty);
      // The catalogue marker survives for SubstrateBridge.run to render.
      expect(resolved.templateBody, contains(r'${tools.catalogue}'));
      // The §6 thinking bindings are rendered generically.
      expect(resolved.templateBody, contains(analysis));
      expect(resolved.templateBody, contains(subReasoning));
      expect(resolved.templateBody, contains('- fact A'));
      expect(resolved.templateBody, contains(text));
    });

    test('synthesis_reentry folds the accumulated rejection history in via '
        '\${rejection_context}', () async {
      final resolved = await resolveStage('synthesis_reentry', {
        'text': text,
        'recall': recall,
        'priorTurns': const <Object?>[],
        'rejection_context': rejection,
        'analysis': analysis,
        'sub_reasoning': subReasoning,
      });

      expect(resolved, isNotNull);
      expect(resolved!.tools, isNotEmpty);
      expect(resolved.templateBody, contains(r'${tools.catalogue}'));
      // The increasing history reaches the prompt verbatim.
      expect(resolved.templateBody, contains('the bad draft'));
      expect(resolved.templateBody, contains('REJECT missing Y'));
    });

    test('analysis runs as the read-only analyser and does not leak the '
        'rejection context', () async {
      final resolved = await resolveStage('analysis', {
        'text': text,
        'recall': recall,
        'priorTurns': const <Object?>[],
        // Always passed by the procedure; the base template must not reference it.
        'rejection_context': rejection,
      });

      expect(resolved, isNotNull);
      expect(resolved!.role, 'analyser');
      // `tools: readonly` resolves to a non-empty (filtered) catalogue.
      expect(resolved.tools, isNotEmpty);
      expect(resolved.templateBody, contains(text));
      expect(resolved.templateBody, contains('- fact A'));
      // The first-pass template never surfaces the rejection history.
      expect(resolved.templateBody, isNot(contains('the bad draft')));
    });

    test('analysis_reentry runs as the analyser and surfaces the rejection '
        'history', () async {
      final resolved = await resolveStage('analysis_reentry', {
        'text': text,
        'recall': recall,
        'priorTurns': const <Object?>[],
        'rejection_context': rejection,
      });

      expect(resolved, isNotNull);
      expect(resolved!.role, 'analyser');
      expect(resolved.templateBody, contains('the bad draft'));
    });

    test('sub_think runs as the sub_thinker over the analysis', () async {
      final resolved = await resolveStage('sub_think', {
        'text': text,
        'analysis': analysis,
      });

      expect(resolved, isNotNull);
      expect(resolved!.role, 'sub_thinker');
      expect(resolved.templateBody, contains(analysis));
      expect(resolved.templateBody, contains(text));
    });

    test('critique is the no-tool evaluator over the draft', () async {
      final resolved = await resolveStage('critique', {
        'text': text,
        'draft': 'the draft under review',
      });

      expect(resolved, isNotNull);
      expect(resolved!.role, 'evaluator');
      // §9: critique is `tools: none`.
      expect(resolved.tools, isEmpty);
      expect(resolved.templateBody, contains('the draft under review'));
      // No tool catalogue marker in the critique template.
      expect(resolved.templateBody, isNot(contains(r'${tools.catalogue}')));
    });
  });

  group('§8 cognition glue — buildRouteChainResolver', () {
    test('expands the assistant route to its single oMLX entry', () {
      final cfg = CognitionConfigLoader.loadFromDir(_cognitionRoot());
      final routeChainOf = buildRouteChainResolver(cfg);
      final List<RouteEntry> chain = routeChainOf('assistant');
      expect(chain, hasLength(1));
      expect(chain.single.providerId, 'omlx');
      expect(chain.single.model, 'gemma-4-26b-a4b-it-4bit');
    });
  });
  // The live `/switch_model` re-routing of these two resolver seams — a normal
  // config change, not an override layer — is pinned end-to-end (disk write +
  // live-config mutation + resolver reflection + reload survival) in
  // `r41_model_switch_test.dart`.
}
