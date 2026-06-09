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
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SelectionSettings;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'history_markdown.dart';
import 'history_store.dart';
import 'memory_profile_selector.dart';

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

/// One per-session entry: its dedicated history, the activity clock
/// [SessionManager.evictIdle] reads, and the Extension-H memory-profile
/// selection state the manager threads across the conversation's turns
/// (access spec § 7.4). Private to the library — only the manager mutates it.
class _SessionEntry {
  final ConversationHistory history;
  DateTime lastActivityAt;

  /// The principal this session belongs to, or `null` while unknown (a session
  /// the Telegram registry adopted via [SessionManager.ensureSession] before any
  /// [SessionManager.resolve] turn has attributed it). Filled in on the first
  /// resolve, so the readable-markdown mirror can file the session under its
  /// principal (access spec § 6.5 / § 21.10).
  String? principalId;

  /// The channel this session belongs to, or `null` while unknown (see
  /// [principalId]). Filled in on the first resolve.
  AccessChannel? channel;

  /// The confidently pinned memory profile, or `null` while the conversation is
  /// still on the default (never selected, or last selection inconclusive).
  String? pinnedProfile;

  /// Whether a selection pass has ever run for this session — distinguishes the
  /// first admitted prompt (always selects, when enabled) from later turns.
  bool everSelected;

  /// Whether the last selection pass was inconclusive (below threshold, unknown
  /// profile, or selector failure) and the conversation is on the default,
  /// awaiting a re-check. Drives the `access.profile.repinned` transition.
  bool selectionInconclusive;

  /// Turns elapsed since the last selector call while inconclusive — the
  /// `recheckEveryNTurns` window counter. Reset to `0` on every selector call.
  int turnsSinceProfileCheck;

  _SessionEntry({
    required this.history,
    required this.lastActivityAt,
    this.principalId,
    this.channel,
    this.pinnedProfile,
    this.everSelected = false,
    this.selectionInconclusive = false,
    this.turnsSinceProfileCheck = 0,
  });
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

  /// Rehydrates a snapshot from its [toJson] document — the on-disk restart
  /// seam ([JsonFileHistoryStore], access spec § 21.10). A missing or malformed
  /// section reads as empty rather than throwing here: structural validation of
  /// the file is the store's job ([HistoryStoreException]); this codec is
  /// tolerant of partial documents so an older snapshot still loads what it can.
  factory SessionHistoriesSnapshot.fromJson(Map<String, Object?> json) {
    final globals = <(String, AccessChannel), ConversationHistory>{};
    final globalsJson = json['globals'];
    if (globalsJson is List) {
      for (final entry in globalsJson.whereType<Map<String, Object?>>()) {
        final principalId = entry['principalId'] as String?;
        final channel = _channelFromWire(entry['channel'] as String?);
        final historyJson = entry['history'];
        if (principalId == null ||
            channel == null ||
            historyJson is! Map<String, Object?>) {
          continue;
        }
        globals[(principalId, channel)] =
            ConversationHistory.fromJson(historyJson);
      }
    }

    final sessions = <String, _SessionEntry>{};
    final sessionsJson = json['sessions'];
    if (sessionsJson is Map<String, Object?>) {
      sessionsJson.forEach((id, value) {
        if (value is! Map<String, Object?>) return;
        final historyJson = value['history'];
        if (historyJson is! Map<String, Object?>) return;
        sessions[id] = _SessionEntry(
          history: ConversationHistory.fromJson(historyJson),
          lastActivityAt: DateTime.tryParse(
                (value['lastActivityAt'] as String?) ?? '',
              ) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          principalId: value['principalId'] as String?,
          channel: _channelFromWire(value['channel'] as String?),
          pinnedProfile: value['pinnedProfile'] as String?,
          everSelected: (value['everSelected'] as bool?) ?? false,
          selectionInconclusive:
              (value['selectionInconclusive'] as bool?) ?? false,
          turnsSinceProfileCheck:
              (value['turnsSinceProfileCheck'] as num?)?.toInt() ?? 0,
        );
      });
    }

    return SessionHistoriesSnapshot._(globals, sessions);
  }

