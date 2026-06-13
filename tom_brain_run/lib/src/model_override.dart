// The model-override seam behind the `/switch_model` command (request e).
//
// `/switch_model <prompt-id> <model-id>` re-points one cognition prompt type at
// a chosen `<providerId>:<model>`, *without* rewriting the committed per-prompt
// cognition config (which routes by a shared `llm:` route name — editing the
// route file would wrongly move every prompt on that route). The override rides
// the two `sub.run` resolver seams (`cognition_prompt_resolver.dart`): an
// overridden prompt's `ResolvedPrompt.llmRoute` becomes the synthetic route name
// `<modelOverrideRoutePrefix><promptId>`, and the route-chain resolver decodes
// that synthetic name back into a single-entry chain of the chosen model. So a
// switch re-routes *only* the targeted prompt; every other prompt keeps its
// committed route.
//
// The override is **persisted** to a flat `model_overrides.yaml` at the
// cognition root (request e revision): `/switch_model` mutates the live registry
// *and* writes it through, and the boot seeds the registry back from that file —
// so a switch survives a process restart. (Earlier this seam was process-only;
// that decision was revised to make `/switch_model` change the configuration on
// disk, per the "no backwards compatibility" principle.)
//
// This file holds the four pieces that seam needs:
//
//   * [ModelOverride] — the chosen `(providerId, model)` pair for one prompt.
//   * [ModelOverrideRegistry] — the in-process map prompt-id → override,
//     consulted by the wrapped resolvers and the prompts inspector.
//   * [ModelOverrideStore] — the on-disk persistence (`model_overrides.yaml`)
//     the boot seeds the registry from and `/switch_model` writes through.
//   * [TomBrainModelSwitcher] — the run-layer `TelegramModelSwitcher` impl: it
//     validates the prompt-id against the loaded `CognitionConfig` and the
//     `<providerId>:<model>` id against the `SubstrateConfig`, then mutates the
//     registry, persists it through the store, and renders the outcome.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show TelegramModelSwitcher;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig;
import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;

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

/// The in-process registry of active model overrides, keyed by prompt id.
///
/// Mutated only by [TomBrainModelSwitcher] (via `/switch_model`); read by the
/// wrapped resolvers (to re-route an overridden prompt) and the
/// `CognitionPromptsInspector` (to show the active override in `/show_prompts`).
/// It is seeded from a [ModelOverrideStore] at boot and written back through
/// that store on every switch, so an override survives a process restart.
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

  /// An unmodifiable snapshot of every active override, keyed by prompt id —
  /// the shape a [ModelOverrideStore] persists.
  Map<String, ModelOverride> get entries =>
      Map<String, ModelOverride>.unmodifiable(_byPromptId);
}

/// Thrown when a `model_overrides.yaml` file cannot be parsed into overrides
/// (a non-map document, a non-string value, or a value that is not a
/// `<providerId>:<model>` pair).
class ModelOverrideStoreException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const ModelOverrideStoreException(this.message);

  @override
  String toString() => 'ModelOverrideStoreException: $message';
}

/// The on-disk persistence behind `/switch_model`: a flat YAML map at
/// [filePath] (`<cognition.root>/model_overrides.yaml`) of prompt-id →
/// `"<providerId>:<model>"`.
///
/// The store is the durable half of the override seam (request e): the boot
/// [load]s it to seed the [ModelOverrideRegistry], and [TomBrainModelSwitcher]
/// [save]s the registry snapshot through it after every validated switch. The
/// committed per-prompt cognition config is never touched — a prompt's `llm:`
/// route name is shared, so the per-prompt override lives in its own file.
final class ModelOverrideStore {
  /// The absolute path to the `model_overrides.yaml` file this store owns.
  final String filePath;

  /// Binds the store to [filePath].
  const ModelOverrideStore({required this.filePath});

