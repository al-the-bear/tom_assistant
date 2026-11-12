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
import 'package:tom_brain_config/tom_brain_config.dart';

/// Builds the `PromptResolver` seam over a loaded [config].
///
/// The returned function resolves a prompt id to a procedure-side
/// `ResolvedPrompt`: it loads the resolved template file(s) under
/// [builtins].configFolder — a `kind: prompt` `<stem>.system.md` +
/// `<stem>.user.md` pair (an absent half → empty string) joined into one body,
/// or a `kind: fragment` single `<stem>.md` (§8 step 8) — renders the
/// `priorTurns` / `recall` / `open_todo_reminder` / `text` inputs into the
/// labelled blocks the pre-§6 builders produced, resolves the §6 built-ins
/// ([expressions] backs any `${{ … }}` form; [environment] backs `${env:NAME}`),
/// and maps the inherited settings on. An unregistered id yields `null`, which
/// `SubstrateBridge.run` turns into its typed `UnregisteredPromptException`
/// (§7.3).
///
/// [fallThroughOnMissing] selects how a registered prompt whose template file is
/// **absent** on disk is handled. The default (`false`) is the standalone-disk
/// contract: an absent present-flagged file is a config error and the underlying
/// read throws. `true` is the *overlay* contract used when this disk resolver is
/// layered over a bundle (CLI plan step 3): an absent file yields `null`, so the
/// `LayeredPromptResolver` falls through to the bundled base — the same
/// "shadow when present, base otherwise" rule the profile-overlay resolver uses.
proc.PromptResolver buildPromptResolver(
  CognitionConfig config,
  BrainBuiltins builtins, {
  PlaceholderExpressions? expressions,
  Map<String, String>? environment,
  bool fallThroughOnMissing = false,
}) {
  return (String promptId, Map<String, Object?> inputs) async {
    final registered = config.prompts[promptId];
    if (registered == null) {
      // Honour the seam contract: a `null` return is the §7.3 "unregistered
      // prompt id is a hard error" signal `run` raises loudly on.
      return null;
    }

    // In soft (overlay) mode a missing disk template is a fall-through (`null`);
    // in the default standalone-disk mode the read fails fast on a missing
    // present-flagged file.
    final String? rawTemplate = fallThroughOnMissing
        ? await _loadOverlayTemplate(registered.template, builtins.configFolder)
        : await _loadRawTemplate(registered.template, builtins.configFolder);
    if (rawTemplate == null) return null;

    return _renderPrompt(
      registered,
      rawTemplate,
      inputs,
      config,
      builtins,
      expressions: expressions,
      environment: environment,
    );
  };
}

/// Builds the `PromptResolver` seam over a compiled-in [bundlePrompts] map
/// (`path → verbatim template source`), the prompt-template analogue of
/// `BundledProcedureStore` (CLI plan step 3).
///
/// The standalone `tom_brain` CLI ships its `cognition/` templates compiled into
/// the executable rather than on disk; this resolver renders a registered
/// prompt's body from that bundle instead of from [builtins].configFolder. It
/// addresses each template by the *same* cognition-root-relative path the
/// registered `TemplateResolution` carries (so a disk resolver and a bundled
/// resolver agree on the key for one prompt id, which is what makes
/// disk-overlays-bundle "by template id" composition work). The bundle is keyed
/// by path, not by disk `present` flags — a bundle-only deployment has no disk
/// to flag presence against, so the lookup ignores `present` entirely.
///
/// Returns `null` for an unregistered id OR a registered id whose template
/// path is not in the bundle — the `LayeredPromptResolver` fall-through signal.
proc.PromptResolver buildBundledPromptResolver(
  CognitionConfig config,
  BrainBuiltins builtins,
  Map<String, String> bundlePrompts, {
  PlaceholderExpressions? expressions,
  Map<String, String>? environment,
}) {
  final bundle = Map<String, String>.unmodifiable(bundlePrompts);
  return (String promptId, Map<String, Object?> inputs) async {
    final registered = config.prompts[promptId];
    if (registered == null) return null;

    final rawTemplate = _loadBundleTemplate(registered.template, bundle);
    if (rawTemplate == null) return null;

    return _renderPrompt(
      registered,
      rawTemplate,
      inputs,
      config,
      builtins,
      expressions: expressions,
      environment: environment,
    );
  };
}

