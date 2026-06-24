// TelegramAccessEdge — the live Telegram channel of the running access
// process (E.45; proto spec § 6 / § 8 / § 11).
//
// ── What this is, and how it differs from `TelegramAdapter` ──────────
//
// `TelegramAdapter` (E.19–E.23) is the *wire* surface: it owns the
// long-polling loop, the inbound `ChatMessage` → `InboundRequest` mapping
// (E.20), the outbound consolidation (E.21), and the whitelist gate (E.22) —
// its `authorizedInboundRequests` stream emits exactly the requests a
// whitelisted sender produced, the graceful decline for a non-whitelisted
// one already sent. It is the transport contract, proven against the
// loopback backend (E.54).
//
// `TelegramAccessEdge` is the *running-process* surface: it subscribes to the
// adapter's `authorizedInboundRequests` and drives the E.41 `AccessAssembler`
// for each one, so every admitted request runs the full inbound flow —
// identity (E.24) → rate-limit (E.29) → quota (E.30) → anchor (E.31) →
// session (E.25) → classify (E.33) → delivery (E.38) → `dispatcher.accept`.
// The adapter has already authenticated the *sender*; the edge applies the
// per-principal gates and dispatches.
//
// ── Recovering the sender, and the graceful decline on a gate failure ─
//
// The assembler keys identity / rate-limit / quota on the Telegram sender id.
// That id rode the inbound mapping onto
// `InboundRequest.metadata[telegramSenderIdMetadataKey]` (E.20); the edge
// lifts it back out to call `admitTelegram(userId:)` and to address the
// graceful decline. A request that somehow carries no sender id cannot be
// addressed or admitted, so it is dropped (it should never happen on the
// authorized stream — the whitelist gate already read the same id).
//
// When a gate throws, the assembler has already emitted the correlated
// `AccessFailed` (its observability record) and rethrown for the edge to map
// onto the wire. Here the wire shape is a single plain Telegram message — the
// same graceful-decline vocabulary the rest of the channel uses
// (`telegramRateLimitMessage` / `telegramQuotaMessage` / `telegramAnchorMessage`
// / `telegramNotAuthorisedMessage`). The decline is best-effort: if sending it
// also throws, the edge swallows that (there is nothing more it can do) and
// moves on to the next inbound request.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show InboundRequest, ResolvedProfile, traceMemoryMetadataKey;
import 'package:tom_chattools/tom_chattools.dart' show ChatApi, ChatReceiver;

import '../adapters/telegram/telegram_inbound_mapping.dart'
    show telegramSenderIdMetadataKey;
import '../adapters/telegram/telegram_outbound_mapping.dart'
    show TelegramOutboundConsolidator;
import '../adapters/telegram/telegram_whitelist.dart'
    show telegramNotAuthorisedMessage;
import '../config/telegram_chat_profile_config.dart'
    show TelegramChatProfileConfig;
import '../delivery/telegram_delivery.dart' show ChatApiTelegramSink;
import '../edge_security/edge_security.dart';
import '../identity/telegram_command.dart';
import '../identity/telegram_session_registry.dart';
import 'access_assembler.dart';
import 'telegram_inspectors.dart';

/// Builds the startup announcement the Telegram channel sends to each
/// whitelisted owner when the process comes up: a one-line "I'm alive on this
/// host" ping identifying the [host] the brain is running on.
///
/// A pure function so the wording is one named place (and unit-testable without
/// a `ChatApi`); [TelegramAccessEdge.announceStartup] is what actually sends it.
/// It ends with a hint at `/help` so a user discovers the command vocabulary
/// the moment the link comes up (part a).
String telegramStartupAnnouncement(String host) =>
    'Telegram link to tom_brain from host $host just started. '
    'Send /help to list the available commands.';

/// How many of the most recently recorded prompts `/observatory_show_prompts`
/// lists (part b). Newest-first; the user analyses one by its listed index.
const int telegramShowPromptsLimit = 20;

/// How many trailing lines of each log file `/show_logs` shows (part d).
const int telegramShowLogsLineCount = 50;

