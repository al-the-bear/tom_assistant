// LLM-configuration failure types (Extension F, step 2;
// `tom_brain_procedure_prototype_specification.md` § 21.6, § 21.10).
//
// The three-layer model configuration (`llm_configuration/`) loads two
// file layers — `providers.yaml` and `models/<id>.yaml` — through the
// canonical plain-map loader. Two absent-file conditions and one
// structural-shape condition each surface as a single typed error, so a
// boot path can route on the wire code without string-matching the
// message — the same idiom `EngineConfigInvalid` (C.42) and the
// placeholder codes (step 1) follow:
//
//   • `providers.missing`     — the providers.yaml file is absent.
//   • `model_config.missing`  — a requested models/<id>.yaml is absent.
//   • `llm.config.invalid`    — a present document has the wrong shape
//                               (bad enum value, duplicate id, missing
//                               required field, env-expansion failure).
//
// The two "missing" rows mirror the § 21.10 failure table verbatim
// (`prompt_template.missing` / `model_config.missing` share that row);
// `llm.config.invalid` is the structural sibling, named here so the
// loaders never leak a raw `FormatException`, `YamlException`, or
// placeholder error to their callers.

library;

/// Wire code for an absent `providers.yaml`. Matches the § 21.10
/// config-loader failure family.
const String providersMissingCode = 'providers.missing';

/// Wire code for an absent `models/<id>.yaml`. Matches the § 21.10
/// `model_config.missing` row.
const String modelConfigMissingCode = 'model_config.missing';

/// Wire code for a structurally invalid providers/model document.
const String llmConfigInvalidCode = 'llm.config.invalid';

/// Thrown when the `providers.yaml` file does not exist.
///
/// An absent providers file is a hard error (unlike an absent
/// `EngineConfig`, which falls back to defaults): without a provider
/// registry the substrate router has nowhere to connect. Carries the
/// [path] that was looked up so an operator sees which file is missing.
final class ProvidersMissing implements Exception {
  /// Records the absent providers file at [path].
  const ProvidersMissing(this.path);

  /// The filesystem path that was expected to hold the providers file.
  final String path;

  /// The wire code carried by every providers-missing failure.
  String get code => providersMissingCode;

  /// Human-readable explanation, reused by [toString].
  String get message => 'providers file not found at "$path"';

  @override
  String toString() => '$code: $message';
}

/// Thrown when a requested `models/<id>.yaml` does not exist.
///
/// Carries the logical [modelId] that was requested and the [path] that
/// was looked up, so the failure identifies both *which* model is missing
/// and *where* the loader expected its file.
final class ModelConfigMissing implements Exception {
  /// Records the absent model config for [modelId] at [path].
  const ModelConfigMissing(this.modelId, this.path);

  /// The logical model id whose config file is missing.
  final String modelId;

  /// The filesystem path that was expected to hold the model config.
  final String path;

  /// The wire code carried by every model-config-missing failure.
  String get code => modelConfigMissingCode;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'model config "$modelId" not found at "$path"';

  @override
  String toString() => '$code: $message';
}

/// Thrown when a present providers/model document is structurally invalid.
///
/// Carries a human-readable [message] and, when the problem is localised
/// to one field, the dotted [path] of the offending key (e.g.
/// `providers[0].apiType`). The string form prefixes `llm.config.invalid:`
/// so the failure class is greppable in logs and trails.
final class LlmConfigInvalid implements Exception {
  /// Builds a structural-invalid error with [message] and an optional
  /// field [path].
  const LlmConfigInvalid(this.message, {this.path});

  /// Describes what is wrong with the configuration document.
  final String message;

  /// The dotted path of the offending field, when the problem is local to
  /// a single key. `null` for document-level problems.
  final String? path;

  /// The wire code carried by every structural-invalid failure.
  String get code => llmConfigInvalidCode;

  @override
  String toString() {
    final at = path == null ? '' : ' (at "$path")';
    return '$code: $message$at';
  }
}
