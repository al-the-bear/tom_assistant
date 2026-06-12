// LLM-configuration failure types
// (`tom_brain_procedure_specification.md` § 21.6, § 21.10).
//
// What survives the retirement of the three-layer LLM config scaffold
// (`providers.yaml` / `models/<id>.yaml` / `prompt_template/`, removed with the
// scripted `call_llm_v1` loop in increment 9) is the single structural-shape
// error every remaining YAML loader in this module funnels a malformed document
// through, so a boot path can route on its wire code without string-matching the
// message — the same idiom `EngineConfigInvalid` (C.42) follows:
//
//   • `llm.config.invalid` — a present document has the wrong shape (bad enum
//     value, duplicate id, missing required field, env-expansion failure),
//     named here so the loaders never leak a raw `FormatException`,
//     `YamlException`, or placeholder error to their callers.

library;

/// Wire code for a structurally invalid configuration document.
const String llmConfigInvalidCode = 'llm.config.invalid';

/// Thrown when a present configuration document is structurally invalid.
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
