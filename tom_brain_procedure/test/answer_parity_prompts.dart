// Shared parity `PromptResolver` for the `answer_with_memory_v1` suites.
//
// Increment 6 (`prompt_configuration.md` §6 / §12) migrated the normal answer
// path off its inline prompt builders onto `sub.run('…assembly', inputs:)`. The
// procedure no longer assembles its own transcript — a registered prompt's
// template + the injected `PromptResolver` do. The acceptance suites still want
// to assert *the same assembled prompt* reaches the substrate (parity with the
// pre-migration behaviour, §12), so this helper stands in for the host
// `PromptResolver`, reproducing the exact text the deleted `_assemblePrompt` /
// `_renderPriorTurns` / `_todoDisciplineBlock` builders produced.
//
// What it reproduces (verbatim from the pre-increment-6 body):
//   `${tools.catalogue}` marker  — the `SubstrateBridge.run` renderer fills it
//                                  from [tools] with the identical catalogue
//                                  text the old `_renderToolCatalogue` emitted,
//                                  so the marker is left in place here;
//   todo-discipline block        — the `todo.*` tool tutorial every answering
//                                  prompt carries (§4);
//   `Conversation so far:` block — the prior-turn history;
//   `Relevant recalled memory:`  — one line per recalled node `values.text`;
//   open-todo reminder           — folded in on a re-entry pass (was the
//                                  `_appendOpenTodoReminder` suffix);
//   `User prompt:\n<text>`       — the live inbound prompt.
//
// The tool *set* is no longer a procedure input (§7.4 resolves it from the
// prompt's tool policy). A suite that wants the substrate to see a catalogue
// sets [tools] before invoking; the resolver surfaces it as
// `ResolvedPrompt.tools`, exactly as a config-backed resolver would expand a
// prompt's tool policy. The real `tool_loop_v1` then runs the loop, so loop /
// tool-execution behaviour is genuinely exercised — only prompt assembly is
// faked here.

import 'package:tom_brain_substrate/tom_brain_substrate.dart' show RouteEntry;

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show PromptResolver, ResolvedPrompt, RouteChainResolver;

/// A configurable stand-in for the host `PromptResolver` + `RouteChainResolver`
/// the `SubstrateBridge` is wired with at boot. Construct one per test, mutate
/// [tools] / [role] / [route] / [maxToolLoops] before invoking, and pass
/// [resolver] + [routeChainOf] to `SubstrateBridge(...)`.
class AnswerParityPrompts {
  /// The resolved tool descriptor list (the `tool.list` wire shape) the answer
  /// prompt offers — empty means "no tools" (the `none` profile). The
  /// `SubstrateBridge.run` renderer turns this into the `${tools.catalogue}`
  /// block; `tool_loop_v1` uses it as the executable tool set.
  List<Object?> tools = const <Object?>[];

  /// The role the answer prompt assumes — the user-facing `assistant_to_user`,
  /// matching the pre-migration `sub.llm(role: 'assistant_to_user')` call.
  String role = 'assistant_to_user';

  /// The named LLM route `tool_loop_v1`'s `sub.send` dispatches over. The fake
  /// substrates ignore the route, so any name resolving through [routeChainOf]
  /// works; the route chain itself is empty (the substrate doubles never
  /// inspect it).
  String route = 'assistant';

  /// The inner tool-loop cap. High by default so the loop terminates on a plain
  /// answer (no tool turn), never on exhaustion, matching the pre-migration
  /// effectively-unlimited behaviour.
  int maxToolLoops = 64;

  /// The optional decoding temperature threaded onto the resolved prompt.
  double? temperature;

  /// Every `(id, inputs)` pair the resolver was asked for, in dispatch order.
  /// The thinking suites assert against this to prove the re-entry templates
  /// (`*_reentry`) are selected on pass ≥2 and that the accumulated rejection
  /// history flows into them via `${rejection_context}` (§9).
  final List<({String id, Map<String, Object?> inputs})> requests =
      <({String id, Map<String, Object?> inputs})>[];

