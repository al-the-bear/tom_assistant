// The `/switch_model` command (request e): a change to the normal cognition
// configuration on disk, not a side-channel override.
//
// `/switch_model <prompt-id> <provider:model>` re-points one cognition prompt at
// a chosen model. There is no per-prompt "model" field in the config — a prompt
// names an `llm:` *route* (§8), and a route names the model. So a switch is
// expressed in the two normal config surfaces it already has:
//
//   1. A single-entry route file `cognition/<llm>/<prompt-id>.yaml` carrying the
//      chosen `provider:model` (authored here, comment-headed). Per-prompt, so
//      re-pointing one prompt never moves the others that share the inherited
//      route.
//   2. That prompt's `llm:` binding in its main-procedure config file, set to the
//      new route via comment-preserving `yaml_edit` — only the one node changes;
//      every comment, sibling, and formatting choice in the hand-authored file is
//      left untouched.
//
// The same change is applied to the in-process [CognitionConfig] (its `prompts`
// and `llmRoutes` maps, which the two `sub.run` resolvers read fresh on every
// call), so the switch takes effect on the next run *and* — because it is now
// committed configuration the standard loader reads at boot — survives a restart.
// No override registry, no `model_overrides.yaml`, no synthetic route.
//
// This file holds the two pieces that seam needs:
//
//   * [CognitionModelWriter] — writes the route file, edits the prompt's `llm:`
//     binding, and mutates the live [CognitionConfig].
//   * [TomBrainModelSwitcher] — the run-layer `TelegramModelSwitcher` impl: it
//     validates the prompt-id against the loaded [CognitionConfig] and the
//     `<providerId>:<model>` id against the [SubstrateConfig], then applies the
//     change through the writer and renders the outcome.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show TelegramModelSwitcher;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show RoleRouteEntryConfig, SubstrateConfig;
import 'package:yaml_edit/yaml_edit.dart';

import 'cognition_config.dart';
import 'llm_route_config.dart';

/// Thrown when a `/switch_model` change cannot be written to the cognition
/// config on disk — a missing main-procedure file, or an unparseable one.
class CognitionModelWriteException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const CognitionModelWriteException(this.message);

  @override
  String toString() => 'CognitionModelWriteException: $message';
}

/// Writes a `/switch_model` selection into the normal cognition configuration —
/// both on disk (a route file + the prompt's `llm:` binding) and in the live
/// [config] (so the change applies without a restart).
///
/// Bound to the cognition root directory ([cognitionRoot], the folder holding
/// `registry.yaml`) and the loaded [config] the process booted from. The writer
/// owns the on-disk encoding of a per-prompt model choice; [TomBrainModelSwitcher]
/// owns the validation that precedes it.
final class CognitionModelWriter {
  /// The cognition root directory (holds `registry.yaml`, the `llm/` folder, and
  /// the main-procedure config files).
  final String cognitionRoot;

  /// The loaded cognition config this writer mutates in place so a switch applies
  /// to the running process.
  final CognitionConfig config;

  /// Binds the writer to the [cognitionRoot] and the live [config].
  const CognitionModelWriter({
    required this.cognitionRoot,
    required this.config,
  });

  /// The route name a switched [promptId] is pointed at: the prompt id itself,
  /// so each switched prompt owns a dedicated single-entry route
  /// (`<llm>/<prompt-id>.yaml`) and re-pointing one never moves the others that
  /// share the inherited route.
  static String routeNameFor(String promptId) => promptId;

  /// Re-points [promptId] at [providerId]`:`[model] across the normal config.
  ///
  /// Writes the route file, rewrites the prompt's `llm:` binding in its
  /// main-procedure file, and mutates the live [config] so the change applies on
  /// the next run. The caller ([TomBrainModelSwitcher]) has already validated
  /// that [promptId] is registered and the model is advertised. Throws
  /// [CognitionModelWriteException] if the main-procedure file is missing or
  /// unparseable.
  void apply({
    required String promptId,
    required String providerId,
    required String model,
  }) {
    final prompt = config.prompts[promptId];
    if (prompt == null) {
      // The switcher validates registration first, so this is unreachable in the
      // command path; guard the public method honestly all the same.
      throw CognitionModelWriteException(
        'No registered prompt "$promptId" to re-point.',
      );
    }
    final routeName = routeNameFor(promptId);

    _writeRouteFile(routeName, providerId, model);
    _bindPromptRoute(prompt, routeName);
    _applyLive(prompt, routeName, providerId, model);
  }

  /// Writes (or overwrites) the single-entry route file for [routeName] at
  /// `<cognitionRoot>/<llmFolder>/<routeName>.yaml`.
  void _writeRouteFile(String routeName, String providerId, String model) {
    final dir = Directory('$cognitionRoot/${config.registry.llmFolder}')
      ..createSync(recursive: true);
    final file = File('${dir.path}/$routeName.yaml');
    file.writeAsStringSync(
      '# The "$routeName" LLM route — written by /switch_model (request e).\n'
      '# A single-entry route dedicating one model to this prompt; rewritten on\n'
      '# every /switch_model for this prompt. Add entries by hand to make it a\n'
      '# rotation/failover chain (first reachable wins).\n'
      '\n'
      'route:\n'
      '  - provider: $providerId\n'
      '    model: $model\n',
    );
  }

