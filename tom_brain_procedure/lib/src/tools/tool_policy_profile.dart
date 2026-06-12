// ToolPolicyProfile — the tool-permission profile a run selects (§ 21.8).
//
// Relocated here from the retired `prompt_template_config.dart` (the layer-3
// prompt-template config removed with the scripted `call_llm_v1` loop). The
// enum is **not** part of that scaffold: it is the live profile the tools
// module switches on — `ToolPolicy` (`tool_policy.dart`) maps each profile to a
// concrete allow-set, and `ToolPolicyConfig` (`tool_policy_config.dart`) parses
// the `default:` profile. Its natural home is the tools module it serves; this
// also removes the lone `tools → config/prompt_template` import that the
// retirement would otherwise dangle.

library;

import '../config/llm_config_errors.dart' show LlmConfigInvalid;

/// The tool-permission profile a run selects (§ 21.8). The on-wire
/// `read_only` token maps to [ToolPolicyProfile.readOnly].
enum ToolPolicyProfile {
  /// Every tool (the deny list is still honoured, step 5).
  all('all'),

  /// Every `readOnly` tool (the deny list is still honoured).
  readOnly('read_only'),

  /// Every tool whose `group` is in the enabled-groups set.
  groups('groups'),

  /// Only the allow-listed tool names.
  explicit('explicit');

  const ToolPolicyProfile(this.wire);

  /// The token as written in YAML.
  final String wire;

  /// Parses a YAML `toolPolicy` token, rejecting an unknown value through
  /// [LlmConfigInvalid] with [path].
  static ToolPolicyProfile parse(String raw, String path) {
    for (final value in ToolPolicyProfile.values) {
      if (value.wire == raw) return value;
    }
    throw LlmConfigInvalid(
      'unknown toolPolicy "$raw" (expected one of '
      '${ToolPolicyProfile.values.map((v) => v.wire).join(", ")})',
      path: path,
    );
  }
}