  /// The `PromptResolver` seam: resolves any id to the parity answer prompt.
  ///
  /// The id selects the **role** (and tool set) the way the real config-backed
  /// resolver does — the thinking stages route to `analyser` / `sub_thinker` /
  /// `evaluator`, everything else (the `synthesis*` drafts and the
  /// `answer_with_memory.assembly`) to the user-facing [role]. The body is the
  /// same parity transcript for every id (the substrate doubles key off the role
  /// and return canned text, so the body is not asserted on for the thinking
  /// stages). The inputs are the §6 placeholder bindings the procedures pass.
  PromptResolver get resolver => (String promptId, Map<String, Object?> inputs) async {
        requests.add((id: promptId, inputs: Map<String, Object?>.of(inputs)));
        // The plan-step-11 fragments / completion-check are tool-less prompts
        // (the `none` profile) rendered through the `todo_list` / `completion_check`
        // / `continuation_hint` registrations. They are resolved the same way the
        // config-backed resolver resolves them: a fragment/template body with no
        // `${tools.catalogue}` marker and an empty tool set.
        final fragmentBody = _fragmentBodyFor(promptId, inputs);
        if (fragmentBody != null) {
          // The completion_check runs through `sub.run` → `tool_loop_v1` →
          // `sub.send`, so its DONE/CONTINUE completion *streams*. The live
          // config pins it to `channel: thinking` (assist_user.yaml) so the
          // confirmation turn never leaks onto the user-visible answer stream;
          // the parity resolver mirrors that. The `todo_list` /
          // `continuation_hint` fragments are `sub.render`-only (no completion),
          // so they carry no channel.
          final channel =
              promptId.endsWith('.completion_check') ? 'thinking' : null;
          return ResolvedPrompt(
            role: role,
            llmRoute: route,
            templateBody: fragmentBody,
            tools: const <Object?>[],
            maxToolLoops: maxToolLoops,
            temperature: temperature,
            channel: channel,
          );
        }
        final text = inputs['text'];
        final recall = inputs['recall'];
        final priorTurns = inputs['priorTurns'];
        final reminder = inputs['open_todo_reminder'];
        return ResolvedPrompt(
          role: _roleForId(promptId),
          llmRoute: route,
          templateBody: _assemble(recall, text, priorTurns, reminder),
          tools: _toolsForId(promptId),
          maxToolLoops: maxToolLoops,
          temperature: temperature,
        );
      };

  /// Reproduces the rendered body of the three plan-step-11 registrations —
  /// `todo_list`, `completion_check`, `continuation_hint` — keyed off the prompt
  /// id suffix, mirroring the live config templates
  /// (`config/bomber/cognition/assist_user/answer_with_memory.{todo_list,
  /// completion_check.user,continuation_hint}.md`). Returns `null` for every other
  /// id (the assembly / thinking-stage prompts), which fall through to the parity
  /// transcript. The `completion_check` body begins with [confirmationSentinel]
  /// and embeds the `todo_list` input, so the scripted substrate detects the
  /// confirmation turn and the live todo list surfaces in the prompt it sees.
  static String? _fragmentBodyFor(String promptId, Map<String, Object?> inputs) {
    if (promptId.endsWith('.todo_list')) {
      return _renderTodoEntries(inputs['todos']);
    }
    if (promptId.endsWith('.completion_check')) {
      final text = inputs['text'];
      final todoList = inputs['todo_list'];
      return '$confirmationSentinel Before it is delivered, confirm whether '
          'your work is complete.\n\n'
          'The user asked:\n$text\n\n'
          'Your current task list:\n${todoList ?? ''}\n\n'
          'If your latest answer fully satisfies the request and no task still '
          'needs doing, reply with DONE as the first word. If there is still '
          'work to do, reply with CONTINUE as the first word.';
    }
    if (promptId.endsWith('.continuation_hint')) {
      return 'You indicated your previous answer was not yet complete. Review '
          'your task list, continue the outstanding work, and mark each task '
          'done with todo.update as you finish it.';
    }
    return null;
  }

  /// The opening sentinel of the `completion_check` template — the scripted
  /// substrate keys the DONE/CONTINUE confirmation turn off it (kept in sync with
  /// `answer_with_memory.completion_check.user.md`).
  static const String confirmationSentinel =
      'You have just produced an answer for the user.';

