// E.20 contract test — the Telegram `ChatMessage` → `InboundRequest`
// mapping.
//
// Two surfaces are exercised:
//   * The pure projection `ChatMessage.toInboundRequest()`
//     (telegram_inbound_mapping.dart): every mapped field, the non-text
//     rejection, and the private-chat conversation-id fallback.
//   * The adapter's `inboundRequests` stream: the mapped, dropped-on-
//     rejection view driven through the E.5 `LoopbackChatApi` double.
//
// Per the E.20 scope ruling this test deliberately does NOT assert outbound
// consolidation (E.21), whitelist behaviour (E.22), or identity / session /
// persona resolution (E.24–E.27).

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';
import 'package:test/test.dart';

import '../_support/loopback_chat_api.dart';

/// Builds a text [ChatMessage] mirroring what the real Telegram backend
/// emits (`platformMessageId` set, sender id present), with an optional flat
/// `telegram_chat_id` on `rawData` (the loopback's anticipated key).
ChatMessage _telegramMessage({
  required String senderId,
  String? text,
  String messageId = '1',
  String? chatId,
}) =>
    ChatMessage(
      id: messageId,
      text: text,
      sender: ChatSender(id: senderId),
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      platformMessageId: messageId,
      rawData: chatId == null ? null : {'telegram_chat_id': chatId},
    );

void main() {
  group('ChatMessage.toInboundRequest — text mapping', () {
    test('maps body / message id / chat id / sender / streaming', () {
      final result = _telegramMessage(
        senderId: '42',
        text: 'hello brain',
        messageId: '7',
        chatId: '900',
      ).toInboundRequest();

      expect(result.isOk, isTrue);
      final req = (result as Ok<InboundRequest, TelegramInboundError>).value;
      expect(req.text, 'hello brain');
      expect(req.messageId, '7');
      expect(req.conversationId, '900');
      expect(req.metadata[telegramSenderIdMetadataKey], '42');
      expect(req.streaming, isFalse);
    });

    test('falls back to the sender id for conversationId in a private chat',
        () {
      // No flat telegram_chat_id (an older backend; tom_chattools 2.0.0 and
      // later stamps it). For a private chat the chat id equals the user id.
      final result = _telegramMessage(
        senderId: '12345',
        text: 'private message',
      ).toInboundRequest();

      final req = (result as Ok<InboundRequest, TelegramInboundError>).value;
      expect(req.conversationId, '12345');
    });

    test('uses platformMessageId for messageId, falling back to id', () {
      // platformMessageId present → used.
      final withPlatform = ChatMessage(
        id: 'internal-1',
        text: 'x',
        sender: const ChatSender(id: '1'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        platformMessageId: 'tg-99',
      ).toInboundRequest();
      expect(
        (withPlatform as Ok<InboundRequest, TelegramInboundError>)
            .value
            .messageId,
        'tg-99',
      );

      // platformMessageId absent → falls back to id.
      final withoutPlatform = ChatMessage(
        id: 'internal-2',
        text: 'x',
        sender: const ChatSender(id: '1'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ).toInboundRequest();
      expect(
        (withoutPlatform as Ok<InboundRequest, TelegramInboundError>)
            .value
            .messageId,
        'internal-2',
      );
    });

    test('metadata carrying the sender id is unmodifiable', () {
      final req = (_telegramMessage(senderId: '5', text: 'hi')
              .toInboundRequest() as Ok<InboundRequest, TelegramInboundError>)
          .value;
      expect(
        () => req.metadata['x'] = 'y',
        throwsUnsupportedError,
      );
    });
  });

  group('ChatMessage.toInboundRequest — non-text rejection', () {
    test('rejects a message with null text (Stage-1 is text-only)', () {
      final result = _telegramMessage(senderId: '1').toInboundRequest();
      expect(result.isErr, isTrue);
      final err = (result as Err<InboundRequest, TelegramInboundError>).error;
      expect(err.reason, TelegramInboundRejection.noText);
    });

    test('rejects an empty-string body', () {
      final result =
          _telegramMessage(senderId: '1', text: '').toInboundRequest();
      expect(result.isErr, isTrue);
      expect(
        (result as Err<InboundRequest, TelegramInboundError>).error.reason,
        TelegramInboundRejection.noText,
      );
    });

    test('rejects a whitespace-only body', () {
      final result =
          _telegramMessage(senderId: '1', text: '   \n\t ').toInboundRequest();
      expect(result.isErr, isTrue);
      expect(
        (result as Err<InboundRequest, TelegramInboundError>).error.reason,
        TelegramInboundRejection.noText,
      );
    });

    test('the rejection message names the message id and never throws', () {
      final result =
          _telegramMessage(senderId: '1', messageId: '88').toInboundRequest();
      final err = (result as Err<InboundRequest, TelegramInboundError>).error;
      expect(err.message, contains('88'));
    });
  });

  group('TelegramAdapter.inboundRequests — mapped stream', () {
    test('emits one InboundRequest per text message, in arrival order',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final requests = <InboundRequest>[];
      adapter.inboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '1', text: 'first', messageId: 'a');
      api.injectText(senderId: '1', text: 'second', messageId: 'b');
      await Future<void>.delayed(Duration.zero);

      expect(requests.map((r) => r.text), ['first', 'second']);
      expect(requests.map((r) => r.messageId), ['a', 'b']);
      expect(
        requests.every((r) => r.metadata[telegramSenderIdMetadataKey] == '1'),
        isTrue,
      );

      await adapter.stop();
    });

    test('drops non-text messages from the mapped stream', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final texts = <String>[];
      adapter.inboundRequests.listen((r) => texts.add(r.text));

      await adapter.start();
      // A non-text message (no text) interleaved with two text messages.
      api.injectText(senderId: '1', text: 'kept-1');
      api.injectInbound(ChatMessage(
        id: 'sticker-1',
        sender: const ChatSender(id: '1'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        type: ChatMessageType.sticker,
      ));
      api.injectText(senderId: '1', text: 'kept-2');
      await Future<void>.delayed(Duration.zero);

      expect(texts, ['kept-1', 'kept-2']);

      await adapter.stop();
    });

    test('derives conversationId from the loopback chat id', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final requests = <InboundRequest>[];
      adapter.inboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '7', text: 'hi', chatId: '7');
      await Future<void>.delayed(Duration.zero);

      expect(requests.single.conversationId, '7');

      await adapter.stop();
    });
  });
}
