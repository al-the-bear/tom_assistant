// `SessionManager` — the edge step that resolves *which conversation* an
// inbound request belongs to and hands the engine the history it answers
// from (Extension G; plan step #22; access spec § 7.2 / § 21.2).
//
// What this file owns:
//
//   * `AccessChannel` — the channel discriminator (`openai` / `telegram` /
//     `ollama` / `anthropic`). It is the second component of the global
//     history key. Identity is the *person* (E.24, channel-blind by design —
//     same `principalId` on every channel); the channel distinction lives
//     here, so the same principal's OpenAI history and Telegram history are
//     different histories (access spec § 7.1 / § 7.2).
//   * `SessionIdMinter` — mints a fresh, unique session id whenever a request
//     arrives without one (or echoes an unknown one). The brain owns the id
//     space (§ 7.2): the client never invents an id, it only echoes one the
//     brain previously minted.
//   * `SessionResolution` — the result of [SessionManager.resolve]: the
//     shared `Session` handle, the `ConversationHistory` the engine answers
//     from, the resolved id, and the two diagnostic flags (`mintedNewId`,
//     `unknownSessionId`) that drive the `access.session.*` observability
//     events (§ 14).
//   * `SessionHistoriesSnapshot` — an opaque, point-in-time deep copy of both
//     history stores; the in-process stand-in for the memory-node persistence
//     the real layer wires at E.27 / E.55 (§ 21.10). `snapshot` / `restore`
//     round-trip it, so a "restart" preserves both histories.
//   * `SessionManager` — resolves every request against two history stores:
//
//       1. A **global history** per `(principalId, channel)` — "all prompts"
//          (§ 7.2). *Every* request appends here, sessioned or not. Never
//          idle-evicted.
//       2. A **per-session `ConversationHistory`** keyed by the brain-minted
//          id string. A sessioned request that echoes a known id appends to
//          its dedicated history (and the global); a sessionless request mints
//          a fresh id and registers an *empty* dedicated history, with the
//          originating turn going to the global only.
//
// The two-history split (§ 7.2, point 1):
//
//   * Sessionless (`envelope.sessionId == null`) → mint a fresh id, register
//     an empty dedicated history under it, append the turn to the **global**
//     history, and answer from the global. The minted id is handed back so
//     the client can attach to its dedicated history on the next turn.
//   * Known echoed id (in the per-session store) → append the turn to **both**
//     the dedicated history and the global, and answer from the dedicated
//     one.
//   * Unknown echoed id (not in the per-session store) → graceful recovery,
//     not an error (§ 14, `access.session.unknown`): treat it like a
//     sessionless request (mint a fresh id, empty dedicated history, append to
//     the global, answer from the global) and raise the `unknownSessionId`
//     flag. The bogus id is never registered.
//
// Why an in-process store (not a memory write) in the prototype:
//
//   The access layer deliberately does NOT depend on `tom_brain_memory` (every
//   memory write goes through the dispatcher, never around it). So this
//   manager owns the *resolution* (id → history) and produces the shared
//   handle; the durable memory-node persistence is the integration point wired
//   through the dispatcher at E.27 / E.55. `snapshot` / `restore` model that
//   persistence in-process so the restart contract is testable now.
//
// Scope discipline. This step is the conversation → history resolver only. It
// does NOT resolve identity (E.24 — it *consumes* the resolved `principalId`),
// resolve personas (E.26), persist to `tom_brain_memory` (E.27 / E.55),
// construct an `Access`, or wire boot (E.41+). The brain answer is back-filled
// downstream by the engine (hub § 21.1); the manager records the prompt with
// an empty answer.

import 'package:tom_core_agentic/tom_core_agentic.dart' show systemClock;
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// The originating channel of an inbound request — the second component of a
/// global history key.
///
/// Identity (E.24) is channel-blind: the same person maps to one
/// `principalId` whether they arrive over OpenAI or Telegram. The channel
/// distinction is the history's job, so a principal's OpenAI conversation and
/// Telegram conversation resolve to *different* global histories (access spec
/// § 7.2).
enum AccessChannel {
  /// The OpenAI HTTP/SSE adapter (E.3).
  openai('openai'),

