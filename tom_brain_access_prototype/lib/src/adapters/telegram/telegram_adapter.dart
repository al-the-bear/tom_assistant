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
// Scope discipline (Q-E.11.2 carried forward — same per-substep posture as
// the OpenAI adapter's E.11 router scaffold). Through E.21 the adapter is
// the lifecycle + inbound relay + inbound mapping + outbound consolidation,
// nothing downstream:
//
//   * NO whitelist auth. Rejecting a non-whitelisted sender at the edge
//     is E.22.
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
/// Through E.21 the adapter handles inbound (raw relay + mapped
/// [inboundRequests]) and outbound ([sendAnswer] — consolidate a streamed
/// answer into one, or on overflow the minimum number of, Telegram
/// message(s)). The user-id whitelist (E.22) and the `DeliveryRegistry`
/// wiring (E.36+) are later substeps that build on this.
final class TelegramAdapter {
  /// The chat backend this adapter drives. Injected so the adapter is
  /// testable against a loopback double; in production it is the real
  /// Telegram implementation built by [fromConfig].
  final ChatApi _chatApi;

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
  TelegramAdapter({
    required ChatApi chatApi,
    TelegramOutboundConsolidator outboundConsolidator =
        const TelegramOutboundConsolidator(),
  })  : _chatApi = chatApi,
        _outbound = outboundConsolidator;

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
  }) {
    final TelegramChatApiBuilder builder =
        buildChatApi ?? _buildTelegramChatApi;
    return TelegramAdapter(
      chatApi: builder(config),
      outboundConsolidator: outboundConsolidator,
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
