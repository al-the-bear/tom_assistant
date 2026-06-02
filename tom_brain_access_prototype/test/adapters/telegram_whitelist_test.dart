// E.22 contract test — the Telegram user-id whitelist edge auth gate.
//
// Two surfaces are exercised:
//   * The pure policy `TelegramWhitelist` (telegram_whitelist.dart): the
//     empty-whitelist closed default (Q-E.22.1), exact-match membership, the
//     defensive copy, and the unmodifiable `allowedUserIds` view.
//   * The adapter's `authorizedInboundRequests` stream: a whitelisted text
//     message surfaces (no decline sent); a non-whitelisted sender draws the
//     graceful `telegramNotAuthorisedMessage` and nothing surfaces (no
//     `Access` is ever built); auth is the outermost gate (a non-text message
//     from a non-whitelisted sender still draws the decline). Driven through
//     the E.5 `LoopbackChatApi` double's recorded outbound calls.
//
// Per the E.22 scope ruling this test deliberately does NOT assert rate
// limiting / quota / anchor pre-check (E.29–E.31), identity / session /
// persona resolution (E.24–E.27), or dispatcher wiring (boot, E.41+).

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';
import 'package:test/test.dart';

import '../_support/loopback_chat_api.dart';

/// Lets the adapter's `asyncExpand` gate drain its awaited `sendMessage`
/// calls and yields before assertions (more than one awaited microtask per
/// rejected message, so a slightly generous pump).
Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('TelegramWhitelist — pure policy', () {
    test('an empty whitelist allows no one (closed default, Q-E.22.1)', () {
      final whitelist = TelegramWhitelist.empty();
      expect(whitelist.isAllowed('1'), isFalse);
      expect(whitelist.isAllowed(''), isFalse);
      expect(whitelist.allowedUserIds, isEmpty);
    });

    test('a constructed-empty whitelist also allows no one', () {
      final whitelist = TelegramWhitelist(const <String>[]);
      expect(whitelist.isAllowed('42'), isFalse);
    });

    test('permits exactly the configured ids, rejects the rest', () {
      final whitelist = TelegramWhitelist(const ['42', '7']);
      expect(whitelist.isAllowed('42'), isTrue);
      expect(whitelist.isAllowed('7'), isTrue);
      expect(whitelist.isAllowed('999'), isFalse);
    });

    test('membership is an exact, case-sensitive string match', () {
      final whitelist = TelegramWhitelist(const ['Abc']);
      expect(whitelist.isAllowed('Abc'), isTrue);
      expect(whitelist.isAllowed('abc'), isFalse);
      expect(whitelist.isAllowed(' Abc'), isFalse);
    });

    test('takes a defensive copy of the source ids', () {
      final source = <String>['1'];
      final whitelist = TelegramWhitelist(source);
      source.add('2'); // must not retroactively widen the whitelist.
      expect(whitelist.isAllowed('2'), isFalse);
      expect(whitelist.allowedUserIds, {'1'});
    });

    test('allowedUserIds is an unmodifiable view', () {
      final whitelist = TelegramWhitelist(const ['1']);
      expect(() => whitelist.allowedUserIds.add('2'), throwsUnsupportedError);
    });
  });

  group('TelegramAdapter.authorizedInboundRequests — edge auth gate', () {
    test('a whitelisted sender\'s text message surfaces, no decline sent',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '1', text: 'allowed', messageId: 'a');
      await _pump();

      expect(requests.map((r) => r.text), ['allowed']);
      // No decline message was sent to a whitelisted sender.
      expect(api.sentMessages, isEmpty);

      await adapter.stop();
    });

    test('a non-whitelisted sender is declined and nothing surfaces',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '999', text: 'who am I', messageId: 'b');
      await _pump();

      // No Access-bound request surfaces for a non-whitelisted sender.
      expect(requests, isEmpty);
      // The graceful decline was sent back to that sender.
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);
      expect(api.sentReceivers.single, const ChatReceiver.id('999'));
      // Stage-1 plain text — no parseMode.
      expect(api.sentParseModes.single, isNull);

      await adapter.stop();
    });

    test('only whitelisted senders pass when allowed and rejected interleave',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final texts = <String>[];
      adapter.authorizedInboundRequests.listen((r) => texts.add(r.text));

      await adapter.start();
      api.injectText(senderId: '1', text: 'kept-1');
      api.injectText(senderId: '999', text: 'dropped');
      api.injectText(senderId: '1', text: 'kept-2');
      await _pump();

      expect(texts, ['kept-1', 'kept-2']);
      // Exactly one decline — for the single non-whitelisted message.
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);
      expect(api.sentReceivers.single, const ChatReceiver.id('999'));

      await adapter.stop();
    });

    test('a whitelisted sender\'s non-text message is dropped silently',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      // A sticker from a whitelisted sender: passes auth, dropped by the
      // text-only Stage-1 mapping (E.20), and draws no decline (it was
      // authorised — it simply carried no prompt).
      api.injectInbound(ChatMessage(
        id: 'sticker-1',
        sender: const ChatSender(id: '1'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        type: ChatMessageType.sticker,
      ));
      await _pump();

      expect(requests, isEmpty);
      expect(api.sentMessages, isEmpty);

      await adapter.stop();
    });

    test('auth is the outermost gate: a non-text non-whitelisted message '
        'still draws the decline', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      // A sticker from a non-whitelisted sender: rejected at the edge before
      // the content is even examined.
      api.injectInbound(ChatMessage(
        id: 'sticker-2',
        sender: const ChatSender(id: '999'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        type: ChatMessageType.sticker,
      ));
      await _pump();

      expect(requests, isEmpty);
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);
      expect(api.sentReceivers.single, const ChatReceiver.id('999'));

      await adapter.stop();
    });

    test('the default (empty) whitelist rejects every sender', () async {
      final api = LoopbackChatApi();
      // No whitelist argument → TelegramWhitelist.empty() (closed default).
      final adapter = TelegramAdapter(chatApi: api);
      final requests = <InboundRequest>[];
      adapter.authorizedInboundRequests.listen(requests.add);

      await adapter.start();
      api.injectText(senderId: '1', text: 'hello');
      await _pump();

      expect(requests, isEmpty);
      expect(api.sentMessages, [telegramNotAuthorisedMessage]);

      await adapter.stop();
    });

    test('the ungated inboundRequests view ignores the whitelist', () async {
      // inboundRequests stays the raw mapped view for observability — it does
      // NOT apply the whitelist (only authorizedInboundRequests does).
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(
        chatApi: api,
        whitelist: TelegramWhitelist(const ['1']),
      );
      final texts = <String>[];
      adapter.inboundRequests.listen((r) => texts.add(r.text));

      await adapter.start();
      api.injectText(senderId: '999', text: 'not on list');
      await _pump();

      // The ungated view still maps it; no decline is sent from this path.
      expect(texts, ['not on list']);
      expect(api.sentMessages, isEmpty);

      await adapter.stop();
    });
  });
}