  /// Reproduces the live resolver's `${todo_entries}` rendering (the `todo_list`
  /// fragment): each `{text, done}` entry as `[x]`/`[ ] <text>`, joined by
  /// newlines; the empty string for an empty or malformed listing.
  static String _renderTodoEntries(Object? todos) {
    if (todos is! List || todos.isEmpty) return '';
    final lines = <String>[];
    for (final entry in todos) {
      if (entry is! Map) continue;
      final box = entry['done'] == true ? '[x]' : '[ ]';
      lines.add('$box ${entry['text']}');
    }
    return lines.join('\n');
  }

  /// Maps a thinking-stage prompt id onto the substrate role its config assigns
  /// (`prompt_configuration.md` §5.3): the analysis stages run as `analyser`,
  /// the sub-reasoning stage as `sub_thinker`, the critique as `evaluator`, and
  /// everything else — the tool-enabled `synthesis` / `synthesis_reentry` drafts
  /// and the `answer_with_memory.assembly` prompt — inherits the user-facing
  /// [role].
  String _roleForId(String promptId) {
    if (promptId.endsWith('.analysis') ||
        promptId.endsWith('.analysis_reentry')) {
      return 'analyser';
    }
    if (promptId.endsWith('.sub_think')) return 'sub_thinker';
    if (promptId.endsWith('.critique')) return 'evaluator';
    // The recall conductor's curation prompt runs read-only under the
    // `recaller` persona (assist_user.yaml `recall_conductor.curate`), so the
    // curation suites can key the conductor turn off the resolved role.
    if (promptId.endsWith('.curate')) return 'recaller';
    return role;
  }

  /// Maps a thinking-stage prompt id onto its resolved tool set: the `critique`
  /// is a no-tool `evaluator` verdict (empty catalogue), every other stage
  /// surfaces the configured [tools] (the synthesis stages run `tools: all`; the
  /// readonly reasoning stages still carry a non-empty catalogue in production).
  List<Object?> _toolsForId(String promptId) {
    if (promptId.endsWith('.critique')) return const <Object?>[];
    return tools;
  }

  /// The `RouteChainResolver` seam: every route resolves to an empty chain —
  /// the substrate doubles route over their own canned stream regardless.
  RouteChainResolver get routeChainOf =>
      (String routeName) => const <RouteEntry>[];

  /// Reproduces the pre-increment-6 `_assemblePrompt` output, leaving the
  /// `${tools.catalogue}` marker for `SubstrateBridge.run` to render.
  static String _assemble(
    Object? recall,
    Object? text,
    Object? priorTurns,
    Object? reminder,
  ) {
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
    final preamble =
        context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';

    final reminderBlock = (reminder is String && reminder.isNotEmpty)
        ? '\n$reminder\n'
        : '';

    return '$catalogueMarker${_todoDisciplineBlock()}$history$preamble'
        'User prompt:\n$text$reminderBlock';
  }

  /// Reproduces the pre-increment-6 `_todoDisciplineBlock`.
  static String _todoDisciplineBlock() {
    return 'Task tracking — you MUST manage your own todo list with these tools:\n'
        '  call:todo.add{text: "Read CLAUDE.md"}     -> returns {id: "t1"}\n'
        '  call:todo.list{}                          -> lists entries with their ids\n'
        '  call:todo.update{id: "t1", done: true}    -> mark an entry finished\n'
        '  call:todo.remove{id: "t1"}                -> drop an entry by its id\n'
        'Always use the id returned by todo.add — never the text — for '
        'update/remove. Before you start, break the request into todos with '
        'todo.add. As you complete each step, mark it done with todo.update. You '
        'are NOT finished until every todo is done; do not claim completion while '
        'open todos remain.\n\n';
  }

  /// Reproduces the pre-increment-6 `_renderPriorTurns`.
  static String _renderPriorTurns(Object? priorTurns) {
    if (priorTurns is! List || priorTurns.isEmpty) return '';
    var rendered = '';
    for (final turn in priorTurns) {
      if (turn is! Map) continue;
      final user = turn['user'];
      final assistant = turn['assistant'];
      if (user != null && '$user'.isNotEmpty) {
        rendered += 'User: $user\n';
      }
      if (assistant != null && '$assistant'.isNotEmpty) {
        rendered += 'Assistant: $assistant\n';
      }
    }
    return rendered.isEmpty ? '' : 'Conversation so far:\n$rendered\n';
  }
}
