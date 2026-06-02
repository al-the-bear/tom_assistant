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
// Scope discipline (Q-E.11.2 carried forward — same per-substep posture as
// the OpenAI adapter's E.11 router scaffold). E.19 is the adapter
// lifecycle + raw inbound relay, nothing downstream:
//
//   * NO `InboundRequest` mapping. [inboundMessages] re-emits the raw
//     `tom_chattools` `ChatMessage` exactly as it arrives. Turning a
//     `ChatMessage` into a channel-agnostic `InboundRequest`
//     (text / messageId / conversationId / sender) is E.20.
//   * NO outbound consolidation. Streamed-answer → one consolidated
//     Telegram message (the § Q13 Stage-1 rule, with size-limit
//     chunking) is E.21.
//   * NO whitelist auth. Rejecting a non-whitelisted sender at the edge
//     is E.22.
//   * NO `DeliveryRegistry` wiring. The outbound delivery path is E.36 –
//     E.40; boot (E.41+) is what constructs the real `TelegramAdapter`
//     (via [TelegramAdapter.fromConfig]) and joins it to the dispatcher.
//
// The adapter is therefore self-contained and unit-testable against an
// injected `ChatApi` double (the E.5 `LoopbackChatApi`), with no socket,
// no televerse `Bot`, and no real Telegram network — mirroring the way
// the OpenAI adapter is driven through its `handler` with no port bind.

import 'dart:async';

import 'package:tom_chattools/tom_chattools.dart';

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
/// E.19 deliberately stops at the raw relay. The `ChatMessage` →
/// `InboundRequest` mapping (E.20), the outbound consolidation (E.21), and
/// the user-id whitelist (E.22) are later substeps that build on this
/// scaffold.
final class TelegramAdapter {
  /// The chat backend this adapter drives. Injected so the adapter is
  /// testable against a loopback double; in production it is the real
  /// Telegram implementation built by [fromConfig].
  final ChatApi _chatApi;

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
  TelegramAdapter({required ChatApi chatApi}) : _chatApi = chatApi;

  /// Builds an adapter over the Telegram backend described by [config].
  ///
  /// By default this constructs the package's real Telegram implementation
  /// (`config.createApi(...)`, long-polling per [TelegramChatConfig]). A
  /// test supplies [buildChatApi] to inject a loopback double instead,
  /// exercising the factory wiring without the Telegram network.
  factory TelegramAdapter.fromConfig(
    TelegramChatConfig config, {
    TelegramChatApiBuilder? buildChatApi,
  }) {
    final TelegramChatApiBuilder builder =
        buildChatApi ?? _buildTelegramChatApi;
    return TelegramAdapter(chatApi: builder(config));
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
  /// the E.20 mapper consumes it to produce `InboundRequest`. Broadcast:
  /// safe to attach a listener before [start].
  Stream<ChatMessage> get inboundMessages => _inbound.stream;

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
