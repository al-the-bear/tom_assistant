// Telegram inbound/outbound adapter — the scaffold (E.19).
//
// What this file owns (Plan § Phase E, substep E.19; proto spec § 6.1):
//
//   * `TelegramAdapter` — the prototype's Telegram channel, built on
//     `tom_chattools`' `ChatApi` + `TelegramChatConfig`, running in
//     **long-polling** mode (no webhook). E.19 is the *scaffold*: the
//     lifecycle (`start` / `stop`) that subscribes to the chat backend's
//     real-time `onMessage` stream, plus the raw inbound relay
//     ([inboundMessages]) the later substeps map.
//   * `TelegramChatApiBuilder` — the seam that builds the concrete
//     `ChatApi` from a `TelegramChatConfig`. Defaults to the package's
//     real Telegram implementation; tests inject a loopback double.
//
// E.20 adds the inbound mapping: [inboundRequests] is [inboundMessages]
// projected through `ChatMessage.toInboundRequest()`
// (telegram_inbound_mapping.dart), emitting one `InboundRequest` per text
// message and dropping non-text Stage-1 messages (def § Q13). The raw
// [inboundMessages] relay stays exposed for observability.
//
// E.21 adds the outbound mapping: [sendAnswer] consolidates an answer's
// `Stream<OutboundChunk>` (via `TelegramOutboundConsolidator`,
// telegram_outbound_mapping.dart) into **one consolidated message** — or, on
// overflow, the minimum number of size-compliant messages (def § Q13
// Stage-1: no edits, typing indicators, or inline buttons; Q-E.2.6 split) —
// and sends them to the receiver through the backend's `sendMessage`.
//
// E.22 adds the edge auth gate: [authorizedInboundRequests] is
// [inboundRequests] filtered through the injected `TelegramWhitelist`
// (telegram_whitelist.dart). A whitelisted sender's text message surfaces as
// an `InboundRequest`; a non-whitelisted sender is rejected **at the edge** —
// `telegramNotAuthorisedMessage` is sent back and the request is dropped, so
// no `InboundRequest` surfaces and no `Access` is ever built for it (AC-3,
// AC-4; proto spec § 6.4 / § 8). [inboundRequests] stays exposed as the
// ungated mapped view (observability); boot (E.41) consumes the gated
// [authorizedInboundRequests].
//
// Scope discipline (Q-E.11.2 carried forward — same per-substep posture as
// the OpenAI adapter's E.11 router scaffold). Through E.22 the adapter is
// the lifecycle + inbound relay + inbound mapping + outbound consolidation +
// the whitelist gate, nothing downstream:
//
//   * NO rate limiting / quota / anchor pre-check. Those are the remaining
//     edge-security checks (E.29 – E.31), owned by `edge_security/`.
//   * NO identity / session / persona resolution (E.24 – E.27): the gate
//     decides *whether* a sender proceeds, not *who* the principal is.
//   * NO `DeliveryRegistry` wiring. Translating per-`Access` chunks to the
//     channel and owning both delivery paths is E.36 – E.38; backpressure /
//     `DeliveryStalled` is E.39 – E.40; boot (E.41+) is what constructs the
//     real `TelegramAdapter` (via [TelegramAdapter.fromConfig]) and joins it
//     to the dispatcher.
//
// The adapter is therefore self-contained and unit-testable against an
// injected `ChatApi` double (the E.5 `LoopbackChatApi`), with no socket,
// no televerse `Bot`, and no real Telegram network — mirroring the way
// the OpenAI adapter is driven through its `handler` with no port bind.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';

import 'telegram_inbound_mapping.dart';
import 'telegram_outbound_mapping.dart';
import 'telegram_whitelist.dart';

/// Builds the concrete [ChatApi] a [TelegramAdapter] drives, from its
/// [TelegramChatConfig].
///
/// The production default ([TelegramAdapter.fromConfig] with no builder)
/// constructs the package's real Telegram implementation via
/// `config.createApi(...)`. A test injects a builder that returns a
/// loopback double so the adapter's lifecycle and inbound relay can be
/// exercised without touching the Telegram network.
typedef TelegramChatApiBuilder = ChatApi Function(TelegramChatConfig config);

/// The prototype Telegram channel adapter.
///
/// Wraps a `tom_chattools` [ChatApi] and runs it in **long-polling** mode:
/// [start] initialises the backend and subscribes to its real-time
/// `onMessage` stream, re-emitting each inbound `ChatMessage` on
/// [inboundMessages]; [stop] cancels that subscription, disconnects the
/// backend, and closes the relay.
///
/// Through E.22 the adapter handles inbound (raw relay + mapped
/// [inboundRequests] + whitelist-gated [authorizedInboundRequests]) and
/// outbound ([sendAnswer] — consolidate a streamed answer into one, or on
/// overflow the minimum number of, Telegram message(s)). The
/// `DeliveryRegistry` wiring (E.36+) is a later substep that builds on this.
final class TelegramAdapter {
  /// The chat backend this adapter drives. Injected so the adapter is
  /// testable against a loopback double; in production it is the real
  /// Telegram implementation built by [fromConfig].
  final ChatApi _chatApi;

