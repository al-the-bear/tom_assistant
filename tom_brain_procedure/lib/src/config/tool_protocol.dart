// ToolProtocol — how a provider exposes tool calls on the wire.
//
// Relocated here from the retired three-layer `provider_config.dart` (the
// `ProviderRegistry` / `ModelConfigStore` scaffold removed with the scripted
// `call_llm_v1` loop). The enum itself is **not** part of that scaffold: it is
// the live wire-protocol token the substrate bridge's `ToolProtocolResolver`
// switches on (`substrate_bridge.dart`) to decide between native OpenAI
// `tool_calls` and JSON-text tool calls. It survives the retirement on its own,
// alongside the structural [LlmConfigInvalid] its parser raises.

library;

import 'llm_config_errors.dart' show LlmConfigInvalid;

/// How a provider exposes tool calls. Parsed from the `toolProtocol`
/// field; the on-wire `json_text` token maps to [ToolProtocol.jsonText].
enum ToolProtocol {
  /// Native OpenAI `tool_calls`.
  openai('openai'),

  /// Tool calls parsed from JSON embedded in the completion text — the
  /// fallback for models without a native tool-call channel.
  jsonText('json_text');

  const ToolProtocol(this.wire);

  /// The token as written in YAML.
  final String wire;

  /// Parses a YAML `toolProtocol` token, rejecting an unknown value
  /// through [LlmConfigInvalid] with [path].
  static ToolProtocol parse(String raw, String path) {
    for (final value in ToolProtocol.values) {
      if (value.wire == raw) return value;
    }
    throw LlmConfigInvalid(
      'unknown toolProtocol "$raw" (expected one of '
      '${ToolProtocol.values.map((v) => v.wire).join(", ")})',
      path: path,
    );
  }
}