  /// The snapshot as a JSON-encodable document covering both history stores.
  ///
  /// Globals serialize as a list (their `(principalId, channel)` key is a Dart
  /// record, not a JSON-able string) and sessions as a map keyed by the
  /// brain-minted session id — so a restored id is attachable again, an echoing
  /// request resolves it as known (access spec § 21.10).
  Map<String, Object?> toJson() => <String, Object?>{
        'globals': [
          for (final e in _globals.entries)
            <String, Object?>{
              'principalId': e.key.$1,
              'channel': e.key.$2.wireName,
              'history': e.value.toJson(),
            },
        ],
        'sessions': <String, Object?>{
          for (final e in _sessions.entries)
            e.key: <String, Object?>{
              'history': e.value.history.toJson(),
              'lastActivityAt': e.value.lastActivityAt.toIso8601String(),
              if (e.value.principalId != null)
                'principalId': e.value.principalId,
              if (e.value.channel != null) 'channel': e.value.channel!.wireName,
              if (e.value.pinnedProfile != null)
                'pinnedProfile': e.value.pinnedProfile,
              'everSelected': e.value.everSelected,
              'selectionInconclusive': e.value.selectionInconclusive,
              'turnsSinceProfileCheck': e.value.turnsSinceProfileCheck,
            },
        },
      };

  /// Resolves a persisted [wireName] back to its [AccessChannel], or `null`
  /// when the name is absent or unknown (a global with an unknown channel is
  /// skipped rather than crashing the whole restore).
  static AccessChannel? _channelFromWire(String? wireName) {
    if (wireName == null) return null;
    for (final c in AccessChannel.values) {
      if (c.wireName == wireName) return c;
    }
    return null;
  }

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

  /// The memory-profile selector (Extension H, access spec § 7.4), or `null`
  /// when none is wired. When `null` — or when [_selection] is disabled —
  /// [selectMemoryProfile] makes no selector call and the conversation stays on
  /// the process default profile.
  final MemoryProfileSelector? _profileSelector;

  /// The selection policy: whether selection is enabled, the default profile
  /// name, the inconclusive threshold, the re-check window, and whether to feed
  /// the selector the conversation history (`useHistory`).
  final SelectionSettings _selection;

  /// The "all prompts" history per (principal, channel). Never idle-evicted.
  final Map<(String, AccessChannel), ConversationHistory> _globals = {};

  /// The dedicated per-session histories, keyed by the brain-minted id.
  final Map<String, _SessionEntry> _sessions = {};

  /// The durable backing for both history stores, or `null` for an in-process
  /// (non-durable) manager. When present, the manager rehydrates from it on
  /// construction and [persist] writes the live snapshot back to it — the
  /// "nothing is ever lost" restart contract (umbrella Hard principle 6).
  final HistoryStore? _store;

  /// The readable-markdown mirror sink. [persist] renders each live history into
  /// per-principal / per-session `.raw.md` + `.memory.md` files through it, so an
  /// operator can read what the brain remembers (access spec § 21.10). Defaults
  /// to a no-op ([NullHistoryMarkdownSink]) — the mirror is opt-in; the JSON
  /// snapshot remains the source of truth.
  final HistoryMarkdownSink _markdownSink;

  /// Builds a session manager.
  ///
  /// [sizing] (default [HistorySizing.standard]) shapes each history's window
  /// and compaction thresholds. [sessionIdMinter] mints fresh ids (default: a
  /// process-unique counter+timestamp closure); a deployment may inject a UUID
  /// minter. [now] is the clock used for the per-session activity timestamps
  /// [evictIdle] reads (default: [systemClock]), injectable so tests can drive
  /// eviction deterministically. [profileSelector] is the Extension-H selector
  /// (access spec § 7.4); when omitted (or when [selection] is disabled),
  /// [selectMemoryProfile] never calls the substrate and the conversation stays
  /// on the process default profile. [selection] is the selection policy
  /// (default: disabled). [historyStore] is the durable backing: when given,
  /// the manager loads any persisted histories from it now (so a restart
  /// resumes mid-conversation) and [persist] writes back to it; when omitted
  /// the manager is in-process only (the prototype's original behaviour).
  SessionManager({
    this.sizing = const HistorySizing.standard(),
    SessionIdMinter? sessionIdMinter,
    DateTime Function()? now,
    MemoryProfileSelector? profileSelector,
    SelectionSettings selection = const SelectionSettings(),
    HistoryStore? historyStore,
    HistoryMarkdownSink markdownSink = const NullHistoryMarkdownSink(),
  })  : _mint = sessionIdMinter ?? _defaultMinter(),
        _now = now ?? systemClock,
        _profileSelector = profileSelector,
        _selection = selection,
        _store = historyStore,
        _markdownSink = markdownSink {
    final store = _store;
    if (store != null) {
      final document = store.load();
      if (document.isNotEmpty) {
        restore(SessionHistoriesSnapshot.fromJson(document));
      }
    }
  }

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
      entry.principalId = identity.principalId;
      entry.channel = channel;
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
      principalId: identity.principalId,
      channel: channel,
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