  /// The Telegram adapter (E.4).
  telegram('telegram'),

  /// The Ollama HTTP adapter (plan-2 #27). A bearer HTTP channel like
  /// [openai]; its adapter renders its own NDJSON / buffered-JSON dialect
  /// from the raw `OutboundChunk` stream (it does not reuse the SSE path).
  ollama('ollama'),

  /// The Anthropic Messages HTTP adapter (plan-2 #28). A bearer HTTP channel
  /// like [openai]; its adapter renders its own named-SSE / buffered-Message
  /// dialect from the raw `OutboundChunk` stream.
  anthropic('anthropic');

  const AccessChannel(this.wireName);

  /// The stable, lower-case channel name. Matches the `channel` strings the
  /// sibling `IdentityResolutionException` (E.24) already uses, so logs read
  /// consistently across the resolvers.
  final String wireName;
}

/// Mints a fresh, unique session id. Called whenever a request arrives without
/// a session id, or echoes one the brain does not recognise.
///
/// The brain owns the session id space (access spec § 7.2): the client never
/// invents an id, it only echoes one the brain previously minted. A minter
/// must return a *distinct* id on every call — two conversations that shared an
/// id would share a history.
typedef SessionIdMinter = String Function();

/// The result of resolving one inbound request to its conversation.
///
/// Carries the shared [session] handle the dispatcher threads onto the
/// `Access`, the [history] the engine answers from (the dedicated per-session
/// history for a known echoed id, the global history otherwise), the resolved
/// [sessionId], and the two diagnostic flags that drive the `access.session.*`
/// observability events (§ 14). Immutable.
final class SessionResolution {
  /// The minimal shared conversation handle (§ 4.4) — `sessionId` plus the
  /// originating channel's conversation id.
  final Session session;

  /// The history the engine answers from: the dedicated per-session history
  /// when the request echoed a known id, otherwise the per-(principal,
  /// channel) global history.
  final ConversationHistory history;

  /// The resolved session id — the freshly minted id for a sessionless or
  /// unknown-id request, or the echoed id for a known one.
  final String sessionId;

  /// Whether [sessionId] was freshly minted this turn (true for a sessionless
  /// or unknown-id request, false for a known echoed id). Drives
  /// `access.session.created`.
  final bool mintedNewId;

  /// Whether the request echoed an id the manager did not recognise — graceful
  /// recovery, not an error (§ 14, `access.session.unknown`).
  final bool unknownSessionId;

  /// Builds an immutable resolution.
  const SessionResolution({
    required this.session,
    required this.history,
    required this.sessionId,
    required this.mintedNewId,
    required this.unknownSessionId,
  });

  @override
  String toString() => 'SessionResolution(sessionId: $sessionId, '
      'mintedNewId: $mintedNewId, unknownSessionId: $unknownSessionId)';
}

/// One per-session entry: its dedicated history plus the activity clock
/// [SessionManager.evictIdle] reads. Private to the library — only the manager
/// mutates it.
class _SessionEntry {
  final ConversationHistory history;
  DateTime lastActivityAt;
  _SessionEntry({required this.history, required this.lastActivityAt});
}

/// An opaque, point-in-time deep copy of a [SessionManager]'s two history
/// stores — the in-process stand-in for the memory-node persistence the real
/// layer wires at E.27 / E.55 (access spec § 21.10).
///
/// Produced by [SessionManager.snapshot] and consumed by
/// [SessionManager.restore]. Both ends deep-copy, so a snapshot shares no
/// mutable state with the manager it came from or the one it is restored into:
/// a turn appended after the snapshot cannot leak into a restored copy.
final class SessionHistoriesSnapshot {
  final Map<(String, AccessChannel), ConversationHistory> _globals;
  final Map<String, _SessionEntry> _sessions;

