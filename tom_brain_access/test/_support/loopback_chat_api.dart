// LoopbackChatApi — the in-process Telegram channel test double (E.5
// decision; first authored here at E.19, reused unchanged by the E.23
// roundtrip / conformance suite — its inbound injector + outbound recorder +
// counted lifecycle were already exactly what the end-to-end conformance
// needs).
//
// `tom_chattools` ships only the abstract `ChatApi` plus its single
// televerse-backed Telegram implementation — there is no fake (E.4 /
// E.5 finding, Q-E.5.1). This consumer-authored double therefore
// `implements ChatApi` so the access prototype's tests can drive the
// adapter's lifecycle and inbound relay with no Telegram network, no
// televerse `Bot`, and no socket.
//
// Shape (per the E.5 decision):
//   * Inbound — `onMessage` is backed by a broadcast controller fed by
//     the test through [injectInbound] / [injectText].
//   * Outbound — every `sendMessage` / `send` call is recorded into
//     inspectable lists ([sentMessages] with the matching [sentReceivers])
//     so the E.21 consolidation and Q-E.2.6 chunking can be asserted by
//     counting / concatenating recorded outbound messages.
//   * Lifecycle — `initialize` / `isConnected` / `disconnect` are stubbed
//     and counted ([initializeCount] / [disconnectCount]) so the boot
//     (E.41) and shutdown (E.42) orchestration can be verified to drive
//     the double through the same calls it drives the real adapter
//     through.
//   * Unused surface — `getMessages`, `getReceiverInfo`,
//     `downloadAttachment` throw `UnimplementedError`: the prototype's
//     Telegram path is text-only (Stage-1, def § Q13), so these are
//     outside the loopback's job, and a thrown error documents that
//     intent loudly rather than returning a misleading empty value.

import 'dart:async';

import 'package:tom_chattools/tom_chattools.dart';

/// In-process [ChatApi] test double standing in for the Telegram backend.
final class LoopbackChatApi implements ChatApi {
  /// The settings the adapter would normally pass in; unused by the
  /// loopback but required by the `ChatApi` contract.
  @override
  late ChatSettings settings;

  final StreamController<ChatMessage> _inbound =
      StreamController<ChatMessage>.broadcast();

  bool _connected = false;

  /// How many times [initialize] was called.
  int initializeCount = 0;

  /// How many times [disconnect] was called.
  int disconnectCount = 0;

  /// Every text the adapter sent, in call order (records `sendMessage`'s
  /// `text` and `send`'s `message.text ?? ''`).
  final List<String> sentMessages = <String>[];

  /// The receiver each entry of [sentMessages] was addressed to, in the
  /// same order.
  final List<ChatReceiver> sentReceivers = <ChatReceiver>[];

  /// The `parseMode` each entry of [sentMessages] carried (`null` when
  /// none was supplied), in the same order.
  final List<String?> sentParseModes = <String?>[];

  @override
  bool get isConnected => _connected;

  @override
  String get platform => 'telegram-loopback';

  @override
  Future<void> initialize() async {
    initializeCount++;
    _connected = true;
  }

  @override
  Stream<ChatMessage> get onMessage => _inbound.stream;

  /// Feeds a fully-formed [message] into the inbound stream, as if the
  /// Telegram backend had received it.
  void injectInbound(ChatMessage message) => _inbound.add(message);

  /// Convenience inbound injector: builds a text [ChatMessage] from a
  /// [senderId] / [messageId] / [text] and feeds it in. [chatId] is
  /// carried on `rawData` (`telegram_chat_id`) so the E.20 mapping can
  /// derive `conversationId` from it; it defaults to [senderId] (a
  /// Telegram private chat's id equals the user id).
  void injectText({
    required String senderId,
    required String text,
    String messageId = '1',
    String? chatId,
  }) {
    injectInbound(ChatMessage(
      id: messageId,
      text: text,
      sender: ChatSender(id: senderId),
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      platformMessageId: messageId,
      rawData: {'telegram_chat_id': chatId ?? senderId},
    ));
  }

  @override
  Future<ChatMessage> sendMessage(
    ChatReceiver receiver,
    String text, {
    String? parseMode,
  }) async {
    sentMessages.add(text);
    sentReceivers.add(receiver);
    sentParseModes.add(parseMode);
    return ChatMessage(
      id: 'sent-${sentMessages.length}',
      text: text,
      sender: const ChatSender.self(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  Future<ChatMessage> send(ChatReceiver receiver, ChatMessage message) async {
    sentMessages.add(message.text ?? '');
    sentReceivers.add(receiver);
    sentParseModes.add(null);
    return message;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    _connected = false;
    await _inbound.close();
  }

  @override
  Future<ChatResponse> getMessages(
    ChatReceiver receiver, {
    Duration maxWait = const Duration(seconds: 30),
    Duration minWait = Duration.zero,
    Duration interval = const Duration(seconds: 2),
    ChatMessageFilter? filter,
  }) =>
      throw UnimplementedError(
        'LoopbackChatApi is inbound via onMessage only (E.5 / Q-E.4.4); '
        'getMessages is not part of the prototype Telegram path.',
      );

  @override
  Future<ChatReceiverInfo?> getReceiverInfo(ChatReceiver receiver) =>
      throw UnimplementedError(
        'LoopbackChatApi does not model receiver profiles '
        '(text-only Stage-1, def § Q13).',
      );

  @override
  Future<List<int>?> downloadAttachment(ChatAttachment attachment) =>
      throw UnimplementedError(
        'LoopbackChatApi is text-only; attachments are out of scope '
        '(Stage-1, def § Q13).',
      );
}
