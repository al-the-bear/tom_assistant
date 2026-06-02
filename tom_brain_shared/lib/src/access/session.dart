// Session — the minimal conversation handle the dispatcher threads through
// (Plan step D.11; def § 1.5; proto spec § 10.1).
//
// What this file owns:
//
//   * The `Session` value type — a thin handle identifying the
//     sliding-window conversation an inbound request belongs to.
//
// Why a *minimal* handle (not the full session window):
//
//   The rich `Session` *node* (sliding-window message history, last-N
//   turns, TTL) is memory-owned (`memory_specification.md`) and produced
//   by Phase E's `SessionManager` (E.25). The dispatcher reads only the
//   session's identity so the recorder / persist path can attach a run to
//   the right conversation (D.39); it never reads the window contents.
//   The shared shape therefore carries the identity only — Q-D.11.3.

/// The conversation a request belongs to, in the minimal shape the
/// dispatcher needs. Carried on [Access] so a run can be linked to its
/// conversation.
///
/// Immutable value object. Phase E's `SessionManager` builds it from the
/// memory-owned session node; the dispatcher reads only [sessionId]
/// (and, when present, [conversationId]) and treats the rest as opaque.
final class Session {
  /// Stable session identifier — the key under which the memory-owned
  /// session node is stored. Non-empty: an empty session id cannot link
  /// a run to a conversation.
  final String sessionId;

  /// Optional conversation identifier this session belongs to, mirrored
  /// from `InboundRequest.conversationId` when the channel supplies one.
  /// `null` when the channel is single-turn / conversationless.
  final String? conversationId;

  /// Builds an immutable session handle. [sessionId] must be non-empty.
  Session({
    required this.sessionId,
    this.conversationId,
  }) {
    if (sessionId.isEmpty) {
      throw ArgumentError.value(
        sessionId,
        'sessionId',
        'must be non-empty',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.sessionId == sessionId &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(sessionId, conversationId);

  @override
  String toString() =>
      'Session(sessionId: $sessionId, conversationId: $conversationId)';
}
