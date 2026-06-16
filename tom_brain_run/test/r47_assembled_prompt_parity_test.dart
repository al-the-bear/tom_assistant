// r47 — golden assembled-prompt parity for the §9 template migration
// (`prompt_restructuring_and_configuration_plan.md` step 9; decisions
// D9.3 / D9.4 / D9.5).
//
// Step 9 migrated every `kind: prompt` template to a `.system.md` + `.user.md`
// pair. As recorded in the decisions file (D9.1), the *content* split was
// realised across steps 6–8: the system scaffold (anchor + persona + objective
// + optional output-schema) is owned by the **role layer**
// (`RoleTemplate.assemble` → `SystemScaffold`), every per-prompt file is
// **user-channel** material, and step 8's `git mv` to `<stem>.user.md` was
// byte-identical. The system half of each migrated prompt is therefore
// legitimately *empty* — the role supplies the system channel.
//
// This test is the golden assembled-prompt guard step 9 names: for every
// migrated `kind: prompt` in the committed `config/bomber/cognition` tree it
// reproduces the production wire text on a stub substrate and asserts it matches
// the pre-migration prompt **modulo the system/user split**:
//
//   * `wp.user`     == `'prompt: ' + <rendered .user.md body>`  (the migrated
//                       user body is exactly the pre-§8 single-file body —
//                       byte-pinned by `cognition_prompt_resolver_test`).
//   * `wp.system`   leads with the assistant-dedication anchor and carries the
//                       role's `PERSONA:` / `OBJECTIVE:` scaffold.
//   * `wp.combined` == `'${system}\n\n${user}'` — the anchor leads, the body is
//                       confined to the user channel, nothing leaks across.
//
// "Stub substrate" (D9.4): the runtime send path is
// `sub.send → LlmCall(roleId: role, inputs: {'prompt': body}) → facade →
// template.assemble`. `RoleTemplate.assemble` is the sole, pure, offline
// `WirePrompt` construction site (`InProcessTomBrainSubstrate.complete` calls it
// before touching any provider), so the test reproduces the wire text by
// calling `registry.get(role).assemble(inputs: {'prompt': body})` directly over
// the **real** file-backed role registry and the **real** rendered template
// body. (The full-substrate anchor/hash conformance is pinned separately by
// `b46_anchor_enforcement_conformance_test`.)

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
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        ReloadingRoleRegistry,
        RoleRegistry,
        WirePrompt,
        bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream;
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

/// A generous, deterministic input map covering the union of placeholders the
/// migrated templates reference (the §9 placeholder census). Unreferenced keys
/// are harmless; a referenced key the procedure always supplies is supplied
/// here. The conditional user slots use the special-renderer input keys
/// (`recall` / `priorTurns` / `open_todo_reminder`).
Map<String, Object?> _stubInputs() => <String, Object?>{
      'text': 'How does memory consolidate?',
      // The recall-conductor curation prompt's slots (§16).
      'prompt': 'How does memory consolidate?',
      // The memory-curator worth-storing prompt's slots (dream redesign part f).
      'answer': 'Memory consolidates during the dream cadences.',
      'known': '- the user works in dark mode',
      'surfaced': 'n_01 :: a surfaced node summary\nn_02 :: another summary',
      'intent': 'answer',
      'goal': 'Produce the best possible answer.',
      'successCriterion': 'covers X and Y',
      'statements': '- claim one\n- claim two',
      'statement': 'claim one',
      'analysis': 'Analysis: the answer must cover X and Y.',
      'sub_reasoning': 'Sub-reasoning: X depends on Z.',
      'rejection_context':
          'Attempt 1:\nDraft:\nthe bad draft\nCritique:\nREJECT missing Y\n\n',
      'kind': 'Conclusion',
      'extras': 'extra context here',
      'draft': 'the draft under review',
      'summary': 'a short summary',
      'summaries': '- summary one\n- summary two',
      'steps': '1. step one\n2. step two',
      'revision': 'the revised plan',
      'observation': 'an observed result',
      'findings': '- finding one',
      'check': 'the check to run',
      'canonical': 'the canonical form',
      'body': 'the artifact body',
      'recall': <String, Object?>{
        'nodes': <Object?>[
          <String, Object?>{
            'values': <String, Object?>{'text': 'fact A'},
          },
        ],
      },
      'priorTurns': <Object?>[
        <String, Object?>{'user': 'hello', 'assistant': 'hi there'},
      ],
      'open_todo_reminder': '<reminder>open todos: finish step 2</reminder>',
    };

/// The real file-backed role registry the run uses: the in-code roster overlaid
/// with the on-disk `roles/<role>.persona.md` + `<role>.objective.md` prose
/// (the same construction `provision_brain` performs).
RoleRegistry _fileBackedRoles(String configRoot) =>
    ReloadingRoleRegistry.reloading(
      base: bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream(),
      rolesDir: Directory('$configRoot/roles'),
    ).latest;