  /// The edge auth gate (E.22): the configured set of allowed Telegram
  /// user ids. [authorizedInboundRequests] consults it before a request can
  /// become an `Access`; a non-whitelisted sender is rejected at the edge.
  /// Injected so a test can supply a known set; defaults to the closed
  /// `TelegramWhitelist.empty()` (allows no one — Q-E.22.1), which boot
  /// replaces with the configured set.
  final TelegramWhitelist _whitelist;

  /// Buffers an answer's `OutboundChunk` stream and splits it into the
  /// size-compliant Telegram message(s) [sendAnswer] sends (E.21). Injected
  /// so a test can lower the per-message budget; defaults to Telegram's real
  /// 4096-code-unit limit.
  final TelegramOutboundConsolidator _outbound;

  /// The broadcast relay carrying inbound `ChatMessage`s to consumers.
  ///
  /// Created eagerly (not in [start]) so a consumer — the E.20 mapper, or
  /// a test — can attach a listener *before* polling begins and therefore
  /// not miss the first message. A broadcast controller fits the
  /// real-time, possibly-multi-listener nature of an inbound bot stream.
  final StreamController<ChatMessage> _inbound =
      StreamController<ChatMessage>.broadcast();

  /// The live subscription to the backend's `onMessage` stream while the
  /// adapter is running; `null` before [start] / after [stop].
  StreamSubscription<ChatMessage>? _subscription;

  bool _running = false;

  /// Wraps an already-built [chatApi]. Boot and tests use this directly;
  /// the production path normally goes through [fromConfig].
  ///
  /// [outboundConsolidator] controls how a streamed answer is split into
  /// Telegram message(s) (E.21); it defaults to the real 4096-code-unit
  /// limit and is injectable so a test can force the overflow split with a
  /// small budget.
  ///
  /// [whitelist] is the edge auth gate (E.22); it defaults to the closed
  /// `TelegramWhitelist.empty()` (allows no one — Q-E.22.1) and is injectable
  /// so a test (and boot) can supply the configured set of allowed user ids.
  TelegramAdapter({
    required ChatApi chatApi,
    TelegramOutboundConsolidator outboundConsolidator =
        const TelegramOutboundConsolidator(),
    TelegramWhitelist whitelist = const TelegramWhitelist.empty(),
  })  : _chatApi = chatApi,
        _outbound = outboundConsolidator,
        _whitelist = whitelist;

  /// Builds an adapter over the Telegram backend described by [config].
  ///
  /// By default this constructs the package's real Telegram implementation
  /// (`config.createApi(...)`, long-polling per [TelegramChatConfig]). A
  /// test supplies [buildChatApi] to inject a loopback double instead,
  /// exercising the factory wiring without the Telegram network.
  factory TelegramAdapter.fromConfig(
    TelegramChatConfig config, {
    TelegramChatApiBuilder? buildChatApi,
    TelegramOutboundConsolidator outboundConsolidator =
        const TelegramOutboundConsolidator(),
    TelegramWhitelist whitelist = const TelegramWhitelist.empty(),
  }) {
    final TelegramChatApiBuilder builder =
        buildChatApi ?? _buildTelegramChatApi;
    return TelegramAdapter(
      chatApi: builder(config),
      outboundConsolidator: outboundConsolidator,
      whitelist: whitelist,
    );
  }

  /// The default [TelegramChatApiBuilder]: the package's real Telegram
  /// `ChatApi`, configured for long-polling from [config] (Q-E.4.3 — the
  /// direct `TelegramChatConfig.createApi` path, with explicit polling
  /// control, over the `ChatApi.connect` settings-detection factory).
  static ChatApi _buildTelegramChatApi(TelegramChatConfig config) {
    final ChatSettings settings = ChatSettings.telegram(
      config.token,
      usePolling: config.usePolling,
      pollingTimeout: Duration(seconds: config.pollingTimeout),
    );
    return config.createApi(settings);
  }

  /// The platform identifier reported by the underlying backend
  /// (`'telegram'` for the real implementation; the loopback reports its
  /// own marker).
  String get platform => _chatApi.platform;

  /// Whether [start] has run and [stop] has not yet been called.
  bool get isRunning => _running;

  /// The raw inbound `ChatMessage` stream (long-polling relay).
  ///
  /// Each message the backend receives while the adapter is running is
  /// re-emitted here, in arrival order. This is the *raw* channel object;
  /// [inboundRequests] is the mapped, dispatcher-facing view. Broadcast:
  /// safe to attach a listener before [start].
  Stream<ChatMessage> get inboundMessages => _inbound.stream;

  /// The mapped inbound `InboundRequest` stream (E.20).
  ///
  /// Each raw [inboundMessages] message is projected through
  /// `ChatMessage.toInboundRequest()`; text messages surface here as one
  /// `InboundRequest` (in arrival order), and non-text Stage-1 messages
  /// (sticker / photo / empty body — def § Q13) are dropped. Per proto
  /// spec § 12 a dropped message is *ignored*; the structured "why" lives in
  /// the `Err(TelegramInboundError)` the mapping returns, which a
  /// logger-aware consumer (boot, E.41) records. Broadcast: safe to attach a
  /// listener before [start].
  Stream<InboundRequest> get inboundRequests => _inbound.stream
      .map((m) => m.toInboundRequest())
      .where((r) => r.isOk)
      .map((r) => (r as Ok<InboundRequest, TelegramInboundError>).value);

