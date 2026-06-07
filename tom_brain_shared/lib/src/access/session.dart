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

import 'package:tom_core_agentic/tom_core_agentic.dart' show requireNonEmpty;

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

  /// The memory profile this conversation is pinned to (Extension H,
  /// access spec § 4.4 / § 7.4). `null` when the conversation uses the
  /// process default profile — either selection is off, or no confident
  /// pick has been made yet. When set, the procedure layer opens that
  /// profile for retrieval (hub § 23.5 / § 23.6). Access' `SessionManager`
  /// is the only writer (via the `MemoryProfileSelector`); the dispatcher
  /// reads it through `Access`.
  final String? memoryProfile;

  /// Builds an immutable session handle. [sessionId] must be non-empty.
  Session({
    required this.sessionId,
    this.conversationId,
    this.memoryProfile,
  }) {
    requireNonEmpty(sessionId, 'sessionId');
  }

  /// Returns a copy with [memoryProfile] replaced — the seam access uses to
  /// stamp the selected profile onto an otherwise-built handle. Passing
  /// `null` clears the profile back to the process default. Identity
  /// ([sessionId], [conversationId]) is preserved.
  Session withMemoryProfile(String? memoryProfile) => Session(
        sessionId: sessionId,
        conversationId: conversationId,
        memoryProfile: memoryProfile,
      );

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.sessionId == sessionId &&
      other.conversationId == conversationId &&
      other.memoryProfile == memoryProfile;

  @override
  int get hashCode => Object.hash(sessionId, conversationId, memoryProfile);

  @override
  String toString() => 'Session(sessionId: $sessionId, '
      'conversationId: $conversationId, memoryProfile: $memoryProfile)';
}
