// The §7.4 provisioner glue that backs the two `SubstrateBridge.run` seams over
// a loaded `CognitionConfig` (`prompt_configuration.md` §7.4, §12 step 6).
//
// `tom_brain_procedure`'s `sub.run('<id>')` resolves a prompt id through two
// injected host seams: a `PromptResolver` (id + inputs → a procedure-side
// `ResolvedPrompt` carrying the assembled template body + inherited settings)
// and a `RouteChainResolver` (route name → the substrate `RouteEntry` chain the
// loop's `sub.send` dispatches over). The engine itself owns neither — by
// principle 7 the bridged primitive API is the only surface a procedure touches,
// so the config-driven assembly lives here, in `tom_brain_run`, and is handed
// down at boot.
//
// This file builds both seams from a `CognitionConfig`:
//
//   * [buildPromptResolver] loads the registered prompt's template file from the
//     cognition root, renders the dynamic answer blocks (prior turns, recalled
//     memory, the open-todo reminder) byte-for-byte as the pre-§6 inline
//     builders did, resolves the §6 built-in placeholders, and maps the
//     inherited `PromptSettings` onto the procedure-side `ResolvedPrompt`. The
//     `${tools.catalogue}` marker is deliberately left in the body for
//     `SubstrateBridge.run` to render from the resolved tool set.
//
//   * [buildRouteChainResolver] maps a named route's `RoleRouteEntryConfig`
//     chain onto the substrate `RouteEntry` list (the one route-entry value type
//     in the workspace), mirroring `substrate_config.dart`'s policy builder.
//
// Injection-safety: the per-call inputs (`text`, the recall nodes, the prior
// turns, the reminder) are user-derived and may themselves contain `${…}`. The
// `PlaceholderResolver` re-scans every substitution, so binding those values as
// resolver bindings would re-interpret user `${…}` as placeholders. Instead the
// known input/marker tokens are swapped for null-byte guard sentinels *before*
// `resolve()` (so the resolver only ever expands genuine built-ins) and
// literal-restored *after* with a plain `replaceAll` that never re-scans.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart' as proc;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show RouteConditions, RouteEntry;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show PlaceholderExpressions, PlaceholderResolver;

import 'builtin_bindings.dart';
import 'cognition_config.dart';

/// Builds the `PromptResolver` seam over a loaded [config].
///
/// The returned function resolves a prompt id to a procedure-side
/// `ResolvedPrompt`: it loads the template at `<configFolder>/<templatePath>`
/// (the cognition root is [builtins].configFolder), renders the
/// `priorTurns` / `recall` / `open_todo_reminder` / `text` inputs into the
/// labelled blocks the pre-§6 builders produced, resolves the §6 built-ins
/// ([expressions] backs any `${{ … }}` form; [environment] backs `${env:NAME}`),
/// and maps the inherited settings on. An unregistered id yields `null`, which
/// `SubstrateBridge.run` turns into its typed `UnregisteredPromptException`
/// (§7.3).
proc.PromptResolver buildPromptResolver(
  CognitionConfig config,
  BrainBuiltins builtins, {
  PlaceholderExpressions? expressions,
  Map<String, String>? environment,
}) {
  return (String promptId, Map<String, Object?> inputs) async {
    final registered = config.prompts[promptId];
    if (registered == null) {
      // Honour the seam contract: a `null` return is the §7.3 "unregistered
      // prompt id is a hard error" signal `run` raises loudly on.
      return null;
    }

    final templatePath = _joinPath(builtins.configFolder, registered.templatePath);
    final rawTemplate = await File(templatePath).readAsString();

    final resolver = builtins.resolver(
      expressions: expressions,
      environment: environment,
    );

    final body = await _resolveProtected(
      rawTemplate,
      resolver,
      // The dynamic blocks are rendered here and restored *after* resolution so
      // user-controlled `${…}` in them is never re-scanned. The catalogue marker
      // restores to itself — `SubstrateBridge.run` renders it from the tool set.
      restore: _buildRestoreMap(inputs),
    );

    final settings = registered.settings;
    return proc.ResolvedPrompt(
      role: settings.role,
      llmRoute: settings.llm ?? config.registry.llmDefault,
      templateBody: body,
      tools: _expandTools(settings.tools),
      maxToolLoops: settings.maxToolLoops ?? 6,
      temperature: settings.temperature,
      responseFormat: settings.responseFormat,
    );
  };
}

/// Builds the `RouteChainResolver` seam over a loaded [config].
///
/// Maps a named route's ordered `RoleRouteEntryConfig` chain onto the substrate
/// `RouteEntry` list `sub.send` dispatches over. Throws
/// [UnknownLlmRouteException] for an unloaded route name (§8.1).
proc.RouteChainResolver buildRouteChainResolver(CognitionConfig config) {
  return (String routeName) => config
      .route(routeName)
      .route
      .map((entry) => RouteEntry(
            providerId: entry.providerId,
            model: entry.model,
            conditions: entry.conditions == null
                ? RouteConditions.empty
                : RouteConditions(
                    maxInputTokens: entry.conditions!.maxInputTokens),
          ))
      .toList(growable: false);
}

/// The literal `${tools.catalogue}` marker `SubstrateBridge.run` renders.
const String _catalogueToken = r'${tools.catalogue}';