  /// The whitelist-gated inbound `InboundRequest` stream (E.22).
  ///
  /// Each raw [inboundMessages] message is checked against the configured
  /// [TelegramWhitelist] **before** it can become an `Access`:
  ///
  ///   * A **whitelisted** sender's text message is mapped (E.20) and
  ///     surfaces here — exactly the requests boot (E.41) turns into
  ///     `Access` objects. A whitelisted sender's non-text Stage-1 message
  ///     is dropped silently (def § Q13), as on [inboundRequests].
  ///   * A **non-whitelisted** sender is rejected at the edge:
  ///     [telegramNotAuthorisedMessage] is sent back through the backend's
  ///     `sendMessage`, and the request is dropped — nothing surfaces here,
  ///     so no `Access` is ever built for it (AC-3, AC-4; proto spec
  ///     § 6.4 / § 8).
  ///
  /// The auth check is the **outermost** gate: it runs before the inbound
  /// text mapping, so even a non-text message from a non-whitelisted sender
  /// draws the graceful decline (you authenticate the sender before you look
  /// at the content). [inboundRequests] stays exposed as the ungated mapped
  /// view for observability; boot consumes this gated stream. Broadcast:
  /// safe to attach a listener before [start].
  Stream<InboundRequest> get authorizedInboundRequests =>
      _inbound.stream.asyncExpand(_gateInbound);

  /// Applies the whitelist gate to one raw inbound [message] (E.22).
  ///
  /// Sends the graceful decline and emits nothing for a non-whitelisted
  /// sender; otherwise maps the message (E.20) and emits the `InboundRequest`
  /// for a whitelisted sender's text message (dropping a non-text one).
  Stream<InboundRequest> _gateInbound(ChatMessage message) async* {
    final String senderId = message.sender.id;
    if (!_whitelist.isAllowed(senderId)) {
      await _chatApi.sendMessage(
        ChatReceiver.id(senderId),
        telegramNotAuthorisedMessage,
      );
      return;
    }
    final Result<InboundRequest, TelegramInboundError> mapped =
        message.toInboundRequest();
    if (mapped.isOk) {
      yield (mapped as Ok<InboundRequest, TelegramInboundError>).value;
    }
  }

  /// Consolidates a streamed [answer] and sends it to [receiver] as the
  /// Stage-1 Telegram outbound message(s) (E.21; proto spec § 6.3).
  ///
  /// Buffers the answer's `OutboundChunk` stream into the full text, then
  /// sends **one consolidated message** when it fits Telegram's per-message
  /// size limit, or the **minimum number of size-compliant messages** when it
  /// does not (the overflow split; def § Q13 "no edits" is preserved — we
  /// never edit, we send N append-only messages, Q-E.2.6). Each message is
  /// plain text: no `parseMode`, no typing indicator, no inline buttons
  /// (Stage-1, def § Q13).
  ///
  /// Returns the sent `ChatMessage`s in order — one per delivered part, the
  /// backend's echo of each `sendMessage`. An empty answer sends nothing and
  /// returns an empty list (Telegram rejects an empty body, Q-E.21.1).
  ///
  /// This is the adapter's outbound *mapping + send*. Wiring it to the
  /// dispatcher's per-`Access` `deliver` callback, and the backpressure /
  /// `DeliveryStalled` signal, are the `DeliveryRegistry` substeps
  /// (E.36 – E.40); this method does the consolidation and the send, nothing
  /// downstream.
  Future<List<ChatMessage>> sendAnswer({
    required ChatReceiver receiver,
    required Stream<OutboundChunk> answer,
  }) async {
    final List<String> parts = await _outbound.consolidate(answer);
    final List<ChatMessage> sent = <ChatMessage>[];
    for (final String part in parts) {
      sent.add(await _chatApi.sendMessage(receiver, part));
    }
    return sent;
  }

  /// Starts long-polling: initialises the backend and subscribes to its
  /// `onMessage` stream, relaying each inbound message to
  /// [inboundMessages].
  ///
  /// Idempotent — a second call while already running is a no-op (the
  /// backend is initialised exactly once).
  Future<void> start() async {
    if (_running) return;
    await _chatApi.initialize();
    _subscription = _chatApi.onMessage.listen(
      _inbound.add,
      onError: _inbound.addError,
    );
    _running = true;
  }

  /// Stops long-polling: cancels the inbound subscription, disconnects the
  /// backend, and closes the relay.
  ///
  /// Idempotent — a call while not running is a no-op. After [stop] the
  /// adapter is terminal; a fresh [TelegramAdapter] is built to run again
  /// (the prototype boots once and shuts down once).
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _subscription?.cancel();
    _subscription = null;
    await _chatApi.disconnect();
    await _inbound.close();
  }
}