  /// Rewrites *only* [prompt]'s `llm:` binding to [routeName] in its
  /// main-procedure config file, preserving every comment and formatting choice
  /// via `yaml_edit`'s surgical node update.
  void _bindPromptRoute(ResolvedPrompt prompt, String routeName) {
    final registered = config.registry.procedures[prompt.mainProcedure];
    if (registered == null) {
      throw CognitionModelWriteException(
        'Main procedure "${prompt.mainProcedure}" is not in the registry.',
      );
    }
    final file = File('$cognitionRoot/${registered.configFile}');
    if (!file.existsSync()) {
      throw CognitionModelWriteException(
        'Main-procedure config "${registered.configFile}" not found in '
        'cognition root "$cognitionRoot".',
      );
    }
    final YamlEditor editor;
    try {
      editor = YamlEditor(file.readAsStringSync());
    } on Object catch (e) {
      throw CognitionModelWriteException(
        'Could not parse "${registered.configFile}" to set the llm binding: $e',
      );
    }
    // Path to the one node we touch: <sub>.prompts.<prompt>.llm. The parent map
    // exists (the loader parsed this prompt from it); `update` adds `llm` when
    // absent or replaces it when present, leaving the rest of the file verbatim.
    editor.update(
      [prompt.subProcedure, 'prompts', prompt.promptName, 'llm'],
      routeName,
    );
    file.writeAsStringSync(editor.toString());
  }

  /// Mutates the in-process [config] so the switch applies to the running
  /// process: registers the new single-entry route and replaces the prompt with
  /// a copy whose resolved `llm:` is [routeName].
  void _applyLive(
    ResolvedPrompt prompt,
    String routeName,
    String providerId,
    String model,
  ) {
    config.llmRoutes[routeName] = LlmRouteConfig(
      name: routeName,
      route: <RoleRouteEntryConfig>[
        RoleRouteEntryConfig(providerId: providerId, model: model),
      ],
    );
    final s = prompt.settings;
    config.prompts[prompt.id] = ResolvedPrompt(
      id: prompt.id,
      mainProcedure: prompt.mainProcedure,
      subProcedure: prompt.subProcedure,
      promptName: prompt.promptName,
      templatePath: prompt.templatePath,
      kind: prompt.kind,
      settings: PromptSettings(
        temperature: s.temperature,
        maxToolLoops: s.maxToolLoops,
        tools: s.tools,
        llm: routeName,
        role: s.role,
        responseFormat: s.responseFormat,
        stopSequences: s.stopSequences,
      ),
    );
  }
}

/// The run-layer `TelegramModelSwitcher` implementation behind `/switch_model`
/// (request e).
///
/// Validates both ids before writing anything, so an invalid switch is a
/// rendered notice rather than a corrupting write:
///
///   * the prompt-id must name a prompt registered in [cognition] (the same id
///     space `/show_prompts` lists);
///   * the model-id must be `<providerId>:<model>` (split on the *first* colon —
///     model names hold colons, e.g. `gemma3:27b`), its provider must exist in
///     [substrate], and that provider must advertise the model.
///
/// On success it applies the change through [writer] — the route file, the
/// prompt's `llm:` binding, and the live config — and confirms; the resolvers
/// pick the new route up on the next `sub.run`, and the boot reads it from disk
/// after a restart.
final class TomBrainModelSwitcher implements TelegramModelSwitcher {
  /// The loaded cognition config — the source of the valid prompt-id space.
  final CognitionConfig cognition;

  /// The parsed substrate config — the source of the valid provider/model space.
  final SubstrateConfig substrate;

  /// The writer that persists a validated switch into the normal config (disk +
  /// live), or `null` when the deployment has no cognition root to write into
  /// (the command is then unavailable rather than half-applied).
  final CognitionModelWriter? writer;

  /// Builds the switcher over the loaded [cognition] + [substrate] configs and
  /// the optional config [writer].
  TomBrainModelSwitcher({
    required this.cognition,
    required this.substrate,
    this.writer,
  });

  @override
  Future<String> switchModel({
    required String promptId,
    required String modelId,
  }) async {
    if (!cognition.prompts.containsKey(promptId)) {
      return 'No prompt type named "$promptId" is registered. '
          'Use /show_prompts to list them.';
    }

    // Split on the FIRST colon — model names carry colons (e.g. `gemma3:27b`),
    // so the provider id is everything before the first colon and the model is
    // the rest.
    final colon = modelId.indexOf(':');
    if (colon <= 0 || colon >= modelId.length - 1) {
      return 'Model id "$modelId" must be "<providerId>:<model>" '
          '(an id from /show_models).';
    }
    final providerId = modelId.substring(0, colon);
    final model = modelId.substring(colon + 1);

    final provider = substrate.lookupProvider(providerId);
    if (provider == null) {
      return 'No provider named "$providerId" is configured. '
          'Use /show_models to list them.';
    }
    if (!provider.models.contains(model)) {
      return 'Provider "$providerId" does not advertise a model named '
          '"$model". Use /show_models to list its models.';
    }

    final w = writer;
    if (w == null) {
      return 'This deployment has no cognition config to write to, so '
          '/switch_model is unavailable here.';
    }
    try {
      w.apply(promptId: promptId, providerId: providerId, model: model);
    } on CognitionModelWriteException catch (e) {
      return 'Could not persist the switch for "$promptId": ${e.message}';
    }
    return 'Prompt type "$promptId" now uses $providerId:$model '
        '(written to the cognition config; survives a restart).';
  }
}
