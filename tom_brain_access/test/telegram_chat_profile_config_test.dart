// Step 9 — per-chat Telegram config (`memory_session_profiles.md` § 9.1, MSP-6;
// plan step 9; decisions MSPP-28/MSPP-29/MSPP-30).
//
// `TelegramChatProfileConfig` is the typed `access.telegram.chats[]` entry plus the
// pure rule that turns a chat's prefixes into the effective session + memory
// ids it scopes its commands within. A configured chat resolves to its prefixed
// ids; an *unconfigured* chat (no entry) resolves to `defaultsession_default` /
// `defaultmemory_default` — byte-compatible with a brand-new chat.
//
// Group 1 proves the pure value type + resolution. Group 2 proves the loader
// folds `access.telegram.chats[]` into `AccessConfig.telegramChats`, indexes it
// by `chatId` (rejecting duplicates), and that `telegramChatFor` + the
// `unconfigured` fallback satisfy the done-when end-to-end.

import 'package:tom_brain_access/tom_brain_access.dart'
    show
        AccessConfigException,
        AccessConfigLoader,
        TelegramChatProfileConfig,
        defaultMemoryPrefix,
        defaultSessionPrefix;
import 'package:test/test.dart';

void main() {
  group('TelegramChatProfileConfig — pure value + resolution', () {
    test('a configured chat resolves to its prefixed default ids', () {
      final chat = TelegramChatProfileConfig(
        chatId: '12345',
        principal: 'owner',
        sessionPrefix: 'tg_owner_',
        memoryPrefix: 'tg_owner_',
      );
      // defaultSession / defaultMemory default to 'default'.
      expect(chat.effectiveDefaultSessionId, 'tg_owner_default');
      expect(chat.effectiveDefaultMemoryProfile, 'tg_owner_default');
      expect(chat.effectivePrincipalId, 'owner');
    });

    test('a selector is namespaced within the chat scope; absent ⇒ chat default',
        () {
      final chat = TelegramChatProfileConfig(
        chatId: '7',
        sessionPrefix: 'tg_owner_',
        memoryPrefix: 'tg_owner_',
        defaultSession: 'work',
        defaultMemory: 'home',
      );
      // An explicit selector is prefixed verbatim (a command argument).
      expect(chat.resolveSessionId('side'), 'tg_owner_side');
      expect(chat.resolveMemoryProfile('lab'), 'tg_owner_lab');
      // A null selector falls back to the chat's configured default selector.
      expect(chat.resolveSessionId(null), 'tg_owner_work');
      expect(chat.resolveMemoryProfile(null), 'tg_owner_home');
    });

    test('an unconfigured chat resolves to the built-in default ids', () {
      final chat = TelegramChatProfileConfig.unconfigured('99');
      expect(chat.sessionPrefix, defaultSessionPrefix);
      expect(chat.memoryPrefix, defaultMemoryPrefix);
      expect(chat.effectiveDefaultSessionId, 'defaultsession_default');
      expect(chat.effectiveDefaultMemoryProfile, 'defaultmemory_default');
      // With no `principal`, the principal id is the chat id itself.
      expect(chat.effectivePrincipalId, '99');
    });

    test('an empty chatId is rejected', () {
      expect(
        () => TelegramChatProfileConfig(chatId: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('defaultProfile defaults to "default" and is taken verbatim (§ 6)', () {
      expect(TelegramChatProfileConfig(chatId: '1').defaultProfile, 'default');
      expect(
        TelegramChatProfileConfig(chatId: '1', defaultProfile: 'research')
            .defaultProfile,
        'research',
      );
      expect(
        TelegramChatProfileConfig.unconfigured('9').defaultProfile,
        'default',
      );
    });
  });

  group('AccessConfigLoader — access.telegram.chats[] → typed config', () {
    /// Minimal valid `access:` envelope with a telegram block; [chats] is the
    /// YAML for the `chats:` list (already indented under `telegram:`).
    String yamlWithChats(String chats) => '''
access:
  openai:
    port: 8080
  telegram:
    botToken: tok
    chats:
$chats
  rateLimit:
    capacity: 10
    refillTokens: 1.0
    refillPeriodSeconds: 1.0
  quota:
    dailyCap: 100
''';

    test('a configured chat folds into telegramChats with its prefixes', () {
      final config = AccessConfigLoader.parse(yamlWithChats('''
      - chatId: "12345"
        principal: owner
        sessionPrefix: tg_owner_
        memoryPrefix: tg_owner_
'''));
      expect(config.telegramChats, hasLength(1));
      final chat = config.telegramChatFor('12345');
      expect(chat, isNotNull);
      expect(chat!.effectiveDefaultSessionId, 'tg_owner_default');
      expect(chat.effectiveDefaultMemoryProfile, 'tg_owner_default');
      expect(chat.effectivePrincipalId, 'owner');
    });

    test('a configured chat folds in its defaultProfile (§ 6)', () {
      final config = AccessConfigLoader.parse(yamlWithChats('''
      - chatId: "12345"
        defaultProfile: research
'''));
      expect(config.telegramChatFor('12345')!.defaultProfile, 'research');
    });

    test('an integer chatId is coerced to its decimal string', () {
      final config = AccessConfigLoader.parse(yamlWithChats('''
      - chatId: 424242
        sessionPrefix: tg_a_
'''));
      final chat = config.telegramChatFor('424242');
      expect(chat, isNotNull);
      expect(chat!.chatId, '424242');
      expect(chat.effectiveDefaultSessionId, 'tg_a_default');
    });

    test('a \${env:NAME} chatId is expanded from the env map', () {
      final config = AccessConfigLoader.parse(
        yamlWithChats('''
      - chatId: \${env:TG_OWNER_CHAT}
        memoryPrefix: tg_owner_
'''),
        envVars: const {'TG_OWNER_CHAT': '55667788'},
      );
      final chat = config.telegramChatFor('55667788');
      expect(chat, isNotNull);
      expect(chat!.effectiveDefaultMemoryProfile, 'tg_owner_default');
    });

    test('an unconfigured chat resolves to the built-in defaults', () {
      // No chats configured at all.
      final config = AccessConfigLoader.parse('''
access:
  openai:
    port: 8080
  rateLimit:
    capacity: 10
    refillTokens: 1.0
    refillPeriodSeconds: 1.0
  quota:
    dailyCap: 100
''');
      expect(config.telegramChats, isEmpty);
      // The edge's resolution idiom (steps 10–11): missing entry ⇒ unconfigured.
      final chat = config.telegramChatFor('does-not-exist') ??
          TelegramChatProfileConfig.unconfigured('does-not-exist');
      expect(chat.effectiveDefaultSessionId, 'defaultsession_default');
      expect(chat.effectiveDefaultMemoryProfile, 'defaultmemory_default');
    });

    test('a duplicate chatId is rejected (never a silent last-wins)', () {
      expect(
        () => AccessConfigLoader.parse(yamlWithChats('''
      - chatId: "1"
        sessionPrefix: tg_a_
      - chatId: "1"
        sessionPrefix: tg_b_
''')),
        throwsA(isA<AccessConfigException>()),
      );
    });

    test('an unknown key inside a chat entry is rejected (AC-12)', () {
      expect(
        () => AccessConfigLoader.parse(yamlWithChats('''
      - chatId: "1"
        bogus: x
''')),
        throwsA(isA<AccessConfigException>()),
      );
    });
  });
}
