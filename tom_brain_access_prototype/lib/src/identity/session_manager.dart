// `SessionManager` — the edge step that resolves *which conversation* an
// inbound request belongs to (E.25).
//
// What this file owns (Plan § Phase E, substep E.25; proto spec § 7.2;
// AC-8):
//
//   * `AccessChannel` — the channel discriminator (`openai` / `telegram`).
//     It is the second component of the session key. Identity is the
//     *person* (E.24, channel-blind by design — same `principalId` on both
//     channels); the channel distinction lives here, so the same
//     principal's OpenAI session and Telegram session are different
//     sessions (proto spec § 7.1 / § 7.2).
//   * `SessionKey` — the (principal, channel, conversation id) triple a
//     session is keyed by. Validates its `principalId` like every other
//     access value object; the channel is required, the conversation id is
//     optional (single-turn channels supply none).
//   * `SessionTurn` — one recorded inbound turn (text + optional message id
//     + timestamp + a session-local index). The sliding window is a list of
//     these.
//   * `SessionNode` — the rich, sliding-window session node. The shared
//     `Session` handle (§ 4.4) carries only identity; the window, the turn
//     count, and the timestamps live on the node. `toSessionHandle()`
//     projects the node onto the minimal handle the dispatcher reads.
//   * `SessionManager` — resolves/creates a node per request, keyed by the
//     triple, sliding the window on reuse. Reuse is *by key, not by
//     re-creation* (AC-8): the second request on the same key returns the
//     same node (same `sessionId`), with the new turn appended.
//
// Why an in-process node store (not a memory write) in the prototype:
//
//   The proto spec § 7.2 says the session is "persisted as `Session` nodes
//   in memory (Phase A)". The access layer, however, deliberately does NOT
//   depend on `tom_brain_memory` (pubspec § "Explicitly NOT here") — every
//   memory write goes through the dispatcher, never around it. So Phase E's
//   `SessionManager` owns the *resolution* (key → node, sliding window) and
//   produces the shared handle; the actual memory-node persistence is the
//   integration point wired through the dispatcher at E.27 / E.55. Keeping
//   the node in-process here is the same posture E.24's `IdentityResolver`
//   took with its binding registry: resolve now, wire the persistence seam
//   later, never reach past the dispatcher.
//
// Why a record-tuple map key (not a delimited string):
//
//   The key is a (String, AccessChannel, String?) triple. A delimited
//   string key (`'$principalId|$channel|$conversationId'`) is ambiguous —
//   `('a|b', …, 'c')` and `('a', …, 'b|c')` would collide. A Dart record
//   has structural equality, so the triple is the map key directly and the
//   ambiguity cannot arise.
//
// Scope discipline (per the strict per-substep log). E.25 is the
// conversation → session resolver only. It does NOT:
//
//   * resolve identity (E.24, `IdentityResolver` — it *consumes* the
//     resolved `principalId`) or personas (E.26, `PersonaResolver`).
//   * persist the node to `tom_brain_memory` — that seam is wired through
//     the dispatcher at E.27 / E.55.
//   * construct an `Access` or wire boot (E.41+).
//   * evict by TTL — the prototype slides by turn-count capacity only;
//     time-based expiry is deferred (Q-E.25.2).

import 'package:tom_core_agentic/tom_core_agentic.dart' show systemClock;
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// The originating channel of an inbound request — the second component of
/// a [SessionKey].
///
/// Identity (E.24) is channel-blind: the same person maps to one
/// `principalId` whether they arrive over OpenAI or Telegram. The channel
/// distinction is the session's job, so a principal's OpenAI conversation
/// and Telegram conversation resolve to *different* sessions even when they
/// share a conversation id (proto spec § 7.2).
enum AccessChannel {
  /// The OpenAI HTTP/SSE adapter (E.3).
  openai('openai'),

  /// The Telegram adapter (E.4).
  telegram('telegram');

  const AccessChannel(this.wireName);

  /// The stable, lower-case channel name. Matches the `channel` strings the
  /// sibling `IdentityResolutionException` (E.24) already uses, so logs read
  /// consistently across the two resolvers.
  final String wireName;
}

/// The (principal, channel, conversation id) triple a session is keyed by
/// (proto spec § 7.2, AC-8).
///
/// Immutable value object. [principalId] is the resolved identity's
/// non-secret id (E.24); [channel] distinguishes the same principal's
/// per-channel conversations; [conversationId] is the channel's conversation
/// handle, or `null` for a single-turn / conversationless channel (in which
/// case all of that principal's requests on that channel share one rolling
/// session).
final class SessionKey {
  /// The resolved principal's stable, non-secret id (E.24). Non-empty — an
  /// empty principal id cannot scope a conversation.
  final String principalId;

  /// The originating channel.
  final AccessChannel channel;

  /// The channel's conversation id, or `null` when the channel is
  /// single-turn. `null` is a first-class key value, not a wildcard: every
  /// conversationless request on (principal, channel) shares the one
  /// `null`-conversation session.
  final String? conversationId;

