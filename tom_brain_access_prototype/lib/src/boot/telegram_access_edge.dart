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

import 'package:tom_brain_shared/tom_brain_shared.dart' show InboundRequest;
import 'package:tom_chattools/tom_chattools.dart' show ChatApi, ChatReceiver;

import '../adapters/telegram/telegram_inbound_mapping.dart'
    show telegramSenderIdMetadataKey;
import '../adapters/telegram/telegram_whitelist.dart'
    show telegramNotAuthorisedMessage;
import '../delivery/telegram_delivery.dart' show ChatApiTelegramSink;
import '../edge_security/edge_security.dart';
import 'access_assembler.dart';

/// Builds the startup announcement the Telegram channel sends to each
/// whitelisted owner when the process comes up: a one-line "I'm alive on this
/// host" ping identifying the [host] the brain is running on.
///
/// A pure function so the wording is one named place (and unit-testable without
/// a `ChatApi`); [TelegramAccessEdge.announceStartup] is what actually sends it.
String telegramStartupAnnouncement(String host) =>
    'Telegram link to tom_brain from host $host just started.';

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

  StreamSubscription<InboundRequest>? _subscription;

  /// Builds the edge over the booted [assembler], the [chatApi] used to send
  /// the graceful decline and back the per-request sink, and the adapter's
  /// whitelist-gated [authorizedInbound] stream (E.22).
  TelegramAccessEdge({
    required AccessAssembler assembler,
    required ChatApi chatApi,
    required Stream<InboundRequest> authorizedInbound,
  })  : _assembler = assembler,
        _chatApi = chatApi,
        _authorizedInbound = authorizedInbound;

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

  /// Admits one inbound [request]: recovers the sender, builds the bound sink,
  /// and drives the assembler, declining gracefully on a gate failure.
  Future<void> _admit(InboundRequest request) async {
    final String? userId =
        request.metadata[telegramSenderIdMetadataKey]?.toString();
    if (userId == null) {
      // The authorized stream always carries the sender id (the whitelist gate
      // read the same id); a request without one cannot be addressed.
      return;
    }

    final ChatReceiver receiver = ChatReceiver.id(userId);
    try {
      await _assembler.admitTelegram(
        userId: userId,
        envelope: request,
        sink: ChatApiTelegramSink(chatApi: _chatApi, receiver: receiver),
      );
    } catch (error) {
      await _decline(receiver, error);
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