  /// Mirrors a just-answered turn's answer into the per-(principal, channel)
  /// global "all prompts" history (§ 7.2; umbrella Hard principle 6 — "no event
  /// is ever truly lost").
  ///
  /// The engine back-fills its answer into the *answered-from* history only
  /// ([SessionResolution.history], via `amendLastTurnAnswer`, hub § 21.1 step 4).
  /// For a **known dedicated session** that answered-from history is the
  /// per-session one, while the global history recorded the same turn with an
  /// empty answer ([resolve] appends the turn to both). Without this mirror the
  /// global record accumulates every prompt with a blank reply — the durable
  /// "all prompts" archive silently loses the answers. This copies the
  /// dedicated history's last answer onto the global's matching turn.
  ///
  /// A no-op when the resolution answered from the global directly (a
  /// sessionless / unknown-id / global-session turn): the two histories are the
  /// same object, so the dispatcher already amended it. Idempotent — relies on
  /// [ConversationHistory.amendLastTurnAnswer]'s "skip a turn that already
  /// carries a non-empty answer" guard. The brain answer is unknown at
  /// [resolve] time, so this is the access layer's post-dispatch reconciliation.
  void backfillGlobalAnswer({
    required ResolvedIdentity identity,
    required AccessChannel channel,
    required SessionResolution resolution,
  }) {
    final global = _globals[(identity.principalId, channel)];
    if (global == null || identical(global, resolution.history)) {
      // No global yet, or it *is* the answered-from history (already amended).
      return;
    }
    final answered = resolution.history.durableRecord;
    if (answered.isEmpty) return;
    final answer = answered.last.brainAnswer;
    if (answer.isEmpty) return;
    global.amendLastTurnAnswer(answer);
  }