  /// Builds an immutable session key. [principalId] must be non-empty.
  SessionKey({
    required this.principalId,
    required this.channel,
    this.conversationId,
  }) {
    if (principalId.isEmpty) {
      throw ArgumentError.value(
        principalId,
        'principalId',
        'must be non-empty',
      );
    }
  }

  /// The record form used as the [SessionManager] map key. A Dart record's
  /// structural equality keys the store unambiguously — no delimiter, no
  /// collision between distinct triples.
  (String, AccessChannel, String?) get record =>
      (principalId, channel, conversationId);

  @override
  bool operator ==(Object other) =>
      other is SessionKey &&
      other.principalId == principalId &&
      other.channel == channel &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(principalId, channel, conversationId);

  @override
  String toString() => 'SessionKey(principalId: $principalId, '
      'channel: ${channel.wireName}, conversationId: $conversationId)';
}

/// One recorded inbound turn in a session's sliding window.
///
/// Immutable value object. The window is a list of these in arrival order;
/// the dispatcher never reads them — they are the access layer's record of
/// the conversation, the seam the E.27 / E.55 memory-node persistence reads.
final class SessionTurn {
  /// The session-local turn index, 0-based and monotonically increasing for
  /// the lifetime of the session (it is *not* reset when the window slides,
  /// so it always reflects the total number of turns seen before this one).
  final int index;

  /// The inbound prompt text of this turn.
  final String text;

  /// The originating channel's per-message id, when supplied
  /// (`InboundRequest.messageId`). `null` when the channel gave none.
  final String? messageId;

  /// When the turn was recorded (the manager's clock at resolution time).
  final DateTime at;

  /// Builds an immutable turn record.
  SessionTurn({
    required this.index,
    required this.text,
    required this.at,
    this.messageId,
  });

  @override
  String toString() =>
      'SessionTurn(index: $index, messageId: $messageId, at: $at)';
}

/// The rich, sliding-window session node.
///
/// The shared [Session] handle (§ 4.4) carries only the identity the
/// dispatcher reads; this node carries the window, the running turn count,
/// and the lifecycle timestamps the access layer keeps. The window holds at
/// most [maxWindowTurns] turns — the oldest is evicted when a new turn
/// overflows it ("sliding window", AC-8). The node is created once per key
/// and reused thereafter; only the [SessionManager] mutates it.
final class SessionNode {
  /// The stable session id — the value placed on the shared [Session]
  /// handle and the key under which the memory-owned session node will be
  /// stored (E.27 / E.55). Generated once at creation; stable across reuse.
  final String sessionId;

  /// The key this node was created for.
  final SessionKey key;

  /// When the node was first created.
  final DateTime createdAt;

  /// The maximum number of turns retained in [window].
  final int maxWindowTurns;

  final List<SessionTurn> _window = [];
  DateTime _lastActivityAt;
  int _totalTurns = 0;

  SessionNode._({
    required this.sessionId,
    required this.key,
    required this.createdAt,
    required this.maxWindowTurns,
  }) : _lastActivityAt = createdAt;

  /// The conversation id this session belongs to, mirrored from [key].
  String? get conversationId => key.conversationId;

  /// The most recent turns, oldest first, capped at [maxWindowTurns].
  /// Unmodifiable — the window is mutated only through [_recordTurn].
  List<SessionTurn> get window => List.unmodifiable(_window);

  /// The number of turns currently held in the window
  /// (≤ [maxWindowTurns]).
  int get windowLength => _window.length;

  /// The total number of turns ever seen by this session, including those
  /// already evicted from the window.
  int get totalTurns => _totalTurns;

  /// When the most recent turn was recorded.
  DateTime get lastActivityAt => _lastActivityAt;

  /// Appends [turn], slides the window if it overflows [maxWindowTurns], and
  /// advances the activity clock. Private to the library: only the
  /// [SessionManager] records turns.
  void _recordTurn(SessionTurn turn) {
    _window.add(turn);
    _totalTurns++;
    _lastActivityAt = turn.at;
    while (_window.length > maxWindowTurns) {
      _window.removeAt(0);
    }
  }

  /// Projects this node onto the minimal shared [Session] handle the
  /// dispatcher threads through the `Access` (§ 4.4).
  Session toSessionHandle() =>
      Session(sessionId: sessionId, conversationId: conversationId);

  @override
  String toString() => 'SessionNode(sessionId: $sessionId, key: $key, '
      'totalTurns: $_totalTurns, windowLength: ${_window.length})';
}

/// Builds the [SessionNode.sessionId] for a freshly-created session. The
/// default ([SessionManager._defaultSessionId]) derives a readable,
/// deterministic id from the key; a deployment may inject another factory
/// (e.g. a UUID generator) without affecting reuse, since the id is
/// generated once and stored on the node.
typedef SessionIdFactory = String Function(SessionKey key);

/// The default sliding-window capacity: the last 20 turns of a conversation
/// are retained. Chosen as a sensible prototype default; configurable per
/// [SessionManager].
const int defaultMaxWindowTurns = 20;