  SessionHistoriesSnapshot._(this._globals, this._sessions);

  /// The number of global histories captured.
  int get globalCount => _globals.length;

  /// The number of dedicated per-session histories captured.
  int get sessionCount => _sessions.length;
}

/// Resolves an inbound request to its conversation history, minting a session
/// id when one is absent or unrecognised (access spec § 7.2 / § 21.2).
///
/// In-process for the prototype: the manager owns both history stores; the
/// durable memory-node persistence is wired through the dispatcher at E.27 /
/// E.55 (see the file header). Single-threaded by construction — the access
/// process resolves on its request path, not concurrently.
final class SessionManager {
  /// The sizing applied to every history this manager creates.
  final HistorySizing sizing;

  final SessionIdMinter _mint;
  final DateTime Function() _now;

  /// The "all prompts" history per (principal, channel). Never idle-evicted.
  final Map<(String, AccessChannel), ConversationHistory> _globals = {};

  /// The dedicated per-session histories, keyed by the brain-minted id.
  final Map<String, _SessionEntry> _sessions = {};

  /// Builds a session manager.
  ///
  /// [sizing] (default [HistorySizing.standard]) shapes each history's window
  /// and compaction thresholds. [sessionIdMinter] mints fresh ids (default: a
  /// process-unique counter+timestamp closure); a deployment may inject a UUID
  /// minter. [now] is the clock used for the per-session activity timestamps
  /// [evictIdle] reads (default: [systemClock]), injectable so tests can drive
  /// eviction deterministically.
  SessionManager({
    this.sizing = const HistorySizing.standard(),
    SessionIdMinter? sessionIdMinter,
    DateTime Function()? now,
  })  : _mint = sessionIdMinter ?? _defaultMinter(),
        _now = now ?? systemClock;

  /// The number of dedicated per-session histories currently held — *not* the
  /// global histories (which are bounded by the active (principal, channel)
  /// set, not the conversation set). Bounded by [clear] / [evictIdle].
  int get sessionCount => _sessions.length;

  /// Drops every history — global and per-session. The blunt eviction seam (a
  /// process restart already has this effect; this exposes it without one).
  void clear() {
    _globals.clear();
    _sessions.clear();
  }

  /// Evicts every dedicated per-session history whose most recent activity is
  /// older than [idleFor] measured against the manager's clock. The global
  /// histories are never evicted — they are the durable "all prompts" record
  /// (§ 7.2). A re-arriving turn for an evicted id is treated as an unknown id
  /// (graceful recovery), so eviction loses only the dedicated window, never a
  /// correctness guarantee.
  ///
  /// [idleFor] must be non-negative. Returns the number of evicted sessions.
  int evictIdle(Duration idleFor) {
    if (idleFor.isNegative) {
      throw ArgumentError.value(idleFor, 'idleFor', 'must be non-negative');
    }
    final cutoff = _now().subtract(idleFor);
    final idle = <String>[
      for (final entry in _sessions.entries)
        if (entry.value.lastActivityAt.isBefore(cutoff)) entry.key,
    ];
    for (final id in idle) {
      _sessions.remove(id);
    }
    return idle.length;
  }