/// Every migrated `kind: prompt` id in the committed tree.
List<String> _migratedPromptIds(CognitionConfig cfg) => cfg.promptIds
    .where((id) => cfg.resolve(id).kind == PromptKind.prompt)
    .toList()
  ..sort();

void main() {
  late String configRoot;
  late CognitionConfig cfg;
  late RoleRegistry roles;

  setUpAll(() {
    configRoot = _cognitionRoot();
    cfg = CognitionConfigLoader.loadFromDir(configRoot);
    roles = _fileBackedRoles(configRoot);
  });

  group('§9 assembled-prompt parity — the system/user split contract', () {
    test('there is a migrated prompt to check (and §10 fragments now exist)',
        () {
      final ids = _migratedPromptIds(cfg);
      expect(ids, isNotEmpty);
      // §10 registered the first `kind: fragment` templates (the `todo_list` /
      // `continuation_hint` pair, shared by the memory and thinking loops), so
      // the `kind: prompt` roster is now a strict subset of the whole.
      expect(ids.length, lessThan(cfg.promptIds.length));
    });

    test('every migrated prompt assembles into anchor-led system + user body',
        () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final anchor = AssistantDedicationAnchor.text;

      for (final id in _migratedPromptIds(cfg)) {
        final ResolvedPrompt? resolved = await resolve(id, _stubInputs());
        expect(resolved, isNotNull, reason: '$id did not resolve');

        final role = resolved!.role;
        expect(roles.lookup(role), isNotNull,
            reason: '$id binds role "$role" which is not registered');

        // The production send path: LlmCall(roleId: role, inputs: {prompt}).
        final WirePrompt wp =
            roles.get(role).assemble(inputs: {'prompt': resolved.templateBody});

        // System channel is 100% role-supplied: anchor-led + scaffold.
        expect(wp.system, startsWith(anchor),
            reason: '$id: system channel must lead with the anchor');
        expect(wp.system, contains('PERSONA:'), reason: '$id: persona missing');
        expect(wp.system, contains('OBJECTIVE:'),
            reason: '$id: objective missing');

        // User channel is exactly the rendered template body, one `prompt:`
        // line — the pre-migration body, now in the user half.
        expect(wp.user, 'prompt: ${resolved.templateBody}',
            reason: '$id: user channel must be the rendered template body');

        // The split contract: anchor leads, body confined to user, nothing
        // leaks across the boundary.
        expect(wp.combined, '${wp.system}\n\n${wp.user}',
            reason: '$id: combined must be system + blank line + user');
      }
    });
  });

  group('§9 assembled-prompt parity — concrete golden (assembly)', () {
    const promptId = 'assist_user.answer_with_memory.assembly';

    test('the assembly wire text wraps the committed user body in the '
        'on-disk assistant_to_user role prose', () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved = await resolve(promptId, _stubInputs());
      expect(resolved, isNotNull);
      expect(resolved!.role, 'assistant_to_user');

      final WirePrompt wp =
          roles.get(resolved.role).assemble(inputs: {'prompt': resolved.templateBody});

      // The system half is sourced from the role prose files on disk
      // (D9.5) — read them independently and assert they reach the channel.
      final persona = File('$configRoot/roles/assistant_to_user.persona.md')
          .readAsStringSync()
          .trim();
      final objective = File('$configRoot/roles/assistant_to_user.objective.md')
          .readAsStringSync()
          .trim();
      expect(persona, isNotEmpty);
      expect(objective, isNotEmpty);
      expect(wp.system, contains(persona));
      expect(wp.system, contains(objective));
      expect(wp.system, startsWith(AssistantDedicationAnchor.text));

      // The user half carries the full committed assembly body verbatim,
      // including the `${tools.catalogue}` marker (SubstrateBridge renders it
      // later) and the `User prompt:` slot.
      expect(wp.user, 'prompt: ${resolved.templateBody}');
      expect(wp.user, contains(r'${tools.catalogue}'));
      expect(wp.user, contains('User prompt:'));

      // Combined wire text: anchor-led system, blank line, user body.
      expect(wp.combined, startsWith(AssistantDedicationAnchor.text));
      expect(wp.combined, '${wp.system}\n\n${wp.user}');
    });
  });

  group('§9 assembled-prompt parity — a dreaming prompt over its own role', () {
    const promptId = 'dreaming.extract.claim';

    test('a dreaming prompt assembles over its (non-assistant) role', () async {
      final resolve = buildPromptResolver(cfg, _builtins(configRoot));
      final ResolvedPrompt? resolved = await resolve(promptId, _stubInputs());
      expect(resolved, isNotNull);
      // Dreaming prompts bind a cognitive-agent role, not the user-facing one.
      expect(resolved!.role, isNot('assistant_to_user'));
      expect(roles.lookup(resolved.role), isNotNull);

      final WirePrompt wp =
          roles.get(resolved.role).assemble(inputs: {'prompt': resolved.templateBody});
      expect(wp.system, startsWith(AssistantDedicationAnchor.text));
      expect(wp.user, 'prompt: ${resolved.templateBody}');
      expect(wp.combined, '${wp.system}\n\n${wp.user}');
    });
  });
}
