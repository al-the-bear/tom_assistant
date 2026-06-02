// LoopbackChatApi — the in-process Telegram channel test double for the
// end-to-end smoke (E.49).
//
// `tom_chattools` ships only the abstract `ChatApi` plus its single
// televerse-backed Telegram implementation — there is no fake. The access
// prototype carries its own loopback in *its* test layer; this is the smoke
// package's equivalent (a separate package cannot import another package's
// test files). It `implements ChatApi` so the smoke can drive the whole running
// process's Telegram edge — inbound injection, outbound delivery — with no
// televerse `Bot` and no Telegram network.
//
// Shape:
//   * Inbound — `onMessage` is a broadcast controller the smoke feeds through
//     [injectText] (the access process's adapter subscribes to it on start()).
//   * Outbound — every `sendMessage` / `send` records its text + receiver into
//     [sentMessages] / [sentReceivers]. The smoke reads these back to assert the
//     answer was delivered, or that a non-whitelisted sender drew the decline.
//   * Lifecycle — `initialize` / `disconnect` flip `isConnected`; the access
//     process drives them on boot / teardown.
//   * Unused surface — `getMessages` / `getReceiverInfo` / `downloadAttachment`
//     throw, documenting that the prototype Telegram path is text-only.

import 'dart:async';

import 'package:tom_chattools/tom_chattools.dart';

/// In-process [ChatApi] test double standing in for the Telegram backend.
final class LoopbackChatApi implements ChatApi {
  @override
  late ChatSettings settings;

  final StreamController<ChatMessage> _inbound =
      StreamController<ChatMessage>.broadcast();

  bool _connected = false;

  /// Every text the process sent, in call order.
  final List<String> sentMessages = <String>[];

  /// The receiver each [sentMessages] entry was addressed to, in the same
  /// order.
  final List<ChatReceiver> sentReceivers = <ChatReceiver>[];

  @override
  bool get isConnected => _connected;

  @override
  String get platform => 'telegram-loopback';

  @override
  Future<void> initialize() async {
    _connected = true;
  }

  @override
  Stream<ChatMessage> get onMessage => _inbound.stream;

  /// Feeds a fully-formed [message] into the inbound stream, as if the Telegram
  /// backend had received it.
  void injectInbound(ChatMessage message) => _inbound.add(message);

  /// Convenience inbound injector: builds a text [ChatMessage] from [senderId] /
  /// [messageId] / [text] and feeds it in. [chatId] rides `rawData`
  /// (`telegram_chat_id`) so the inbound mapping can derive `conversationId`; it
  /// defaults to [senderId] (a Telegram private chat's id equals the user id).
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
    return message;
  }

  @override
  Future<void> disconnect() async {
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
        'LoopbackChatApi is inbound via onMessage only; getMessages is not part '
        'of the prototype Telegram path.',
      );

  @override
  Future<ChatReceiverInfo?> getReceiverInfo(ChatReceiver receiver) =>
      throw UnimplementedError(
        'LoopbackChatApi does not model receiver profiles (text-only).',
      );

  @override
  Future<List<int>?> downloadAttachment(ChatAttachment attachment) =>
      throw UnimplementedError(
        'LoopbackChatApi is text-only; attachments are out of scope.',
      );
}