/// Renders a loaded [rawTemplate] for a [registered] prompt into the
/// procedure-side `ResolvedPrompt` — the shared tail of every resolver seam this
/// file builds (base disk, profile overlay, and compiled bundle).
///
/// It seeds a built-in resolver, renders the dynamic blocks and the literal
/// `${k}` / `${k?}` context bindings (restored *after* resolution so
/// user-controlled `${…}` is never re-scanned), resolves the §6 built-ins, and
/// maps the inherited settings on (its `llm:` route falling back to the registry
/// default when unset). The `${tools.catalogue}` marker is left in the body for
/// `SubstrateBridge.run` to render from the resolved tool set.
Future<proc.ResolvedPrompt> _renderPrompt(
  ResolvedPrompt registered,
  String rawTemplate,
  Map<String, Object?> inputs,
  CognitionConfig config,
  BrainBuiltins builtins, {
  PlaceholderExpressions? expressions,
  Map<String, String>? environment,
}) async {
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
  // The prompt's resolved `llm:` route — its committed binding, or whatever a
  // live `/switch_model` rebound it to (the command mutates this same config,
  // §request e), falling back to the registry default when unset.
  final route = settings.llm ?? config.registry.llmDefault;
  return proc.ResolvedPrompt(
    role: settings.role,
    llmRoute: route,
    templateBody: body,
    tools: _expandTools(settings.tools),
    maxToolLoops: settings.maxToolLoops ?? 6,
    temperature: settings.temperature,
    responseFormat: settings.responseFormat,
    channel: settings.channel,
  );
}

/// Builds the `OverlayResolverFactory` seam over a loaded [config]
/// (`session_configuration.md` § 5.2, plan step 8 (b)).
///
/// A profile may name a *template overlay* — a sibling tree under
/// `<cognition.root>/overlays/<name>/` that shadows individual prompt templates
/// while inheriting everything else from the base registry. The engine binds the
/// overlay per run by calling the returned factory with the run's
/// `ResolvedProfile.templateOverlay` and layering the result over the base
/// [buildPromptResolver] in a `LayeredPromptResolver`.
///
/// The returned factory maps an overlay *name* to a `PromptResolver` that loads
/// the *same* registered prompt's template file(s) from the overlay tree instead
/// of the base [builtins].configFolder. When the overlay tree carries **no** file
/// for a prompt id the resolver returns `null` — the layered resolver then falls
/// through to the base, so an overlay shadows only the prompts it actually
/// redefines ("missing-id shadow ignored"). When it does carry the file(s), the
/// body is rendered with the identical built-in / block resolution the base path
/// uses, so an overlaid template behaves byte-for-byte like a base one. The file
/// is read live on every call, so an edited overlay template is picked up on the
/// next run (the same live-edit contract the base resolver honours).
proc.OverlayResolverFactory buildOverlayPromptResolver(
  CognitionConfig config,
  BrainBuiltins builtins, {
  PlaceholderExpressions? expressions,
  Map<String, String>? environment,
}) {
  return (String overlayName) {
    final overlayRoot =
        _joinPath(_joinPath(builtins.configFolder, 'overlays'), overlayName);
    return (String promptId, Map<String, Object?> inputs) async {
      final registered = config.prompts[promptId];
      if (registered == null) return null;

      // Only shadow the base when the overlay tree actually provides this
      // prompt's template file(s); otherwise return `null` so the
      // `LayeredPromptResolver` falls through to the base registry.
      final rawTemplate =
          await _loadOverlayTemplate(registered.template, overlayRoot);
      if (rawTemplate == null) return null;

      return _renderPrompt(
        registered,
        rawTemplate,
        inputs,
        config,
        builtins,
        expressions: expressions,
        environment: environment,
      );
    };
  };
}

/// Builds the `RouteChainResolver` seam over a loaded [config].
///
/// Maps a named route's ordered `RoleRouteEntryConfig` chain onto the substrate
/// `RouteEntry` list `sub.send` dispatches over. Throws
/// [UnknownLlmRouteException] for an unloaded route name (§8.1).
proc.RouteChainResolver buildRouteChainResolver(CognitionConfig config) {
  return (String routeName) {
    // Reads the route fresh from the live `config.llmRoutes` map, so a route a
    // `/switch_model` added (or rebound) resolves the moment the switch lands
    // (§request e) — the command mutates this same config.
    return config
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
  };
}

/// The literal `${tools.catalogue}` marker `SubstrateBridge.run` renders.
const String _catalogueToken = r'${tools.catalogue}';

