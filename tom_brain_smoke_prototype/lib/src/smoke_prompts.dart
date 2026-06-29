// smokePromptResolver / smokeRouteChainResolver — the `sub.run` seams the
// end-to-end smoke binds onto the booted cognition.
//
// ── Why the smoke needs a prompt resolver ─────────────────────────────
//
// Increment 6 (`prompt_configuration.md` §6 / §12) migrated the normal answer
// path off its inline prompt builders onto `sub.run('…assembly', inputs:)`.
// `SubstrateBridge.run` therefore resolves a *registered* prompt through an
// injected `PromptResolver`; with no resolver bound it throws a `StateError`
// ("[run] cannot resolve a prompt"), which a procedure body surfaces as a failed
// run — an empty answer and no persisted Event/Conclusion. The production
// assembly (`tom_brain_run`'s `BrainProvisioner`) binds a cognition-root-backed
// resolver (`buildPromptResolver`); the smoke has no cognition tree, so it binds
// this lightweight stand-in instead — the smoke analogue of the
// `AnswerParityPrompts` test fixture the `tom_brain_procedure` boot suites use.
//
// ── Why the body text does not matter here ────────────────────────────
//
// The smoke runs against [SmokeSubstrate], which ignores the assembled prompt
// entirely and emits its canned `answerChunks`. So this resolver does not
// reproduce the production transcript byte-for-byte (the parity suites do that);
// it only has to return a *valid* [ResolvedPrompt] for every id `sub.run` /
// `sub.render` asks for, so the answer step reaches the substrate and the
// completion-confirmation / todo-list / continuation-hint fragments render. The
// answer prompt offers no tools (`tools: const []`), so the inner `tool_loop_v1`
// runs the substrate once and returns its plain answer — no tool-call parsing of
// the canned chunks.
//
// The completion-check prompt is pinned to `channel: thinking` (§9.2), exactly
// as the live `assist_user.yaml` config pins it, so the DONE/CONTINUE
// confirmation turn streams out-of-band and never leaks onto the user-visible
// answer stream.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show PromptResolver, ResolvedPrompt, RouteChainResolver;
import 'package:tom_brain_substrate/tom_brain_substrate.dart' show RouteEntry;

/// The user-facing role every smoke answer prompt assumes. The stub substrate
/// ignores it (role assembly is the real substrate's job, PE-7), so it is
/// metadata only — but it names the same role the production answer path uses.
const String _smokeAnswerRole = 'assistant_to_user';

/// The named LLM route the inner `tool_loop_v1`'s `sub.send` dispatches over.
/// [smokeRouteChainResolver] resolves it to an empty chain (the stub substrate
/// routes over its own canned stream regardless of the chain).
const String _smokeAnswerRoute = 'assistant';

/// A high inner-loop cap so a plain answer (no tool turn) terminates the loop on
/// its first pass, never on exhaustion.
const int _smokeMaxToolLoops = 64;

/// Builds the smoke's [PromptResolver]: resolves every prompt id to a valid
/// [ResolvedPrompt] so `sub.run` / `sub.render` never throws under the stub
/// substrate.
///
/// The render-only fragments (`*.todo_list`, `*.continuation_hint`) and the
/// `*.completion_check` confirmation prompt return plain, fully-interpolated
/// bodies (no unresolved `${…}` markers) so `sub.render` returns them verbatim;
/// `*.completion_check` additionally carries `channel: thinking`. Every other id
/// — the answer assembly and any recall/thinking-stage prompt — resolves to the
/// generic user-facing answer prompt.
PromptResolver smokePromptResolver() =>
    (String promptId, Map<String, Object?> inputs) async {
      final String? fragmentBody = _fragmentBodyFor(promptId, inputs);
      if (fragmentBody != null) {
        return ResolvedPrompt(
          role: _smokeAnswerRole,
          llmRoute: _smokeAnswerRoute,
          templateBody: fragmentBody,
          tools: const <Object?>[],
          maxToolLoops: _smokeMaxToolLoops,
          channel: promptId.endsWith('.completion_check') ? 'thinking' : null,
        );
      }
      return const ResolvedPrompt(
        role: _smokeAnswerRole,
        llmRoute: _smokeAnswerRoute,
        // The stub substrate ignores the body; a bare marker-free prompt is
        // enough for `sub.run` to reach `completeStream`.
        templateBody: 'Answer the user from the recalled memory.',
        tools: <Object?>[],
        maxToolLoops: _smokeMaxToolLoops,
      );
    };

/// The smoke's [RouteChainResolver]: every route resolves to an empty chain —
/// the stub substrate routes over its own canned stream regardless.
RouteChainResolver smokeRouteChainResolver() =>
    (String routeName) => const <RouteEntry>[];

/// Renders the body of the three plan-step-11 fragment registrations keyed off
/// the prompt-id suffix, or `null` for every other id (which falls through to
/// the generic answer prompt). The bodies are plain text with their input values
/// interpolated directly — no `${…}` markers — so `sub.render` returns them
/// unchanged.
String? _fragmentBodyFor(String promptId, Map<String, Object?> inputs) {
  if (promptId.endsWith('.todo_list')) {
    return _renderTodoEntries(inputs['todos']);
  }
  if (promptId.endsWith('.completion_check')) {
    final Object? text = inputs['text'];
    final Object? todoList = inputs['todo_list'];
    return 'You have just produced an answer for the user. Before it is '
        'delivered, confirm whether your work is complete.\n\n'
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

/// Renders the live `todo.list` entries into a `[x]`/`[ ]` checklist, joined by
/// newlines; the empty string for an empty or malformed listing.
String _renderTodoEntries(Object? todos) {
  if (todos is! List || todos.isEmpty) return '';
  final lines = <String>[];
  for (final entry in todos) {
    if (entry is! Map) continue;
    final box = entry['done'] == true ? '[x]' : '[ ]';
    lines.add('$box ${entry['text']}');
  }
  return lines.join('\n');
}
