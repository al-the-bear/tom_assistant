// Request-fidelity element types (Plan step G.19; hub spec § 22.1; access
// spec § 4.2).
//
// What this file owns:
//
//   The three immutable value types that populate `InboundRequest`'s four
//   Extension-G fields — the "full request fidelity" the gateway stops
//   discarding (hub § 22.1). A Phase-E adapter decodes the wire payload
//   (OpenAI `messages[]` / `tools[]`, Anthropic blocks, …) into these
//   typed elements; the dispatcher and `call_llm_v1` consume them.
//
//     * `PriorTurn`        — one ordered (role, text) turn of the client's
//                            remote history (`InboundRequest.priorTurns`).
//                            The last user message stays the live `text`;
//                            the preceding turns become PriorTurns.
//     * `RemoteToolResult` — one client-executed tool result echoed back on
//                            a follow-up request (`InboundRequest.toolResults`).
//                            References the tool call it answers.
//     * `RemoteToolDef`     — one client-declared tool definition the brain
//                            may *propose* but never executes
//                            (`InboundRequest.remoteTools`).
//
// Why typed elements and not loose maps: equality composes cleanly through
// `listEquals` on the owning `InboundRequest`, the shapes are faithful to
// the spec's `(role, text)` / `{name, description, input_schema}` semantics,
// and the identity-bearing field of each (role / toolCallId / name) is
// validated at construction — matching the sibling `Access`-family types
// (`Session`, `ResolvedIdentity`, `Persona`) which reject empty ids.
//
// What this file does NOT do:
//
//   * No wire decoding. Adapters (Phase E) produce these from the raw
//     provider payload; the types carry the decoded result.
//   * No execution. `RemoteToolDef` is a declaration only — the brain
//     proposes a call; the *client* runs it and returns a
//     `RemoteToolResult` (hub § 22.8).

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show mapEquals, textPreview;

/// One ordered turn of the client-supplied remote history — a `(role, text)`
/// pair drawn from the inbound `messages[]` array (hub § 22.1).
///
/// Immutable value object. The `role` is the provider-native message role
/// (`user` / `assistant` / `system`); `text` is that turn's content and may
/// be empty (an empty assistant turn is legal). An empty / whitespace-only
/// role is a decoder error and is rejected at construction.
final class PriorTurn {
  /// The provider-native message role (`user` / `assistant` / `system`).
  /// Always non-empty.
  final String role;

  /// The turn's content. May be empty — an empty turn body is legal.
  final String text;

  /// Builds an immutable prior turn. [role] must contain at least one
  /// non-whitespace character; a turn with no role could not be replayed
  /// into a provider-native `messages` array.
  PriorTurn({required this.role, required this.text}) {
    if (role.trim().isEmpty) {
      throw ArgumentError.value(
        role,
        'role',
        'a prior turn must carry a role (user / assistant / system)',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PriorTurn && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() =>
      'PriorTurn(role: $role, text: ${textPreview(text, limit: 40)})';
}

/// One client-executed tool result, echoed back to the brain on a follow-up
/// request (hub § 22.8). It references the tool call it answers so the
/// re-entered loop can match it to the proposed call.
///
/// Immutable value object. `content` may be empty (a tool may return
/// nothing); the `toolCallId` is the identity-bearing field and is rejected
/// when empty.
final class RemoteToolResult {
  /// The id of the tool call this result answers — echoed from the
  /// provider-native `tool_calls` / `tool_use` block the brain previously
  /// returned. Always non-empty.
  final String toolCallId;

  /// The result the client's tool produced. May be empty.
  final String content;

  /// Builds an immutable remote tool result. [toolCallId] must contain at
  /// least one non-whitespace character; a result that names no call could
  /// not be matched back to a proposed tool call.
  RemoteToolResult({required this.toolCallId, required this.content}) {
    if (toolCallId.trim().isEmpty) {
      throw ArgumentError.value(
        toolCallId,
        'toolCallId',
        'a remote tool result must reference the tool call it answers',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteToolResult &&
      other.toolCallId == toolCallId &&
      other.content == content;

  @override
  int get hashCode => Object.hash(toolCallId, content);

  @override
  String toString() => 'RemoteToolResult(toolCallId: $toolCallId, '
      'content: ${textPreview(content, limit: 40)})';
}

/// One client-declared tool definition from the request's `tools[]` array
/// (hub § 22.1 / § 22.8). The brain may *propose* calling it; the **client**
/// executes it and returns a [RemoteToolResult] on the next turn.
///
/// Immutable value object. `name` is the identity-bearing field and is
/// rejected when empty; `description` is optional; `inputSchema` is the
/// tool's JSON-schema parameter shape, stored as an unmodifiable defensive
/// copy so a downstream consumer cannot mutate a shared declaration.
final class RemoteToolDef {
  /// The tool's name, as the client declared it. Always non-empty.
  final String name;

  /// Optional human-readable description of what the tool does.
  final String? description;

  /// The tool's JSON-schema parameter shape (the provider's
  /// `parameters` / `input_schema`). Stored unmodifiable; defaults empty.
  final Map<String, Object?> inputSchema;

  /// Builds an immutable remote tool definition. [name] must contain at
  /// least one non-whitespace character; a tool the model is asked to
  /// propose must be nameable.
  RemoteToolDef({
    required this.name,
    this.description,
    Map<String, Object?> inputSchema = const {},
  }) : inputSchema = Map.unmodifiable(inputSchema) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'a remote tool definition must carry a name',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteToolDef &&
      other.name == name &&
      other.description == description &&
      mapEquals(other.inputSchema, inputSchema);

  @override
  int get hashCode =>
      Object.hash(name, description, Object.hashAllUnordered(inputSchema.keys));

  @override
  String toString() => 'RemoteToolDef(name: $name, '
      'description: $description, inputSchema: $inputSchema)';
}