/// The reply when an inspection command (`/observatory_*`, `/show_logs`,
/// `/memory_status`) has no inspector wired on this deployment — the access
/// process was stood up without the corresponding [TelegramInspectors] member
/// (e.g. no trail configured, or a bare standalone serve). A plain, honest
/// "this deployment can't answer that" rather than a failure.
const String telegramInspectorUnavailableMessage =
    'That inspection is not available on this deployment.';

/// The reply to `/todos_list` / `/todos_clear` while the user is in the `global`
/// session. The global session mints a fresh id every turn (it has no stable
/// session id to key a working list on), so it keeps no persistent todo list —
/// the user must be in a named session for the list to survive across prompts.
const String telegramTodosGlobalSessionMessage =
    'The global session keeps no persistent working todo list. '
    'Switch to a named session with /create_session to use one.';

/// The number of leading prompt characters echoed back in the immediate
/// "Processing" acknowledgement ([telegramProcessingAcknowledgement]).
const int telegramProcessingPreviewLength = 200;

/// Builds the immediate acknowledgement the Telegram channel sends the moment a
/// request is admitted, before the (potentially slow) cognition runs: a single
/// line echoing the first [telegramProcessingPreviewLength] characters of the
/// [prompt] so the sender sees their message was received while the answer is
/// still being produced.
///
/// A pure function so the wording is one named, unit-testable place (mirroring
/// [telegramStartupAnnouncement]); [TelegramAccessEdge] is what actually sends
/// it. A prompt at or under the preview length is echoed whole; a longer one is
/// truncated to its first [telegramProcessingPreviewLength] characters (no
/// ellipsis — the preview is a debugging echo, not a rendered excerpt).
String telegramProcessingAcknowledgement(String prompt) {
  final String preview = prompt.length <= telegramProcessingPreviewLength
      ? prompt
      : prompt.substring(0, telegramProcessingPreviewLength);
  return 'Processing: $preview';
}

/// The live Telegram channel of the running access process (E.45).
///
/// Construct one per running process over the booted [AccessAssembler] and the
/// same [ChatApi] the [authorizedInboundRequests] stream is gated by; call
/// [start] to begin admitting requests and [stop] to detach. Each admitted
/// request runs the full E.41 admission pipeline; a gate failure draws a
/// graceful plain-text decline to the same sender.
class TelegramAccessEdge {
  final AccessAssembler _assembler;
  final ChatApi _chatApi;
  final Stream<InboundRequest> _authorizedInbound;
  final TelegramSessionRegistry _sessionRegistry;
  final TelegramInspectors _inspectors;
  final TelegramChatProfileConfig Function(String chatId) _resolveChat;

  StreamSubscription<InboundRequest>? _subscription;

  /// Builds the edge over the booted [assembler], the [chatApi] used to send
  /// the graceful decline and back the per-request sink, the adapter's
  /// whitelist-gated [authorizedInbound] stream (E.22), and the
  /// [sessionRegistry] that maps each Telegram user to its active session and
  /// handles the four session commands (§ 6.5).
  ///
  /// [inspectors] supplies the read-only inspection commands (`/observatory_*`,
  /// `/show_logs`, `/memory_status`); the default ([TelegramInspectors.none])
  /// wires none, so those commands reply "not available on this deployment". A
  /// higher assembly (`tom_brain_run`) injects a bundle built over the live
  /// trail + memory.
  ///
  /// [resolveChat] maps a Telegram chat id to its [TelegramChatProfileConfig]
  /// — the namespace (`sessionPrefix` / `memoryPrefix`) the chat's session and
  /// memory commands are scoped within (§ 9.1, MSP-6). Boot wires it from
  /// `AccessConfig.telegramChatFor`; the default treats every chat as
  /// [TelegramChatProfileConfig.unconfigured] (the all-default `defaultmemory_`
  /// / `defaultsession_` namespace), so a deployment with no `chats[]` block
  /// behaves exactly as before this scoping existed.
  TelegramAccessEdge({
    required AccessAssembler assembler,
    required ChatApi chatApi,
    required Stream<InboundRequest> authorizedInbound,
    required TelegramSessionRegistry sessionRegistry,
    TelegramInspectors inspectors = TelegramInspectors.none,
    TelegramChatProfileConfig Function(String chatId)? resolveChat,
  })  : _assembler = assembler,
        _chatApi = chatApi,
        _authorizedInbound = authorizedInbound,
        _sessionRegistry = sessionRegistry,
        _inspectors = inspectors,
        _resolveChat = resolveChat ??
            ((chatId) => TelegramChatProfileConfig.unconfigured(chatId));

