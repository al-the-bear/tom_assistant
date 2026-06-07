// InboundRequest — the normalised inbound request the dispatcher consumes
// (Plan step D.11; def § 1.5; proto spec § 10.1).
//
// What this file owns:
//
//   * The `InboundRequest` value type — the channel-agnostic shape of one
//     inbound user prompt after a Phase-E adapter (OpenAI HTTP/SSE,
//     Telegram, …) has decoded the wire payload.
//
// Field policy (Q-D.11.1):
//
//   The dispatcher reads exactly two fields — `text` and `kindHint`
//   (proto spec § 10.1, D.4 planned-wire table). The remaining fields
//   (`conversationId`, `messageId`, `streaming`, `metadata`) are the
//   canonical envelope identity that def § 1.5 names as "what makes one
//   inbound request comparable to another"; they are declared here now,
//   not deferred, because:
//
//     1. This is initial implementation — no backwards compatibility.
//        A type two phases reference is declared once, complete, in
//        shared (D.4 reuse decision). Growing a required field later
//        would be exactly the migration this rule forbids.
//     2. Phase E (E.11–E.22) fills them at construction; Phase D's run /
//        session linkage and recorder read `conversationId` / `messageId`.
//
//   `ChannelRef` is *not* declared here: the originating channel is
//   captured implicitly by the channel-specific `Access.deliver`
//   callback (def § 1.5 — "the streaming-back callback specific to the
//   original channel"). No current reader needs an explicit channel
//   handle; adding one would be speculative. Recorded as Q-D.11.2.
//
// What this file does NOT do:
//
//   * No wire decoding. Adapters (Phase E) produce this from the raw
//     OpenAI / Telegram payload; the type carries the decoded result.
//   * No classification. `kindHint` is filled by the Phase-E heuristic
//     classifier (E.33) or left null for the dispatcher's
//     `classify_inbound_v1` fallback. This type only carries the hint.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show listEquals, mapEquals, textPreview;

import 'request_fidelity.dart';

/// The normalised inbound request — one user prompt, decoded from its
/// originating channel into the channel-agnostic shape the dispatcher's
/// single entry point `accept(Access)` consumes.
///
/// Immutable value object. A Phase-E adapter constructs it once per
/// inbound request and hands it to the dispatcher inside an [Access].
final class InboundRequest {
  /// The prompt text. Always non-empty — an empty inbound request is a
  /// programmer / adapter error and is rejected at construction (D.13:
  /// "an empty inbound request is rejected"). Whitespace-only text is
  /// also rejected: it carries no prompt.
  final String text;

  /// Optional procedure-id hint pre-filled by the Phase-E heuristic
  /// classifier (E.33) when it is *confident*. `null` means "no hint";
  /// the dispatcher then runs `classify_inbound_v1` (D.15). The
  /// dispatcher reads this field directly.
  final String? kindHint;

  /// Optional conversation identifier, stable across the turns of one
  /// conversation on one channel. Phase D threads it into the run /
  /// session linkage (D.39); the Phase-E `SessionManager` (E.25) keys
  /// its sliding window on it.
  final String? conversationId;

  /// Optional per-message identifier from the originating channel
  /// (e.g. a Telegram message id). Carried for provenance — the run
  /// recorder can stamp it onto the inbound `Event` node.
  final String? messageId;

  /// Whether the originating request asked for a streamed response
  /// (e.g. the OpenAI `stream: true` flag). The answer step always
  /// streams chunks through `Access.deliver`; this flag tells the
  /// Phase-E adapter whether to render the response as SSE or as a
  /// single consolidated body. Defaults to `false`.
  final bool streaming;

  /// Opaque, channel-specific metadata the adapter chose to carry
  /// forward (raw header values, locale, etc.). Stored as an
  /// unmodifiable view so a downstream consumer cannot mutate a shared
  /// envelope. Defaults to an empty map.
  final Map<String, Object?> metadata;

  // ── Extension G (G.19): full request fidelity (hub § 22.1, access § 4.2). ──
  //
  // The gateway stops discarding everything but the last user message. All
  // four fields are optional and default empty/null, so a pre-Extension-G
  // caller that supplies only `text` (+ the envelope identity above) is
  // structurally unchanged — PE-9 holds because both producer (Phase E) and
  // consumer (`call_llm_v1`) ship in the same change. `text` stays the
  // *live* prompt (the last user message); these fields are the history /
  // tool context around it, so the dispatcher's read-surface is untouched.

  /// The full inbound `messages[]` history the client supplied, as ordered
  /// `(role, text)` turns — **excluding** the last user message, which stays
  /// the live [text]. Empty for a single-turn channel (e.g. Telegram).
  /// Stored as an unmodifiable defensive copy.
  final List<PriorTurn> priorTurns;

  /// Client-executed tool results echoed back on a follow-up turn
  /// (hub § 22.8) — results for tool calls the brain previously proposed.
  /// Empty unless the client is continuing a remote-tool round. Stored as
  /// an unmodifiable defensive copy.
  final List<RemoteToolResult> toolResults;

  /// The client-supplied `tools[]` declarations the brain may *propose*
  /// calling but never executes (hub § 22.8). Empty unless the client
  /// declared tools. Stored as an unmodifiable defensive copy.
  final List<RemoteToolDef> remoteTools;

  /// The session id the client echoed from a prior response
  /// (request field / `X-Tom-Session` header, hub § 22.9), associating
  /// this call with a kept history. `null` when the client sent none —
  /// the request is then routed to the default session.
  final String? sessionId;

  /// Builds an immutable inbound request. [text] must contain at least
  /// one non-whitespace character; the empty / whitespace-only case is
  /// the "empty inbound request" D.13 requires be rejected.
  InboundRequest({
    required this.text,
    this.kindHint,
    this.conversationId,
    this.messageId,
    this.streaming = false,
    Map<String, Object?> metadata = const {},
    List<PriorTurn> priorTurns = const [],
    List<RemoteToolResult> toolResults = const [],
    List<RemoteToolDef> remoteTools = const [],
    this.sessionId,
  })  : metadata = Map.unmodifiable(metadata),
        priorTurns = List.unmodifiable(priorTurns),
        toolResults = List.unmodifiable(toolResults),
        remoteTools = List.unmodifiable(remoteTools) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'inbound request text must be non-empty (and not whitespace-only)',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is InboundRequest &&
      other.text == text &&
      other.kindHint == kindHint &&
      other.conversationId == conversationId &&
      other.messageId == messageId &&
      other.streaming == streaming &&
      mapEquals(other.metadata, metadata) &&
      listEquals(other.priorTurns, priorTurns) &&
      listEquals(other.toolResults, toolResults) &&
      listEquals(other.remoteTools, remoteTools) &&
      other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(
        text,
        kindHint,
        conversationId,
        messageId,
        streaming,
        Object.hashAllUnordered(metadata.keys),
        Object.hashAll(priorTurns),
        Object.hashAll(toolResults),
        Object.hashAll(remoteTools),
        sessionId,
      );

  @override
  String toString() => 'InboundRequest('
      'text: ${textPreview(text, limit: 40)}, '
      'kindHint: $kindHint, '
      'conversationId: $conversationId, '
      'messageId: $messageId, '
      'streaming: $streaming, '
      'metadata: $metadata, '
      'priorTurns: ${priorTurns.length}, '
      'toolResults: ${toolResults.length}, '
      'remoteTools: ${remoteTools.length}, '
      'sessionId: $sessionId)';
}
