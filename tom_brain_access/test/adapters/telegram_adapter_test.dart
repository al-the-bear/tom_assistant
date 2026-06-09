// E.19 contract test — the `TelegramAdapter` scaffold.
//
// Drives the adapter against the E.5 `LoopbackChatApi` double (no
// Telegram network, no socket): the long-polling lifecycle
// (`start` / `stop`, idempotency, backend calls), the raw inbound relay
// (`inboundMessages`), and the `fromConfig` factory seam.
//
// Per the E.19 scope ruling this test deliberately does NOT assert any
// `InboundRequest` mapping (E.20), outbound consolidation (E.21), or
// whitelist behaviour (E.22) — those land with their own substeps and the
// fuller E.23 roundtrip suite.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_chattools/tom_chattools.dart';
import 'package:test/test.dart';

import '../_support/loopback_chat_api.dart';

void main() {
  group('TelegramAdapter — lifecycle (long-polling)', () {
    test('is not running before start()', () {
      final adapter = TelegramAdapter(chatApi: LoopbackChatApi());
      expect(adapter.isRunning, isFalse);
    });

    test('start() initialises the backend exactly once and marks running',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      await adapter.start();

      expect(adapter.isRunning, isTrue);
      expect(api.initializeCount, 1);
      expect(api.isConnected, isTrue);
    });

    test('start() is idempotent — a second call does not re-initialise',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      await adapter.start();
      await adapter.start();

      expect(api.initializeCount, 1);
      expect(adapter.isRunning, isTrue);
    });

    test('stop() disconnects the backend and clears running', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      await adapter.start();
      await adapter.stop();

      expect(adapter.isRunning, isFalse);
      expect(api.disconnectCount, 1);
      expect(api.isConnected, isFalse);
    });

    test('stop() before start() is a no-op (no disconnect)', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);

      await adapter.stop();

      expect(api.disconnectCount, 0);
      expect(adapter.isRunning, isFalse);
    });

    test('platform delegates to the underlying backend', () {
      final adapter = TelegramAdapter(chatApi: LoopbackChatApi());
      expect(adapter.platform, 'telegram-loopback');
    });
  });

  group('TelegramAdapter — inbound relay', () {
    test('relays an injected message to inboundMessages while running',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final received = <ChatMessage>[];
      adapter.inboundMessages.listen(received.add);

      await adapter.start();
      api.injectText(senderId: '42', text: 'hello brain', messageId: '7');
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.text, 'hello brain');
      expect(received.single.sender.id, '42');
      expect(received.single.id, '7');

      await adapter.stop();
    });

    test('relays multiple messages in arrival order', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final texts = <String>[];
      adapter.inboundMessages.listen((m) => texts.add(m.text ?? ''));

      await adapter.start();
      api.injectText(senderId: '1', text: 'first');
      api.injectText(senderId: '1', text: 'second');
      api.injectText(senderId: '1', text: 'third');
      await Future<void>.delayed(Duration.zero);

      expect(texts, ['first', 'second', 'third']);

      await adapter.stop();
    });

    test('inboundMessages closes after stop()', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      var done = false;
      adapter.inboundMessages.listen((_) {}, onDone: () => done = true);

      await adapter.start();
      await adapter.stop();
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
    });

    test('a relay listener may attach before start() without missing events',
        () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter(chatApi: api);
      final texts = <String>[];

      // Attach BEFORE start — the broadcast relay exists from construction.
      adapter.inboundMessages.listen((m) => texts.add(m.text ?? ''));

      await adapter.start();
      api.injectText(senderId: '1', text: 'after-start');
      await Future<void>.delayed(Duration.zero);

      expect(texts, ['after-start']);
      await adapter.stop();
    });
  });

  group('TelegramAdapter.fromConfig — factory seam', () {
    test('builds an adapter from a TelegramChatConfig via the builder seam',
        () {
      final api = LoopbackChatApi();
      var builtFrom = '';
      final adapter = TelegramAdapter.fromConfig(
        const TelegramChatConfig(token: 'BOT_TOKEN'),
        buildChatApi: (config) {
          builtFrom = config.token;
          return api;
        },
      );

      expect(adapter.isRunning, isFalse);
      expect(adapter.platform, 'telegram-loopback');
      expect(builtFrom, 'BOT_TOKEN');
    });

    test('the factory-built adapter drives the injected backend', () async {
      final api = LoopbackChatApi();
      final adapter = TelegramAdapter.fromConfig(
        const TelegramChatConfig(token: 'BOT_TOKEN'),
        buildChatApi: (_) => api,
      );

      await adapter.start();
      expect(api.initializeCount, 1);
      await adapter.stop();
      expect(api.disconnectCount, 1);
    });
  });
}