  /// Whether [start] has run and [stop] has not yet been called.
  bool get isRunning => _subscription != null;

  /// Begins admitting requests: subscribes to [authorizedInbound] and drives
  /// [AccessAssembler.admitTelegram] for each one.
  ///
  /// Idempotent — a second call while already running is a no-op. Each request
  /// is admitted in turn; a failure on one does not stop the subscription (the
  /// next inbound request is still admitted).
  void start() {
    if (_subscription != null) return;
    _subscription = _authorizedInbound.listen(_admit);
  }

  /// Sends a best-effort "process just started" announcement to each
  /// whitelisted owner in [recipientUserIds], identifying the [host] the brain
  /// is running on (the message is [telegramStartupAnnouncement]).
  ///
  /// Best-effort: a send that throws for one recipient is swallowed (the same
  /// posture as the graceful decline) so a notification failure never blocks
  /// the channel coming up, and never stops the announcement reaching the other
  /// owners. Each owner is sent the message in turn.
  Future<void> announceStartup({
    required Iterable<String> recipientUserIds,
    required String host,
  }) async {
    final String message = telegramStartupAnnouncement(host);
    for (final String userId in recipientUserIds) {
      try {
        await _chatApi.sendMessage(ChatReceiver.id(userId), message);
      } catch (_) {
        // Best-effort: a failure to announce to one owner must not stop the
        // channel coming up, nor the announcement reaching the others.
      }
    }
  }

