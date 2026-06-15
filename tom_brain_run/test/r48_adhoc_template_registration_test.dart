// r48 — registration of the migrated ad-hoc templates
// (`prompt_restructuring_and_configuration_plan.md` step 10; decisions
// D10.1…D10.5).
//
// Step 10 lifted the three ad-hoc strings the answer loops built in Dart
// (`_confirmationQuestion` / `_continueReminderText` / `_renderTodoList`) into
// the committed cognition config as registered templates under both the
// `answer_with_memory` and `answer_with_thinking` sub-procedures:
//
//   * `completion_check`   — `kind: prompt`. The DONE/CONTINUE confirmation turn,
//                            a no-tool prompt under the inherited
//                            `assistant_to_user` role. Its system half is
//                            role-supplied (§9 / D9), so only the `.user.md`
//                            exists; the body carries `${text}` and the optional
//                            `${todo_list?}` slot.
//   * `continuation_hint`  — `kind: fragment`. The static "resume unfinished
//                            work" reminder.
//   * `todo_list`          — `kind: fragment`. The `${todo_entries}` checklist
//                            the resolver renders from the live `todo.list`
//                            result — an empty string for no todos, `[x]`/`[ ]`
//                            lines for some (D10.3, replacing the pre-§10
//                            "(your task list is currently empty)" sentinel).
//
// The thinking loop *shares the template files* with the memory loop (the
// procedures shared the Dart builders): both sub-procedures' `template:` values
// point at the same `answer_with_memory.*` stems, which resolve under the shared
// `assist_user/` folder.
//
// This test pins step 10's three named checks: the new IDs resolve, the
// `todo_list` fragment renders empty / a list, and the loader enumerates them
// (plus the kinds, the `${todo_list?}` slot wiring, and the file-sharing).

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ResolvedPrompt;
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        BrainBuiltins,
        CognitionConfig,
        CognitionConfigLoader,
        PromptKind,
        buildPromptResolver;
import 'package:test/test.dart';

/// The committed cognition config tree (`Directory.current` is the package root
/// under `dart test` / testkit).
String _cognitionRoot() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    ).absolute.path;

BrainBuiltins _builtins(String configRoot) => BrainBuiltins(
      hostname: 'bomber',
      trailFolder: '',
      configFolder: configRoot,
      memoryRoot: '/tmp/mem',
      scriptsFolder: '/tmp/scripts',
    );

/// The six step-10 IDs: three under each of the two answer sub-procedures.
const String _memCompletion = 'assist_user.answer_with_memory.completion_check';
const String _memHint = 'assist_user.answer_with_memory.continuation_hint';
const String _memTodos = 'assist_user.answer_with_memory.todo_list';
const String _thinkCompletion =
    'assist_user.answer_with_thinking.completion_check';
const String _thinkHint = 'assist_user.answer_with_thinking.continuation_hint';
const String _thinkTodos = 'assist_user.answer_with_thinking.todo_list';

void main() {
  late String configRoot;
  late CognitionConfig cfg;

  setUpAll(() {
    configRoot = _cognitionRoot();
    cfg = CognitionConfigLoader.loadFromDir(configRoot);
  });

  group('§10 — the loader enumerates the migrated ad-hoc templates', () {
    test('all six new IDs are registered with the expected kinds', () {
      final ids = cfg.promptIds.toSet();
      expect(ids, containsAll(<String>[
        _memCompletion,
        _memHint,
        _memTodos,
        _thinkCompletion,
        _thinkHint,
        _thinkTodos,
      ]));

      // `completion_check` is a full prompt; the hint / todo_list are fragments.
      expect(cfg.resolve(_memCompletion).kind, PromptKind.prompt);
      expect(cfg.resolve(_thinkCompletion).kind, PromptKind.prompt);
      for (final id in <String>[_memHint, _memTodos, _thinkHint, _thinkTodos]) {
        expect(cfg.resolve(id).kind, PromptKind.fragment,
            reason: '$id must be a fragment');
      }
    });

    test('completion_check is a no-tool prompt under the inherited role', () {
      final settings = cfg.resolve(_memCompletion).settings;
      expect(settings.role, 'assistant_to_user');
    });
  });

  group('§10 — the new IDs resolve', () {
    test(r'completion_check renders ${text} and the optional ${todo_list?} slot',
        () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved = await resolve(_memCompletion, {
        'text': 'Why does memory consolidate?',
        'todo_list': '[ ] draft answer\n[x] recall facts',
      });
      expect(resolved, isNotNull);
      final body = resolved!.templateBody;
      // The user request and the rendered list landed in their slots.
      expect(body, contains('Why does memory consolidate?'));
      expect(body, contains('[ ] draft answer'));
      expect(body, contains('[x] recall facts'));
      // The DONE/CONTINUE contract text survived the migration.
      expect(body, contains('reply with DONE as the first word'));
      expect(body, contains('reply with CONTINUE as the first word'));
      // No raw placeholder leaked through.
      expect(body, isNot(contains(r'${text}')));
      expect(body, isNot(contains(r'${todo_list')));
    });

    test(r'completion_check leaves the ${todo_list?} slot empty when unbound',
        () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved =
          await resolve(_memCompletion, {'text': 'A question.'});
      expect(resolved, isNotNull);
      final body = resolved!.templateBody;
      expect(body, contains('A question.'));
      // The optional slot rendered empty rather than surfacing the placeholder.
      expect(body, isNot(contains(r'${todo_list')));
    });

    test('continuation_hint resolves to the static reminder text', () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved = await resolve(_memHint, const {});
      expect(resolved, isNotNull);
      expect(resolved!.templateBody.trim(),
          'You indicated your previous answer was not yet complete. Review your '
          'task list, continue the outstanding work, and mark each task done '
          'with todo.update as you finish it.');
    });
  });

  group('§10 — todo_list renders empty for no todos and a list for some', () {
    test('an empty / absent listing renders the empty string', () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));

      final ResolvedPrompt? absent = await resolve(_memTodos, const {});
      expect(absent, isNotNull);
      expect(absent!.templateBody, isEmpty);

      final ResolvedPrompt? empty =
          await resolve(_memTodos, {'todos': const <Object?>[]});
      expect(empty, isNotNull);
      expect(empty!.templateBody, isEmpty);
    });

    test('a populated listing renders the [x]/[ ] checklist', () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved = await resolve(_memTodos, {
        'todos': <Object?>[
          <String, Object?>{'id': 't1', 'text': 'Read the spec', 'done': true},
          <String, Object?>{'id': 't2', 'text': 'Write the code', 'done': false},
        ],
      });
      expect(resolved, isNotNull);
      expect(resolved!.templateBody, '[x] Read the spec\n[ ] Write the code');
    });
  });

  group('§10 — the thinking loop shares the memory loop\'s template files', () {
    test('the shared IDs resolve to byte-identical bodies for equal inputs',
        () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final inputs = {
        'text': 'Shared question?',
        'todo_list': '[ ] one',
      };
      final ResolvedPrompt? mem = await resolve(_memCompletion, inputs);
      final ResolvedPrompt? think = await resolve(_thinkCompletion, inputs);
      expect(mem, isNotNull);
      expect(think, isNotNull);
      expect(think!.templateBody, mem!.templateBody);

      final ResolvedPrompt? memHint = await resolve(_memHint, const {});
      final ResolvedPrompt? thinkHint = await resolve(_thinkHint, const {});
      expect(thinkHint!.templateBody, memHint!.templateBody);
    });
  });
}