  /// Resolves the conversation for one inbound request and records its turn.
  ///
  /// Appends the request's turn to the global history for ([identity]'s
  /// `principalId`, [channel]), and — when the request echoes a known session
  /// id — to that id's dedicated history too. Mints a fresh id for a
  /// sessionless or unknown-id request (§ 7.2). Returns a [SessionResolution];
  /// the engine answers from its [SessionResolution.history].
  ///
  /// The brain answer is unknown at resolution time, so the recorded
  /// [HistoryTurn] carries an empty `brainAnswer`; the engine back-fills it
  /// downstream (hub § 21.1 step 4).
  SessionResolution resolve({
    required ResolvedIdentity identity,
    required AccessChannel channel,
    required InboundRequest envelope,
  }) {
    final now = _now();
    final global = _globals.putIfAbsent(
      (identity.principalId, channel),
      () => ConversationHistory(sizing: sizing),
    );
    final turn = HistoryTurn(userPrompt: envelope.text, brainAnswer: '');

    final echoed = envelope.sessionId;
    if (echoed != null && _sessions.containsKey(echoed)) {
      // Known echoed id → append to both, answer from the dedicated history.
      final entry = _sessions[echoed]!;
      entry.history.append(turn);
      entry.lastActivityAt = now;
      global.append(turn);
      return SessionResolution(
        session: Session(sessionId: echoed, conversationId: envelope.conversationId),
        history: entry.history,
        sessionId: echoed,
        mintedNewId: false,
        unknownSessionId: false,
      );
    }

    // Sessionless, or an unknown echoed id (graceful recovery): mint a fresh
    // id, register an empty dedicated history under it, append the turn to the
    // global history only, and answer from the global.
    final mintedId = _mint();
    _sessions[mintedId] = _SessionEntry(
      history: ConversationHistory(sizing: sizing),
      lastActivityAt: now,
    );
    global.append(turn);
    return SessionResolution(
      session: Session(sessionId: mintedId, conversationId: envelope.conversationId),
      history: global,
      sessionId: mintedId,
      mintedNewId: true,
      unknownSessionId: echoed != null,
    );
  }

  /// Returns the dedicated per-session history for [sessionId] without
  /// creating or mutating it, or `null` if no session has been registered
  /// under that id. A read-only accessor for inspection (boot diagnostics,
  /// tests).
  ConversationHistory? peekSession(String sessionId) =>
      _sessions[sessionId]?.history;

  /// Returns the global "all prompts" history for ([principalId], [channel])
  /// without creating or mutating it, or `null` if none has been resolved yet.
  ConversationHistory? peekGlobal({
    required String principalId,
    required AccessChannel channel,
  }) =>
      _globals[(principalId, channel)];

  /// Captures a point-in-time deep copy of both history stores — the restart
  /// seam (§ 21.10). The returned snapshot shares no mutable state with this
  /// manager: later appends here cannot leak into it.
  SessionHistoriesSnapshot snapshot() => SessionHistoriesSnapshot._(
        {
          for (final e in _globals.entries) e.key: _copyHistory(e.value),
        },
        {
          for (final e in _sessions.entries)
            e.key: _SessionEntry(
              history: _copyHistory(e.value.history),
              lastActivityAt: e.value.lastActivityAt,
            ),
        },
      );

  /// Rehydrates this manager from [snapshot], replacing any current state. The
  /// restored histories are deep copies, so the manager and the snapshot stay
  /// independent (§ 21.10). A restored per-session id is attachable again — an
  /// echoing request resolves it as known.
  void restore(SessionHistoriesSnapshot snapshot) {
    _globals
      ..clear()
      ..addAll({
        for (final e in snapshot._globals.entries) e.key: _copyHistory(e.value),
      });
    _sessions
      ..clear()
      ..addAll({
        for (final e in snapshot._sessions.entries)
          e.key: _SessionEntry(
            history: _copyHistory(e.value.history),
            lastActivityAt: e.value.lastActivityAt,
          ),
      });
  }

  /// Deep-copies a [ConversationHistory] via its restore seam. [HistoryTurn] is
  /// immutable, so copying the list references is a full deep copy.
  static ConversationHistory _copyHistory(ConversationHistory h) =>
      ConversationHistory.restore(
        sizing: h.sizing,
        compactedSummary: h.compactedSummary,
        rawWindow: h.rawWindow,
        pending: h.pending,
        durableRecord: h.durableRecord,
      );

  /// The default [SessionIdMinter]: a process-unique counter behind a
  /// per-manager timestamp prefix, so every minted id is distinct (within and
  /// across managers). Correctness of reuse is guaranteed by the id-keyed
  /// store, not by the string's shape.
  static SessionIdMinter _defaultMinter() {
    var counter = 0;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return () => 'sess-$stamp-${counter++}';
  }
}
