// The runtime model-override seam behind the `/switch_model` command (request
// e).
//
// `/switch_model <prompt-id> <model-id>` re-points one cognition prompt type at
// a chosen `<providerId>:<model>` for the rest of the process, *without* editing
// the committed cognition config (the override is process-only, never persisted
// — design decision for request e). The override rides the two `sub.run`
// resolver seams (`cognition_prompt_resolver.dart`): an overridden prompt's
// `ResolvedPrompt.llmRoute` becomes the synthetic route name
// `<modelOverrideRoutePrefix><promptId>`, and the route-chain resolver decodes
// that synthetic name back into a single-entry chain of the chosen model. So a
// switch re-routes *only* the targeted prompt; every other prompt keeps its
// committed route.
//
// This file holds the three pieces that seam needs:
//
//   * [ModelOverride] — the chosen `(providerId, model)` pair for one prompt.
//   * [ModelOverrideRegistry] — the process-lifetime map prompt-id → override,
//     consulted by the wrapped resolvers and the prompts inspector.
//   * [TomBrainModelSwitcher] — the run-layer `TelegramModelSwitcher` impl: it
//     validates the prompt-id against the loaded `CognitionConfig` and the
//     `<providerId>:<model>` id against the `SubstrateConfig`, then mutates the
//     registry and renders the outcome.

import 'package:tom_brain_access/tom_brain_access.dart'
    show TelegramModelSwitcher;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig;

import 'cognition_config.dart';

/// The synthetic route-name prefix an overridden prompt's `llmRoute` carries.
///
/// `buildPromptResolver` rewrites an overridden prompt's route to
/// `<modelOverrideRoutePrefix><promptId>`; `buildRouteChainResolver` recognises
/// that prefix and resolves the chain from the [ModelOverrideRegistry] instead
/// of the committed config. The double-underscore framing keeps it out of the
/// namespace any committed route name occupies.
const String modelOverrideRoutePrefix = '__model_override__';

/// One prompt type's active model override — the `<providerId>:<model>` pair the
/// `/switch_model` command chose, re-routing that prompt for the process.
final class ModelOverride {
  /// The substrate provider id the prompt is re-routed to.
  final String providerId;

  /// The model (within that provider) the prompt is re-routed to.
  final String model;

  /// Binds the override pair.
  const ModelOverride({required this.providerId, required this.model});
}

/// The process-lifetime registry of active model overrides, keyed by prompt id.
///
/// Mutated only by [TomBrainModelSwitcher] (via `/switch_model`); read by the
/// wrapped resolvers (to re-route an overridden prompt) and the
/// `CognitionPromptsInspector` (to show the active override in `/show_prompts`).
/// It is never persisted — an override lives only for the running process.
final class ModelOverrideRegistry {
  final Map<String, ModelOverride> _byPromptId = <String, ModelOverride>{};

  /// Sets (or replaces) the override for [promptId].
  void set(
    String promptId, {
    required String providerId,
    required String model,
  }) {
    _byPromptId[promptId] =
        ModelOverride(providerId: providerId, model: model);
  }

  /// The active override for [promptId], or `null` when the prompt is not
  /// overridden.
  ModelOverride? overrideFor(String promptId) => _byPromptId[promptId];

  /// Whether no prompt is currently overridden.
  bool get isEmpty => _byPromptId.isEmpty;
}

/// The run-layer `TelegramModelSwitcher` implementation behind `/switch_model`
/// (request e).
///
/// Validates both ids before mutating the registry, so an invalid switch is a
/// rendered notice rather than a corrupting write:
///
///   * the prompt-id must name a prompt registered in [cognition] (the same id
///     space `/show_prompts` lists);
///   * the model-id must be `<providerId>:<model>` (split on the *first* colon —
///     model names hold colons, e.g. `gemma3:27b`), its provider must exist in
///     [substrate], and that provider must advertise the model.
///
/// On success it records the override in [overrides] (process-only) and confirms;
/// the wrapped resolvers pick the new route up on the next `sub.run`.
final class TomBrainModelSwitcher implements TelegramModelSwitcher {
  /// The loaded cognition config — the source of the valid prompt-id space.
  final CognitionConfig cognition;

  /// The parsed substrate config — the source of the valid provider/model space.
  final SubstrateConfig substrate;

  /// The process-lifetime override registry this switcher mutates.
  final ModelOverrideRegistry overrides;

  /// Builds the switcher over the loaded [cognition] + [substrate] configs and
  /// the live [overrides] registry.
  TomBrainModelSwitcher({
    required this.cognition,
    required this.substrate,
    required this.overrides,
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

    overrides.set(promptId, providerId: providerId, model: model);
    return 'Prompt type "$promptId" now uses $providerId:$model for this '
        'process (override; not persisted to config).';
  }
}
