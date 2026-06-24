// LoopbackChatApi — in-process Telegram channel test double, ported verbatim
// from `tom_brain_access/test/_support/loopback_chat_api.dart` (E.5 / E.19).
//
// `tom_chattools` ships only the abstract `ChatApi` plus its single
// televerse-backed Telegram implementation — there is no fake. This
// consumer-authored double therefore `implements ChatApi` so the r52 LIVE
// end-to-end Telegram suite can drive the access edge's inbound relay + outbound
// delivery with no Telegram network, no televerse `Bot`, and no socket: it is
// handed to `standUpBrainProcessFromConfig` through the `telegramChatApiFactory`
// seam, and the test injects inbound messages / reads the recorded outbound.
//
// Shape:
//   * Inbound — `onMessage` is backed by a broadcast controller fed by the test
//     through [injectInbound] / [injectText].
//   * Outbound — every `sendMessage` / `send` call is recorded into [sentMessages]
//     (+ [sentReceivers] / [sentParseModes]) so the delivery can be asserted by
//     counting / concatenating recorded outbound messages.
//   * Lifecycle — `initialize` / `isConnected` / `disconnect` are stubbed and
//     counted so the boot + shutdown orchestration can be verified.
//   * Unused surface — `getMessages` / `getReceiverInfo` / `downloadAttachment`
//     throw `UnimplementedError`: the Telegram path is text-only.

import 'dart:async';

import 'package:tom_chattools/tom_chattools.dart';

/// In-process [ChatApi] test double standing in for the Telegram backend.
final class LoopbackChatApi implements ChatApi {
  /// The settings the adapter would normally pass in; unused by the loopback
  /// but required by the `ChatApi` contract.
  @override
  late ChatSettings settings;

  final StreamController<ChatMessage> _inbound =
      StreamController<ChatMessage>.broadcast();

  bool _connected = false;

  /// How many times [initialize] was called.
  int initializeCount = 0;

  /// How many times [disconnect] was called.
  int disconnectCount = 0;

  /// Every text the adapter sent, in call order.
  final List<String> sentMessages = <String>[];

  /// The receiver each entry of [sentMessages] was addressed to, in order.
  final List<ChatReceiver> sentReceivers = <ChatReceiver>[];

  /// The `parseMode` each entry of [sentMessages] carried (`null` when none was
  /// supplied), in order.
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

  /// Feeds a fully-formed [message] into the inbound stream, as if the Telegram
  /// backend had received it.
  void injectInbound(ChatMessage message) => _inbound.add(message);

  /// Convenience inbound injector: builds a text [ChatMessage] from a
  /// [senderId] / [messageId] / [text] and feeds it in. [chatId] is carried on
  /// `rawData` (`telegram_chat_id`) so the mapping can derive `conversationId`
  /// from it; it defaults to [senderId] (a Telegram private chat's id equals the
  /// user id).
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
        'LoopbackChatApi is inbound via onMessage only; getMessages is not part '
        'of the Telegram path.',
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