/// Resolves an inbound request to its [SessionNode], keyed by (principal,
/// channel, conversation id), creating the node on first contact and reusing
/// it — sliding the window — thereafter (proto spec § 7.2, AC-8).
///
/// In-process for the prototype: the manager owns the node store; the
/// memory-node persistence is wired through the dispatcher at E.27 / E.55
/// (see the file header). Single-threaded by construction — the access
/// process resolves sessions on its request path, not concurrently.
final class SessionManager {
  /// The sliding-window capacity applied to every node this manager creates.
  final int maxWindowTurns;

  final SessionIdFactory _sessionIdFactory;
  final DateTime Function() _now;
  final Map<(String, AccessChannel, String?), SessionNode> _nodes = {};

  /// Builds a session manager.
  ///
  /// [maxWindowTurns] (default [defaultMaxWindowTurns]) caps each session's
  /// window and must be at least 1. [sessionIdFactory] builds a new node's
  /// id (default: a readable, deterministic derivation from the key).
  /// [now] is the clock used for turn timestamps (default: [systemClock]),
  /// injectable so tests can assert lifecycle timestamps deterministically.
  SessionManager({
    this.maxWindowTurns = defaultMaxWindowTurns,
    SessionIdFactory? sessionIdFactory,
    DateTime Function()? now,
  })  : _sessionIdFactory = sessionIdFactory ?? _defaultSessionId,
        _now = now ?? systemClock {
    if (maxWindowTurns < 1) {
      throw ArgumentError.value(
        maxWindowTurns,
        'maxWindowTurns',
        'must be at least 1',
      );
    }
  }

  /// The number of distinct sessions currently held.
  ///
  /// The node map grows by one entry per distinct (principal, channel,
  /// conversation) key and never shrinks on its own in the prototype
  /// (Q-E.2.5). The bound is made explicit here and via [clear] / [evictIdle]
  /// rather than left as an unwritten assumption (G.3.3); a final-layer
  /// scheduler drives a periodic [evictIdle] to keep the map bounded by the
  /// *active* conversation set rather than the all-time one.
  int get sessionCount => _nodes.length;

  /// Drops all session state; every conversation starts a fresh node on its
  /// next [resolve]. The blunt eviction seam (a process restart already has
  /// this effect; this exposes it without one).
  void clear() => _nodes.clear();

  /// Evicts every session whose most recent turn is older than [idleFor]
  /// measured against the manager's clock — the conversations that have gone
  /// quiet long enough that retaining their window earns nothing. A re-arriving
  /// turn for an evicted key simply mints a fresh node, so eviction loses only
  /// the prior window (the prototype keeps no cross-restart history anyway,
  /// Q-E.2.5), never a correctness guarantee. The targeted complement to
  /// [clear]: the seam a final-layer idle-eviction policy reads.
  ///
  /// [idleFor] must be non-negative. Returns the number of evicted sessions.
  int evictIdle(Duration idleFor) {
    if (idleFor.isNegative) {
      throw ArgumentError.value(idleFor, 'idleFor', 'must be non-negative');
    }
    final cutoff = _now().subtract(idleFor);
    final idle = <(String, AccessChannel, String?)>[
      for (final entry in _nodes.entries)
        if (entry.value.lastActivityAt.isBefore(cutoff)) entry.key,
    ];
    for (final key in idle) {
      _nodes.remove(key);
    }
    return idle.length;
  }

  /// Resolves the session for one inbound request and records its turn.
  ///
  /// Builds the key from the resolved [identity] (its `principalId`), the
  /// originating [channel], and the [envelope]'s `conversationId`. Reuses
  /// the existing node for that key when present (appending the turn and
  /// sliding the window), else creates one. Returns the node; the caller
  /// projects [SessionNode.toSessionHandle] onto the `Access`.
  SessionNode resolve({
    required ResolvedIdentity identity,
    required AccessChannel channel,
    required InboundRequest envelope,
  }) {
    final key = SessionKey(
      principalId: identity.principalId,
      channel: channel,
      conversationId: envelope.conversationId,
    );
    final now = _now();
    final node = _nodes.putIfAbsent(
      key.record,
      () => SessionNode._(
        sessionId: _sessionIdFactory(key),
        key: key,
        createdAt: now,
        maxWindowTurns: maxWindowTurns,
      ),
    );
    node._recordTurn(SessionTurn(
      index: node.totalTurns,
      text: envelope.text,
      messageId: envelope.messageId,
      at: now,
    ));
    return node;
  }

  /// Returns the node for [key] without creating or mutating it, or `null`
  /// if no session has been resolved for that key yet. A read-only accessor
  /// for inspection (boot diagnostics, tests).
  SessionNode? peek(SessionKey key) => _nodes[key.record];

  /// The default [SessionIdFactory]: a readable id derived from the key.
  /// Deterministic per key, so the same conversation always yields the same
  /// id; correctness of reuse is guaranteed by the record-keyed store, not
  /// by this string.
  static String _defaultSessionId(SessionKey key) =>
      'sess:${key.channel.wireName}:'
      '${key.conversationId ?? 'default'}:${key.principalId}';
}