  /// Reads the persisted overrides, keyed by prompt id.
  ///
  /// An absent file, or a file with no non-comment content, loads as the empty
  /// map. Throws [ModelOverrideStoreException] on a malformed document, a
  /// non-string value, or a value that is not a `<providerId>:<model>` pair.
  Map<String, ModelOverride> load() {
    final file = File(filePath);
    if (!file.existsSync()) return <String, ModelOverride>{};
    final content = file.readAsStringSync();
    // A blank or comment-only file (`loadYamlAsMap` rejects a null root) is the
    // honest empty state — a hand-cleared overrides file.
    final hasContent = content
        .split('\n')
        .map((line) => line.trim())
        .any((line) => line.isNotEmpty && !line.startsWith('#'));
    if (!hasContent) return <String, ModelOverride>{};

    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'model_overrides',
      errorFactory: ModelOverrideStoreException.new,
    );
    final result = <String, ModelOverride>{};
    for (final entry in doc.entries) {
      final value = entry.value;
      if (value is! String) {
        throw ModelOverrideStoreException(
          'Override for "${entry.key}" must be a "<providerId>:<model>" '
          'string (got ${value == null ? 'null' : value.runtimeType}).',
        );
      }
      result[entry.key] = _parseModelId(entry.key, value);
    }
    return result;
  }

  /// Rewrites the file to exactly [entries], sorted by prompt id for a
  /// deterministic on-disk form. Creates the parent directory if needed.
  void save(Map<String, ModelOverride> entries) {
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    final keys = entries.keys.toList()..sort();
    final buffer = StringBuffer()
      ..writeln('# Persisted /switch_model overrides (request e). Auto-managed —')
      ..writeln('# rewritten on every /switch_model. Format:')
      ..writeln('#   "<prompt-id>": "<providerId>:<model>"');
    for (final key in keys) {
      final override = entries[key]!;
      buffer.writeln('"$key": "${override.providerId}:${override.model}"');
    }
    file.writeAsStringSync(buffer.toString());
  }

  /// Splits a `<providerId>:<model>` value on the FIRST colon — model names
  /// carry colons (e.g. `gemma3:27b`), matching [TomBrainModelSwitcher].
  static ModelOverride _parseModelId(String promptId, String modelId) {
    final colon = modelId.indexOf(':');
    if (colon <= 0 || colon >= modelId.length - 1) {
      throw ModelOverrideStoreException(
        'Override "$modelId" for "$promptId" must be "<providerId>:<model>".',
      );
    }
    return ModelOverride(
      providerId: modelId.substring(0, colon),
      model: modelId.substring(colon + 1),
    );
  }
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
/// On success it records the override in [overrides], persists the registry
/// snapshot through [store] (when one is wired) so the switch survives a
/// restart, and confirms; the wrapped resolvers pick the new route up on the
/// next `sub.run`.
final class TomBrainModelSwitcher implements TelegramModelSwitcher {
  /// The loaded cognition config — the source of the valid prompt-id space.
  final CognitionConfig cognition;

  /// The parsed substrate config — the source of the valid provider/model space.
  final SubstrateConfig substrate;

  /// The in-process override registry this switcher mutates.
  final ModelOverrideRegistry overrides;

  /// The on-disk store the validated override is written through, or `null`
  /// when the deployment has no cognition root to persist into (the switch then
  /// applies for the running process only).
  final ModelOverrideStore? store;

  /// Builds the switcher over the loaded [cognition] + [substrate] configs, the
  /// live [overrides] registry, and the optional persistence [store].
  TomBrainModelSwitcher({
    required this.cognition,
    required this.substrate,
    required this.overrides,
    this.store,
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
    final persisted = store;
    if (persisted != null) {
      persisted.save(overrides.entries);
      return 'Prompt type "$promptId" now uses $providerId:$model '
          '(persisted; survives a restart).';
    }
    return 'Prompt type "$promptId" now uses $providerId:$model for this '
        'process (override; not persisted to config).';
  }
}