  /// Stops admitting requests: cancels the subscription.
  ///
  /// Idempotent — a call while not running is a no-op. In-flight admissions
  /// already handed to the assembler are not interrupted.
  Future<void> stop() async {
    final StreamSubscription<InboundRequest>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  /// Admits one inbound [request]: recovers the sender, intercepts any session
  /// command, stamps the active session id, builds the bound sink, and drives
  /// the assembler — declining gracefully on a gate failure.
  Future<void> _admit(InboundRequest request) async {
    final String? userId =
        request.metadata[telegramSenderIdMetadataKey]?.toString();
    if (userId == null) {
      // The authorized stream always carries the sender id (the whitelist gate
      // read the same id); a request without one cannot be addressed.
      return;
    }

    final ChatReceiver receiver = ChatReceiver.id(userId);

    // Resolve the chat's profile namespace (§ 9.1, MSP-6): a configured chat
    // declares its `sessionPrefix` / `memoryPrefix`; an unconfigured one falls
    // back to the all-default namespace. The chat is keyed by the inbound
    // `conversationId` (the Telegram chat id the mapping carried, E.20); an
    // envelope without one (a private chat where the id was not stamped) keys on
    // the sender id instead — a private chat's id equals its user's. It scopes
    // both the memory commands and the active-memory stamp below.
    final String chatId = request.conversationId ?? userId;
    final TelegramChatProfileConfig chat = _resolveChat(chatId);

    // A slash-command is handled here — session continuity, `/help`, the memory
    // commands, and the inspection commands all stay in the access layer and
    // never reach the brain (§ 6.5 / § 9.2). An ordinary prompt falls through.
    final TelegramCommand? command = parseTelegramCommand(request.text);
    if (command != null) {
      await _handleCommand(receiver, userId, command, chat);
      return;
    }

    // Resolve the chat's active processing profile (§ 6). Telegram owns profile
    // selection on the user's behalf (no credential marker carries it): the
    // registry resolves the active *name* (`/switch_profile` selection over the
    // chat's `defaultProfile`), and the assembler's `resolveProfile` seam maps it
    // to the `ResolvedProfile` carrying the mode / role / anchor / budget knobs.
    // Its advisory `defaultSession` / `defaultMemory` seed the session / memory
    // resolution below (SC-Q14), and the profile itself is stamped onto `Access`.
    final String profileName = _sessionRegistry.resolveActiveProfile(
      userId,
      chatDefaultProfile: chat.defaultProfile,
    );
    final ResolvedProfile profile = _assembler.resolveProfile(profileName);

    // Ordinary prompt: resolve the user's active session and stamp its effective
    // id onto the envelope (null id ⇒ the global session). The effective id is
    // derived from the chat's `sessionPrefix` and was already adopted into the
    // SessionManager by the registry, so the dispatcher resolves it as a known
    // dedicated session (MSPP-37). The profile's `defaultSession` seeds an unset
    // active session (an explicit `/create_session` always wins, SC-Q14).
    final TelegramActiveSession active = _sessionRegistry.resolveActive(
      userId,
      sessionPrefix: chat.sessionPrefix,
      profileDefaultSession: profile.defaultSession,
    );
    // When this user has memory-recall tracing on (`/trace_memory`), stamp the
    // per-turn trace flag onto the envelope metadata so the dispatch route binds
    // the memory-notice sink for this turn (§ 6.5). Merge rather than replace —
    // `copyWith` swaps the whole metadata map, so the channel-supplied keys
    // (the sender id) must be carried forward.
    final InboundRequest stamped = _sessionRegistry.isTraceMemoryEnabled(userId)
        ? request.copyWith(
            sessionId: active.sessionId,
            metadata: <String, Object?>{
              ...request.metadata,
              traceMemoryMetadataKey: true,
            },
          )
        : request.copyWith(sessionId: active.sessionId);

    // Stamp the chat's active memory profile (§ 9.2). The registry holds the
    // bare active name; applying the chat's `memoryPrefix` yields the profile id
    // the engine routes to. Telegram owns this selection on the user's behalf,
    // so it is authoritative over content-driven selection (MSP-5 / MSPP-35).
    final String memoryProfile = _sessionRegistry.resolveActiveMemory(
      userId,
      memoryPrefix: chat.memoryPrefix,
      profileDefaultMemory: profile.defaultMemory,
    );

    try {
      await _assembler.admitTelegram(
        userId: userId,
        envelope: stamped,
        sink: ChatApiTelegramSink(chatApi: _chatApi, receiver: receiver),
        memoryProfile: memoryProfile,
        profile: profile,
        onAdmitted: () => _acknowledge(receiver, stamped.text),
      );
    } catch (error) {
      await _decline(receiver, error);
    }
  }

  /// Runs a parsed [command] for [userId] and sends the reply to [receiver].
  /// The brain is never involved — every slash-command is an access-layer
  /// concern (§ 6.5).
  ///
  /// The session and `/help` commands answer from a single string; the memory
  /// commands resolve within [chat]'s `memoryPrefix` scope (§ 9.2, MSP-6); the
  /// inspection commands fan their (potentially large) output out across as
  /// many size-compliant Telegram messages as it takes (parts b–e).
  Future<void> _handleCommand(
    ChatReceiver receiver,
    String userId,
    TelegramCommand command,
    TelegramChatProfileConfig chat,
  ) async {
    switch (command.kind) {
      case TelegramCommandKind.createSession:
        await _send(receiver, _sessionRegistry.createSession(
          userId,
          command.argument,
          sessionPrefix: chat.sessionPrefix,
        ));
      case TelegramCommandKind.listSessions:
        await _send(receiver, _sessionRegistry.listSessions(
          userId,
          sessionPrefix: chat.sessionPrefix,
        ));
      case TelegramCommandKind.pickSession:
        await _send(receiver, _sessionRegistry.pickSession(
          userId,
          command.argument,
          sessionPrefix: chat.sessionPrefix,
        ));
      case TelegramCommandKind.renameSession:
        await _send(receiver, _sessionRegistry.renameSession(
          userId,
          command.argument,
          sessionPrefix: chat.sessionPrefix,
        ));
      case TelegramCommandKind.createMemory:
        await _send(receiver, _sessionRegistry.createMemory(
          userId,
          command.argument,
          memoryPrefix: chat.memoryPrefix,
        ));
      case TelegramCommandKind.listMemory:
        await _send(receiver, _sessionRegistry.listMemory(
          userId,
          memoryPrefix: chat.memoryPrefix,
        ));
      case TelegramCommandKind.switchMemory:
        await _send(receiver, _sessionRegistry.switchMemory(
          userId,
          command.argument,
          memoryPrefix: chat.memoryPrefix,
        ));
      case TelegramCommandKind.listProfiles:
        await _send(receiver, _sessionRegistry.listProfiles(
          userId,
          chatDefaultProfile: chat.defaultProfile,
        ));
      case TelegramCommandKind.switchProfile:
        await _send(receiver, _sessionRegistry.switchProfile(
          userId,
          command.argument,
          chatDefaultProfile: chat.defaultProfile,
        ));
      case TelegramCommandKind.help:
        await _send(receiver, telegramHelpText());
      case TelegramCommandKind.observatoryShowPrompts:
        await _handleShowPrompts(receiver);
      case TelegramCommandKind.observatoryAnalyzePrompt:
        await _handleAnalyzePrompt(receiver, command.argument);
      case TelegramCommandKind.showLogs:
        await _handleShowLogs(receiver);
      case TelegramCommandKind.memoryStatus:
        await _handleMemoryStatus(receiver);
      case TelegramCommandKind.checkStatus:
        await _handleCheckStatus(receiver);
      case TelegramCommandKind.todosList:
        await _handleTodosList(receiver, userId, chat.sessionPrefix);
      case TelegramCommandKind.todosClear:
        await _handleTodosClear(receiver, userId, chat.sessionPrefix);
      case TelegramCommandKind.checkUsage:
        await _handleCheckUsage(receiver);
      case TelegramCommandKind.stopPrompt:
        await _handleStopPrompt(receiver);
      case TelegramCommandKind.toolsList:
        await _handleToolsList(receiver);
      case TelegramCommandKind.toolInspect:
        await _handleToolInspect(receiver, command.argument);
      case TelegramCommandKind.mcpList:
        await _handleMcpList(receiver);
      case TelegramCommandKind.mcpInspect:
        await _handleMcpInspect(receiver, command.argument);
      case TelegramCommandKind.showModels:
        await _handleShowModels(receiver);
      case TelegramCommandKind.showPrompts:
        await _handleShowPromptTypes(receiver);
      case TelegramCommandKind.switchModel:
        await _handleSwitchModel(receiver, command.argument);
      case TelegramCommandKind.cliServerPort:
        await _handleCliServerPort(receiver, command.argument);
      case TelegramCommandKind.createApiKey:
        await _handleCreateApiKey(receiver, command.argument);
      case TelegramCommandKind.traceMemory:
        await _send(receiver, _sessionRegistry.toggleTraceMemory(userId));
    }
  }

  /// Handles `/observatory_show_prompts`: lists the most recent recorded
  /// prompts, each with its index, timestamp, and a [telegramProcessingPreviewLength]
  /// -character preview (part b). Replies the unavailable message when no prompt
  /// inspector is wired, and an empty-list notice when nothing has been
  /// recorded.
  Future<void> _handleShowPrompts(ChatReceiver receiver) async {
    final TelegramPromptInspector? inspector = _inspectors.prompts;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final List<TelegramPromptDigest> digests = await inspector.recentPrompts(
      limit: telegramShowPromptsLimit,
      previewLength: telegramProcessingPreviewLength,
    );
    if (digests.isEmpty) {
      await _send(receiver, 'No prompts have been recorded yet.');
      return;
    }
    final StringBuffer buffer = StringBuffer('Recent prompts:');
    for (final TelegramPromptDigest digest in digests) {
      buffer
        ..write('\n\n[${digest.index}] ${digest.receivedAt.toIso8601String()}')
        ..write('\n${digest.preview}');
    }
    await _sendSplit(receiver, buffer.toString());
  }

  /// Handles `/observatory_analyze_prompt <index>`: shows the full detail of
  /// the prompt at the listed index, split across as many messages as Telegram
  /// needs (part c). Replies a usage line for a missing/non-numeric argument,
  /// the unavailable message when no inspector is wired, and a not-found notice
  /// when no prompt holds that index.
  Future<void> _handleAnalyzePrompt(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramPromptInspector? inspector = _inspectors.prompts;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final int? index = int.tryParse(argument.trim());
    if (index == null) {
      await _send(
        receiver,
        'Usage: /observatory_analyze_prompt <index> '
        '(from /observatory_show_prompts).',
      );
      return;
    }
    final String? detail = await inspector.promptDetail(index);
    if (detail == null) {
      await _send(
        receiver,
        'No prompt numbered $index. Use /observatory_show_prompts to list them.',
      );
      return;
    }
    await _sendSplit(receiver, detail);
  }

  /// Handles `/show_logs`: sends the last [telegramShowLogsLineCount] lines of
  /// each important log file, one message per file (a file whose tail overflows
  /// a single Telegram message is itself split) (part d). Replies the
  /// unavailable message when no log inspector is wired, and an empty notice
  /// when there are no logs.
  Future<void> _handleShowLogs(ChatReceiver receiver) async {
    final TelegramLogInspector? inspector = _inspectors.logs;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final List<TelegramLogTail> tails =
        await inspector.tailLogs(lines: telegramShowLogsLineCount);
    if (tails.isEmpty) {
      await _send(receiver, 'No log files to show.');
      return;
    }
    for (final TelegramLogTail tail in tails) {
      await _sendSplit(receiver, '=== ${tail.name} ===\n${tail.content}');
    }
  }

  /// Handles `/memory_status`: sends the memory overview, split across messages
  /// if it overflows (part e). Replies the unavailable message when no memory
  /// inspector is wired.
  Future<void> _handleMemoryStatus(ChatReceiver receiver) async {
    final TelegramMemoryInspector? inspector = _inspectors.memory;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.status());
  }