  /// Runs the Extension-H memory-profile selection pass for a just-resolved
  /// request (access spec § 7.4; hub § 23.6). Access owns the session, so access
  /// owns which memory profile a conversation recalls against; the dispatcher
  /// reads the pinned name off `Session.memoryProfile` downstream.
  ///
  /// The state machine, per session:
  ///
  ///   * selection disabled, or no selector wired → `disabled`, process default
  ///     (no pinned name), no selector call.
  ///   * already confidently pinned → `alreadyPinned`, the pinned name reused,
  ///     no selector call.
  ///   * within the re-check window after an inconclusive pick → `deferred`, the
  ///     default profile, no selector call.
  ///   * otherwise run the `profile_selector` role (first prompt, or the
  ///     re-check window reached). On the result:
  ///     - confidence ≥ `inconclusiveThreshold` and a known profile → pin it
  ///       (`pinned`, or `repinned` + `access.profile.repinned` when a prior
  ///       pick was inconclusive);
  ///     - below threshold → `inconclusive`, the default profile, re-check after
  ///       the window;
  ///     - unknown profile → `profileUnknown` + `access.profile.unknown`,
  ///       default, stay inconclusive;
  ///     - selector throws → `selectorUnavailable` +
  ///       `access.profile.selector.unavailable`, default, stay inconclusive
  ///       (PE-6 graceful degrade).
  ///
  /// [resolution] must come from a prior [resolve] on this manager (its session
  /// id keys the per-session selection state). [envelope] supplies the prompt;
  /// the conversation history (when `selection.useHistory`) is read from
  /// [resolution]'s history.
  Future<MemoryProfileSelectionOutcome> selectMemoryProfile({
    required SessionResolution resolution,
    required InboundRequest envelope,
  }) async {
    final selector = _profileSelector;
    if (!_selection.enabled || selector == null) {
      return const MemoryProfileSelectionOutcome(
        status: MemoryProfileSelectionStatus.disabled,
        profile: null,
      );
    }

    final entry = _sessions[resolution.sessionId];
    if (entry == null) {
      // The resolution was not produced by this manager — no session state to
      // pin against. Degrade to the process default.
      return const MemoryProfileSelectionOutcome(
        status: MemoryProfileSelectionStatus.disabled,
        profile: null,
      );
    }

    // Already confident → reuse, no selector call.
    if (entry.pinnedProfile != null) {
      return MemoryProfileSelectionOutcome(
        status: MemoryProfileSelectionStatus.alreadyPinned,
        profile: entry.pinnedProfile,
      );
    }

    // Not yet pinned. After the first (inconclusive) pass, defer the re-run
    // until the re-check window is reached.
    if (entry.everSelected) {
      entry.turnsSinceProfileCheck++;
      if (entry.turnsSinceProfileCheck < _selection.recheckEveryNTurns) {
        return MemoryProfileSelectionOutcome(
          status: MemoryProfileSelectionStatus.deferred,
          profile: _selection.defaultProfile,
        );
      }
    }

    final history = _selection.useHistory
        ? resolution.history.durableRecord
        : const <HistoryTurn>[];

    final ProfileSelection pick;
    try {
      pick = await selector.select(prompt: envelope.text, history: history);
    } on Object {
      // PE-6 graceful degrade: a selector failure falls back to the default and
      // stays inconclusive, so the next window re-runs.
      entry.everSelected = true;
      entry.selectionInconclusive = true;
      entry.turnsSinceProfileCheck = 0;
      return MemoryProfileSelectionOutcome(
        status: MemoryProfileSelectionStatus.selectorUnavailable,
        profile: _selection.defaultProfile,
        code: accessProfileSelectorUnavailableCode,
      );
    }

    final wasInconclusive = entry.selectionInconclusive;
    entry.everSelected = true;
    entry.turnsSinceProfileCheck = 0;

    if (!pick.isKnownProfile) {
      entry.selectionInconclusive = true;
      return MemoryProfileSelectionOutcome(
        status: MemoryProfileSelectionStatus.profileUnknown,
        profile: _selection.defaultProfile,
        confidence: pick.confidence,
        code: accessProfileUnknownCode,
      );
    }

    if (pick.confidence >= _selection.inconclusiveThreshold) {
      entry.pinnedProfile = pick.profile;
      entry.selectionInconclusive = false;
      return MemoryProfileSelectionOutcome(
        status: wasInconclusive
            ? MemoryProfileSelectionStatus.repinned
            : MemoryProfileSelectionStatus.pinned,
        profile: pick.profile,
        confidence: pick.confidence,
        code: wasInconclusive ? accessProfileRepinnedCode : null,
      );
    }

    // Below threshold → inconclusive, use the default, re-check after the window.
    entry.selectionInconclusive = true;
    return MemoryProfileSelectionOutcome(
      status: MemoryProfileSelectionStatus.inconclusive,
      profile: _selection.defaultProfile,
      confidence: pick.confidence,
    );
  }

  /// Returns the confidently pinned memory profile for [sessionId] without
  /// creating or mutating it, or `null` when none is pinned (selection off,
  /// never selected, or the last pick was inconclusive). A read-only accessor
  /// for inspection (boot diagnostics, tests).
  String? peekMemoryProfile(String sessionId) =>
      _sessions[sessionId]?.pinnedProfile;

  /// Returns the dedicated per-session history for [sessionId] without
  /// creating or mutating it, or `null` if no session has been registered
  /// under that id. A read-only accessor for inspection (boot diagnostics,
  /// tests).
  ConversationHistory? peekSession(String sessionId) =>
      _sessions[sessionId]?.history;

  /// Whether [sessionId] is a known dedicated session — i.e. one [resolve]
  /// would answer from its own history rather than re-mint as unknown.
  ///
  /// The adoption seam for an *id minted outside the manager but inside the
  /// brain* (the Telegram session registry, access spec § 6.5 / § 7.2). The
  /// brain owns the session-id space; the registry mints ids on the user's
  /// behalf and registers them with [ensureSession] so [resolve] treats them
  /// as known.
  bool hasSession(String sessionId) => _sessions.containsKey(sessionId);