/// The input keys that map onto a *purpose-built* block renderer rather than the
/// generic `${<key>}` → literal-string path: `priorTurns` and `compactedSummary`
/// together render the labelled `${history}` conversation block (the summary
/// first, then the verbatim turns — `tom_brain_procedure_specification.md` § 22.5
/// / § 22.7), `recall` the `${recall}` memory preamble, `open_todo_reminder` the
/// `${open_todo_reminder}` suffix, and `todos` the `${todo_entries}` checklist
/// (the `todo_list` fragment, §10). Every other input key `k` binds `${k}` (and
/// the optional `${k?}` form) to its literal string value (§6 context bindings).
const Set<String> _speciallyRenderedKeys = {
  'priorTurns',
  'compactedSummary',
  'recall',
  'open_todo_reminder',
  'todos',
};

/// Builds the protected restore map for one prompt's [inputs].
///
/// The [_speciallyRenderedKeys] map onto their own `${…}` tokens through the
/// block renderers (`priorTurns` + `compactedSummary`→`${history}`,
/// `recall`→`${recall}`, `open_todo_reminder`→`${open_todo_reminder}`,
/// `todos`→`${todo_entries}`); the
/// `${tools.catalogue}` marker restores to itself for `SubstrateBridge.run`. Every
/// *other* input key `k` binds **both** `${k}` and the optional `${k?}` form to
/// its literal string value, so the §6 thinking bindings (`${text}` /
/// `${analysis}` / `${sub_reasoning}` / `${draft}` / `${rejection_context}`) — and
/// any future per-call binding, whether the template writes the required or the
/// optional placeholder form — resolve generically without a bespoke renderer
/// (§10: the `completion_check` template's `${todo_list?}` slot). When the key is
/// *absent* from [inputs] the optional `${k?}` form is left for the resolver,
/// which renders it empty (its §1 optional-placeholder contract); the required
/// `${k}` form surfaces as an unbound-built-in error, the intended signal for a
/// missing required input. All bound values are restored after resolution, so
/// user-controlled `${…}` inside them is never re-scanned.
Map<String, String> _buildRestoreMap(Map<String, Object?> inputs) {
  final restore = <String, String>{
    _catalogueToken: _catalogueToken,
    r'${history}': _renderHistory(
      inputs['compactedSummary'],
      inputs['priorTurns'],
    ),
    r'${recall}': _renderRecall(inputs['recall']),
    r'${open_todo_reminder}': _renderReminder(inputs['open_todo_reminder']),
    r'${todo_entries}': _renderTodoEntries(inputs['todos']),
  };
  for (final entry in inputs.entries) {
    if (_speciallyRenderedKeys.contains(entry.key)) continue;
    final value = _stringOf(entry.value);
    restore['\${${entry.key}}'] = value;
    restore['\${${entry.key}?}'] = value;
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

/// Renders the full `${history}` block: the compacted summary first (whenever a
/// session has compacted at least once), then the verbatim prior turns
/// (`tom_brain_procedure_specification.md` § 22.5 / § 22.7 — `${history}` is the
/// compacted summary + verbatim turns). When [compactedSummary] is empty the
/// result is byte-identical to the pre-compaction block (just the prior turns),
/// so the no-summary case renders exactly as before.
String _renderHistory(Object? compactedSummary, Object? priorTurns) =>
    '${_renderCompactedSummary(compactedSummary)}'
    '${_renderPriorTurns(priorTurns)}';

/// Renders the compacted-summary block — the distilled prose for everything
/// older than the verbatim window, labelled and followed by a blank line so it
/// reads above the `Conversation so far:` turns. The empty string when nothing
/// has been compacted yet (the `${history}` block then carries only the raw
/// turns, byte-stable with the pre-compaction rendering).
String _renderCompactedSummary(Object? compactedSummary) =>
    (compactedSummary is String && compactedSummary.isNotEmpty)
        ? 'Summary of earlier conversation:\n$compactedSummary\n\n'
        : '';

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

/// Renders the live session todo store as the `${todo_entries}` checklist for the
/// `todo_list` fragment (§10). [todos] is the `todo.list` result list — each
/// entry a `{text, done}` map rendered as `[x]`/`[ ] <text>`, joined by newlines.
/// An empty or malformed listing renders the **empty string** (§10: "renders an
/// empty string for no todos"), replacing the pre-§10 Dart builder's
/// `(your task list is currently empty)` sentinel — the fragment now owns the
/// rendering, and the caller frames the empty case.
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

/// Stringifies a prompt input, rendering `null` as the empty string.
String _stringOf(Object? value) => value == null ? '' : '$value';

/// Loads a resolved [template] into one raw body under the cognition-root
/// [configFolder] (§8 step 8).
///
/// A [PromptTemplateFiles] pair reads each present half (an absent half → the
/// empty string) and joins them with the same rule the substrate `WirePrompt`
/// uses for a no-native-separation provider — `system`, then a blank line, then
/// `user`, with empty parts dropped. So a prompt whose system half is absent
/// (every live `assist_user` / `dreaming` template until the §9 content split)
/// yields exactly its `<stem>.user.md` bytes — byte-identical to the pre-§8
/// single template file. A [FragmentTemplateFiles] reads its single file.
Future<String> _loadRawTemplate(
  TemplateResolution template,
  String configFolder,
) async {
  switch (template) {
    case PromptTemplateFiles(:final system, :final user):
      final String systemText = system.present
          ? await File(_joinPath(configFolder, system.path)).readAsString()
          : '';
      final String userText = user.present
          ? await File(_joinPath(configFolder, user.path)).readAsString()
          : '';
      if (systemText.isEmpty) return userText;
      if (userText.isEmpty) return systemText;
      return '$systemText\n\n$userText';
    case FragmentTemplateFiles(:final file):
      return File(_joinPath(configFolder, file.path)).readAsString();
  }
}

/// Loads a resolved [template] from an [overlayRoot] tree, returning `null` when
/// the overlay carries **no** file for it (plan step 8 (b)).
///
/// The mirror of [_loadRawTemplate] for the overlay path, with one difference: a
/// base load reads a registered template whose presence the config guarantees, so
/// an absent file is a config error; an overlay load reads an *optional* shadow,
/// so an absent file is the normal "this overlay does not redefine this prompt"
/// case and must fall through (`null`) rather than throw. A [PromptTemplateFiles]
/// pair shadows when *either* half exists in the overlay (the present halves are
/// read, an absent half → empty, joined by the same rule as the base); a
/// [FragmentTemplateFiles] shadows only when its single file exists.
Future<String?> _loadOverlayTemplate(
  TemplateResolution template,
  String overlayRoot,
) async {
  switch (template) {
    case PromptTemplateFiles(:final system, :final user):
      final File? systemFile =
          system.present ? File(_joinPath(overlayRoot, system.path)) : null;
      final File? userFile =
          user.present ? File(_joinPath(overlayRoot, user.path)) : null;
      final bool hasSystem = systemFile != null && await systemFile.exists();
      final bool hasUser = userFile != null && await userFile.exists();
      if (!hasSystem && !hasUser) return null;
      final String systemText =
          hasSystem ? await systemFile.readAsString() : '';
      final String userText = hasUser ? await userFile.readAsString() : '';
      if (systemText.isEmpty) return userText;
      if (userText.isEmpty) return systemText;
      return '$systemText\n\n$userText';
    case FragmentTemplateFiles(:final file):
      final File f = File(_joinPath(overlayRoot, file.path));
      if (!await f.exists()) return null;
      return f.readAsString();
  }
}

/// Loads a resolved [template] from a compiled-in [bundle] (`path → source`),
/// returning `null` when the bundle carries **no** source for it (CLI plan
/// step 3).
///
/// The bundle analogue of [_loadOverlayTemplate]: it addresses each half by the
/// registered template's cognition-root-relative path, exactly the key a disk
/// resolver would read the file from — so disk and bundle agree on the key for
/// one prompt id. Unlike the disk loaders it ignores the `present` flags (a
/// bundle-only deployment has no disk to flag presence against); presence in the
/// [bundle] map *is* the existence test. A [PromptTemplateFiles] pair is served
/// when *either* half is in the bundle (the present halves are read, an absent
/// half → empty, joined by the same rule as the base); a [FragmentTemplateFiles]
/// only when its single file is in the bundle.
String? _loadBundleTemplate(
  TemplateResolution template,
  Map<String, String> bundle,
) {
  switch (template) {
    case PromptTemplateFiles(:final system, :final user):
      final String? systemSrc = bundle[system.path];
      final String? userSrc = bundle[user.path];
      if (systemSrc == null && userSrc == null) return null;
      final String systemText = systemSrc ?? '';
      final String userText = userSrc ?? '';
      if (systemText.isEmpty) return userText;
      if (userText.isEmpty) return systemText;
      return '$systemText\n\n$userText';
    case FragmentTemplateFiles(:final file):
      return bundle[file.path];
  }
}

/// Joins a cognition-root [dir] with a relative [rel] template path. POSIX
/// separators (the cognition config paths are `/`-based); a trailing separator
/// on [dir] is collapsed.
String _joinPath(String dir, String rel) {
  if (dir.isEmpty) return rel;
  final trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return '$trimmed/$rel';
}