  /// Handles `/check_status`: sends the comprehensive operational status (what
  /// is being processed now, plus the recent runs' outcomes and any errors),
  /// split across messages if it overflows. Replies the unavailable message
  /// when no status inspector is wired.
  Future<void> _handleCheckStatus(ChatReceiver receiver) async {
    final TelegramStatusInspector? inspector = _inspectors.status;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.report());
  }

  /// Handles `/todos_list`: sends the working todo list of the user's active
  /// session, split across messages if it overflows. Replies the unavailable
  /// message when no todos inspector is wired, and the global-session notice
  /// when the active session is `global` (which keeps no persistent list).
  Future<void> _handleTodosList(
    ChatReceiver receiver,
    String userId,
    String sessionPrefix,
  ) async {
    final TelegramTodosInspector? inspector = _inspectors.todos;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final String? sessionId = _sessionRegistry
        .resolveActive(userId, sessionPrefix: sessionPrefix)
        .sessionId;
    if (sessionId == null) {
      await _send(receiver, telegramTodosGlobalSessionMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.list(sessionId));
  }

  /// Handles `/todos_clear`: empties the working todo list of the user's active
  /// session and reports the outcome. Replies the unavailable message when no
  /// todos inspector is wired, and the global-session notice when the active
  /// session is `global` (which keeps no persistent list to clear).
  Future<void> _handleTodosClear(
    ChatReceiver receiver,
    String userId,
    String sessionPrefix,
  ) async {
    final TelegramTodosInspector? inspector = _inspectors.todos;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final String? sessionId = _sessionRegistry
        .resolveActive(userId, sessionPrefix: sessionPrefix)
        .sessionId;
    if (sessionId == null) {
      await _send(receiver, telegramTodosGlobalSessionMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.clear(sessionId));
  }

  /// Handles `/check_usage`: sends the live budget of the prompt being processed
  /// right now — elapsed time and accumulated effort — split across messages if
  /// it overflows. Process-global (the single foreground prompt), so unlike the
  /// todo commands there is no session to resolve. Replies the unavailable
  /// message when no usage inspector is wired.
  Future<void> _handleCheckUsage(ChatReceiver receiver) async {
    final TelegramUsageInspector? inspector = _inspectors.usage;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.currentUsage());
  }

  /// Handles `/stop_prompt`: cooperatively interrupts the prompt being processed
  /// right now and reports the outcome (a "stopped" confirmation, or a "nothing
  /// is being processed" notice when the brain is idle). Process-global (the
  /// single foreground prompt), so like `/check_usage` there is no session to
  /// resolve. Replies the unavailable message when no stop controller is wired.
  Future<void> _handleStopPrompt(ChatReceiver receiver) async {
    final TelegramStopController? controller = _inspectors.stop;
    if (controller == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await controller.stopCurrentPrompt());
  }

  /// Handles `/tools_list`: sends the rendered engine-tool catalogue, split
  /// across messages if it overflows. Replies the unavailable message when no
  /// tools inspector is wired.
  Future<void> _handleToolsList(ChatReceiver receiver) async {
    final TelegramToolsInspector? inspector = _inspectors.tools;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.toolsList());
  }

  /// Handles `/tool_inspect <name>`: sends one tool's full detail (the inspector
  /// renders the "no such tool" notice for an unknown name). Replies a usage
  /// line for a missing argument and the unavailable message when no tools
  /// inspector is wired.
  Future<void> _handleToolInspect(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramToolsInspector? inspector = _inspectors.tools;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final String name = argument.trim();
    if (name.isEmpty) {
      await _send(receiver, 'Usage: /tool_inspect <name> (from /tools_list).');
      return;
    }
    await _sendSplit(receiver, await inspector.toolDetail(name));
  }

  /// Handles `/mcp_list`: sends the rendered list of configured MCP servers (the
  /// inspector renders the empty notice when none is configured). Replies the
  /// unavailable message when no MCP inspector is wired.
  Future<void> _handleMcpList(ChatReceiver receiver) async {
    final TelegramMcpInspector? inspector = _inspectors.mcp;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.mcpList());
  }

  /// Handles `/mcp_inspect <server> [tool]`: lists an MCP server's tools, or one
  /// tool's detail when a second argument is given (the inspector renders the
  /// unknown-server / unreachable notices). Replies a usage line for a missing
  /// server and the unavailable message when no MCP inspector is wired.
  Future<void> _handleMcpInspect(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramMcpInspector? inspector = _inspectors.mcp;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final List<String> parts = argument.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) {
      await _send(
        receiver,
        'Usage: /mcp_inspect <server> [tool] (from /mcp_list).',
      );
      return;
    }
    final String server = parts.first;
    final String? tool = parts.length > 1 ? parts[1] : null;
    await _sendSplit(receiver, await inspector.mcpDetail(server, tool: tool));
  }

  /// Handles `/show_models`: sends the rendered list of configured providers and
  /// models. Replies the unavailable message when no models inspector is wired.
  Future<void> _handleShowModels(ChatReceiver receiver) async {
    final TelegramModelsInspector? inspector = _inspectors.models;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.models());
  }

  /// Handles `/show_prompts`: sends the rendered list of cognition prompt types.
  /// Replies the unavailable message when no prompts inspector is wired.
  Future<void> _handleShowPromptTypes(ChatReceiver receiver) async {
    final TelegramPromptsInspector? inspector = _inspectors.promptTypes;
    if (inspector == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    await _sendSplit(receiver, await inspector.prompts());
  }

  /// Handles `/switch_model <prompt-id> <model-id>`: overrides the model a
  /// cognition prompt type uses for this process (the switcher renders the
  /// validation notices for an unknown prompt-id / model-id). Replies a usage
  /// line for a missing argument and the unavailable message when no model
  /// switcher is wired.
  Future<void> _handleSwitchModel(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramModelSwitcher? switcher = _inspectors.modelSwitcher;
    if (switcher == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final List<String> parts = argument.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.length != 2) {
      await _send(
        receiver,
        'Usage: /switch_model <prompt-id> <model-id> '
        '(ids from /show_prompts and /show_models).',
      );
      return;
    }
    await _sendSplit(
      receiver,
      await switcher.switchModel(promptId: parts[0], modelId: parts[1]),
    );
  }

  /// Handles `/cli_server_port <port>`: changes the VS Code bridge / agent-SDK
  /// CLI-server port the running brain uses — the controller persists it to the
  /// run config and reconnects the live agent-SDK providers, rendering the
  /// outcome (including the out-of-range notice). Replies a usage line for a
  /// non-numeric argument and the unavailable message when no controller is
  /// wired.
  Future<void> _handleCliServerPort(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramCliServerPortController? controller = _inspectors.cliServerPort;
    if (controller == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final int? port = int.tryParse(argument.trim());
    if (port == null) {
      await _send(
        receiver,
        'Usage: /cli_server_port <port> (a TCP port number, e.g. 19900).',
      );
      return;
    }
    await _sendSplit(receiver, await controller.setCliServerPort(port: port));
  }

  /// Handles `/create_api_key` and `/create_api_key <sessionPrefix> <memoryPrefix>`:
  /// mints a new API key, admits it live, and persists it (MSP-7), rendering the
  /// outcome (including the rollback notice on a persist failure). The
  /// both-or-neither rule (MSPP-45) is enforced here: zero arguments mint a key
  /// whose value is both prefixes; exactly two set the prefixes verbatim; one
  /// argument is a usage error and the creator is *not* called. Replies the
  /// unavailable message when no creator is wired.
  Future<void> _handleCreateApiKey(
    ChatReceiver receiver,
    String argument,
  ) async {
    final TelegramApiKeyCreator? creator = _inspectors.apiKeyCreator;
    if (creator == null) {
      await _send(receiver, telegramInspectorUnavailableMessage);
      return;
    }
    final List<String> parts = argument.trim().split(RegExp(r'\s+'))
      ..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) {
      await _sendSplit(receiver, await creator.createApiKey());
      return;
    }
    if (parts.length == 2) {
      await _sendSplit(
        receiver,
        await creator.createApiKey(
          sessionPrefix: parts[0],
          memoryPrefix: parts[1],
        ),
      );
      return;
    }
    await _send(
      receiver,
      'Usage: /create_api_key (the key value becomes both prefixes) or '
      '/create_api_key <sessionPrefix> <memoryPrefix> (both together).',
    );
  }

  /// Sends [text] as the minimum number of size-compliant Telegram messages,
  /// in order (the [TelegramOutboundConsolidator] split the answer path uses).
  /// Each part is best-effort — a failure on one is swallowed and the next is
  /// still attempted.
  Future<void> _sendSplit(ChatReceiver receiver, String text) async {
    for (final String part in const TelegramOutboundConsolidator().split(text)) {
      await _send(receiver, part);
    }
  }

  /// Sends a best-effort plain-text [message] to [receiver] (a session-command
  /// acknowledgement or an invalid-session notice). A send failure is swallowed
  /// — the same posture as the acknowledgement and the graceful decline.
  Future<void> _send(ChatReceiver receiver, String message) async {
    try {
      await _chatApi.sendMessage(receiver, message);
    } catch (_) {
      // Best-effort: nothing more to do if the reply fails to send.
    }
  }

  /// Sends the immediate "Processing" acknowledgement to [receiver]
  /// (best-effort — a failure to send it is swallowed).
  ///
  /// Fired by the assembler once a request has passed every edge gate and is
  /// about to be dispatched (its `onAdmitted` hook), so the sender sees their
  /// message echoed back while the cognition runs. A gate-rejected request
  /// never reaches this point — it draws its graceful decline instead, not a
  /// contradictory "Processing" line. Buffered Telegram delivery only flushes
  /// the answer on the run's final chunk, so without this a slow — or failing —
  /// run would leave the sender staring at silence.
  Future<void> _acknowledge(ChatReceiver receiver, String prompt) async {
    try {
      await _chatApi.sendMessage(
        receiver,
        telegramProcessingAcknowledgement(prompt),
      );
    } catch (_) {
      // Best-effort: the ack is a courtesy, never a precondition for the run.
    }
  }

  /// Sends the graceful plain-text decline for [error] to [receiver]
  /// (best-effort — a failure to send the decline is swallowed).
  Future<void> _decline(ChatReceiver receiver, Object error) async {
    try {
      await _chatApi.sendMessage(receiver, _gracefulMessageFor(error));
    } catch (_) {
      // Nothing more to do: the principal is already being declined, and the
      // decline itself failed to send. Drop it and move on.
    }
  }

  /// Maps a thrown edge / dispatch failure to its graceful Telegram message
  /// (proto spec § 8 / § 13.2): rate-limit / quota / anchor each get their
  /// dedicated decline; an unresolved identity and anything else fall back to
  /// the not-authorised message (the channel's catch-all decline).
  static String _gracefulMessageFor(Object error) {
    if (error is RateLimitExceeded) {
      return telegramRateLimitMessage;
    }
    if (error is DailyQuotaExceeded) {
      return telegramQuotaMessage;
    }
    if (error is AnchorPreCheckRejected) {
      return telegramAnchorMessage;
    }
    // An unresolved identity (IdentityResolutionException), a dispatch
    // failure, or anything unforeseen: the principal does not get a usable
    // answer, so decline politely with the channel's catch-all message.
    return telegramNotAuthorisedMessage;
  }
}