  /// Registers an empty dedicated session under [sessionId] if none exists,
  /// so a subsequent [resolve] of that id answers from (and accumulates) its
  /// own history rather than re-minting it as unknown. A no-op when the id is
  /// already known — it never clears an accumulated history.
  ///
  /// The companion to [hasSession]: the Telegram session registry calls this
  /// for every non-null id it hands out (including ids remembered across a
  /// restart) so the brain adopts its own minted ids (access spec § 6.5).
  void ensureSession(String sessionId) {
    _sessions.putIfAbsent(
      sessionId,
      () => _SessionEntry(
        history: ConversationHistory(sizing: sizing),
        lastActivityAt: _now(),
      ),
    );
  }

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
          for (final e in _sessions.entries) e.key: _copyEntry(e.value),
        },
      );

  /// Writes the live histories to the durable [HistoryStore], if one is wired.
  ///
  /// The save seam (access spec § 21.10): the dispatcher calls this once a turn
  /// has been answered and back-filled into its history, so the exchange
  /// survives a process restart. A no-op for an in-process manager (no store).
  /// Serializes the whole snapshot every call — prompts are slow (a full
  /// thinking loop), so a synchronous full-document write per turn is not a
  /// performance concern, and it keeps the "nothing is ever lost" contract
  /// simple (no incremental-write bookkeeping to get wrong).
  void persist() {
    final store = _store;
    if (store != null) {
      store.save(snapshot().toJson());
    }
    // The readable mirror runs independently of the JSON store: a deployment may
    // want human-readable history without the opaque snapshot, or both. The
    // records are a lazy iterable, so the default no-op sink computes nothing.
    _markdownSink.write(_readableHistoryRecords());
  }

  /// Lazily builds one [HistoryMarkdownRecord] per live history — the global
  /// "all prompts" record for each (principal, channel) and each dedicated
  /// session — filed under per-principal / per-session path segments
  /// (access spec § 21.10). A session whose principal is not yet known (adopted
  /// but never resolved) is filed under `_unattached` rather than dropped.
  Iterable<HistoryMarkdownRecord> _readableHistoryRecords() sync* {
    for (final e in _globals.entries) {
      final (principalId, channel) = e.key;
      yield HistoryMarkdownRecord(
        pathSegments: [principalId, channel.wireName, 'global'],
        title: '$principalId / ${channel.wireName} / global',
        history: e.value,
      );
    }
    for (final e in _sessions.entries) {
      final entry = e.value;
      final principalId = entry.principalId;
      final channel = entry.channel;
      if (principalId != null && channel != null) {
        yield HistoryMarkdownRecord(
          pathSegments: [principalId, channel.wireName, 'sessions', e.key],
          title: '$principalId / ${channel.wireName} / session ${e.key}',
          history: entry.history,
        );
      } else {
        yield HistoryMarkdownRecord(
          pathSegments: ['_unattached', 'sessions', e.key],
          title: 'unattached / session ${e.key}',
          history: entry.history,
        );
      }
    }
  }

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
        for (final e in snapshot._sessions.entries) e.key: _copyEntry(e.value),
      });
  }

  /// Deep-copies a [_SessionEntry], carrying its history and its Extension-H
  /// selection state so a restart preserves the pinned profile and the
  /// re-check window position (access spec § 7.4 / § 21.10).
  static _SessionEntry _copyEntry(_SessionEntry e) => _SessionEntry(
        history: _copyHistory(e.history),
        lastActivityAt: e.lastActivityAt,
        principalId: e.principalId,
        channel: e.channel,
        pinnedProfile: e.pinnedProfile,
        everSelected: e.everSelected,
        selectionInconclusive: e.selectionInconclusive,
        turnsSinceProfileCheck: e.turnsSinceProfileCheck,
      );

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

  /// The default [SessionIdMinter]: a bare UTC timestamp
  /// (`YYMMDD-HHMMSS.ssssss`, monotonic-unique — logging-spec §3), so every
  /// session id is distinct and every session-keyed trail file starts with its
  /// timestamp. Correctness of reuse is guaranteed by the id-keyed store, not by
  /// the string's shape.
  static SessionIdMinter _defaultMinter() =>
      () => TimestampId.generate().value;
}