/// The input keys that map onto a *purpose-built* block renderer rather than the
/// generic `${<key>}` → literal-string path: `priorTurns` renders the labelled
/// `${history}` conversation block, `recall` the `${recall}` memory preamble, and
/// `open_todo_reminder` the `${open_todo_reminder}` suffix. Every other input key
/// `k` binds `${k}` to its literal string value (§6 context bindings).
const Set<String> _speciallyRenderedKeys = {
  'priorTurns',
  'recall',
  'open_todo_reminder',
};

/// Builds the protected restore map for one prompt's [inputs].
///
/// The three [_speciallyRenderedKeys] map onto their own `${…}` tokens through
/// the block renderers (`priorTurns`→`${history}`, `recall`→`${recall}`,
/// `open_todo_reminder`→`${open_todo_reminder}`); the `${tools.catalogue}` marker
/// restores to itself for `SubstrateBridge.run`. Every *other* input key `k`
/// binds `${k}` to its literal string value, so the §6 thinking bindings
/// (`${text}` / `${analysis}` / `${sub_reasoning}` / `${draft}` /
/// `${rejection_context}`) — and any future per-call binding — resolve generically
/// without a bespoke renderer. All values are restored after resolution, so
/// user-controlled `${…}` inside them is never re-scanned.
Map<String, String> _buildRestoreMap(Map<String, Object?> inputs) {
  final restore = <String, String>{
    _catalogueToken: _catalogueToken,
    r'${history}': _renderPriorTurns(inputs['priorTurns']),
    r'${recall}': _renderRecall(inputs['recall']),
    r'${open_todo_reminder}': _renderReminder(inputs['open_todo_reminder']),
  };
  for (final entry in inputs.entries) {
    if (_speciallyRenderedKeys.contains(entry.key)) continue;
    restore['\${${entry.key}}'] = _stringOf(entry.value);
  }
  return restore;
}

/// Expands a prompt's resolved [tools] policy into the `tool.list` wire-shape
/// descriptor list the loop offers, mirroring `defaultToolCatalogue`'s shape
/// (`{name, group, description, input_schema}`).
///
/// `null` (unset anywhere in the inheritance chain) and `ToolsNone` both yield
/// the empty (`none` profile) catalogue.
List<Object?> _expandTools(ToolsSetting? tools) {
  switch (tools) {
    case null:
    case ToolsNone():
      return const <Object?>[];
    case ToolsAll():
      return proc.defaultToolCatalogue();
    case ToolsReadonly():
      return _catalogueWhere((tool) => tool.readOnly);
    case ToolsExplicit(:final names):
      final wanted = names.toSet();
      return _catalogueWhere((tool) => wanted.contains(tool.name));
  }
}

/// The basic tool set, filtered by [keep] and mapped to the `tool.list` wire
/// shape. Builds a throwaway registry so the filter reads the same `BrainTool`
/// descriptors `defaultToolCatalogue` emits.
List<Object?> _catalogueWhere(bool Function(proc.BrainTool tool) keep) {
  final registry = proc.ToolRegistry();
  proc.registerBasicTools(registry);
  return registry
      .list()
      .where(keep)
      .map((tool) => <String, Object?>{
            'name': tool.name,
            'group': tool.group.name,
            'description': tool.description,
            'input_schema': tool.inputSchema,
          })
      .toList(growable: false);
}

/// Resolves [template]'s built-in placeholders while protecting the keys of
/// [restore] from substitution and re-scanning.
///
/// Each [restore] key is swapped for a unique null-byte guard sentinel before
/// `resolve()` (the guard holds no `${`, so the resolver ignores it), then the
/// resolved text is literal-restored to the mapped value with a plain
/// `replaceAll` — no second scan, so user-controlled `${…}` in the restored
/// values can never be re-interpreted as placeholders.
Future<String> _resolveProtected(
  String template,
  PlaceholderResolver resolver, {
  required Map<String, String> restore,
}) async {
  final guardToValue = <String, String>{};
  var guarded = template;
  var index = 0;
  for (final entry in restore.entries) {
    final guard = '\u0000g$index\u0000';
    guarded = guarded.replaceAll(entry.key, guard);
    guardToValue[guard] = entry.value;
    index++;
  }

  var resolved = await resolver.resolve(guarded);
  guardToValue.forEach((guard, value) {
    resolved = resolved.replaceAll(guard, value);
  });
  return resolved;
}

/// Renders the prior-turn history block — byte-identical to the pre-§6
/// `_renderPriorTurns` (`Conversation so far:` label + `User:` / `Assistant:`
/// lines, or empty when there is no history).
String _renderPriorTurns(Object? priorTurns) {
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

/// Renders the recalled-memory block — byte-identical to the pre-§6 preamble
/// (`Relevant recalled memory:` label + one `- <text>` line per recall node, or
/// empty when nothing was recalled).
String _renderRecall(Object? recall) {
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
  return context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';
}

/// Renders the open-todo reminder suffix — byte-identical to the pre-§6
/// `_appendOpenTodoReminder` framing (`\n<reminder>\n`, or empty).
String _renderReminder(Object? reminder) =>
    (reminder is String && reminder.isNotEmpty) ? '\n$reminder\n' : '';

/// Stringifies a prompt input, rendering `null` as the empty string.
String _stringOf(Object? value) => value == null ? '' : '$value';

/// Joins a cognition-root [dir] with a relative [rel] template path. POSIX
/// separators (the cognition config paths are `/`-based); a trailing separator
/// on [dir] is collapsed.
String _joinPath(String dir, String rel) {
  if (dir.isEmpty) return rel;
  final trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return '$trimmed/$rel';
}
