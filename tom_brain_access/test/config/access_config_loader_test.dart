// E.44 — whole-process YAML config loader conformance tests.
//
// What this file locks (proto spec § 11.4 / § 13.1; AC-11 / AC-12;
// Q-E.24.2):
//
//   1. A well-formed `access:` section roundtrips into a typed
//      `AccessConfig` with every documented field — OpenAI port + base
//      path, Telegram bot token, the declared `users` block, the Telegram
//      identity bindings *derived from those users*, the bearer bindings
//      *derived from `apiKeys[]`* (MSPP-61 / G-3), the rate-limit / quota /
//      anchor policies, the persona vocabulary, the session window, and the
//      embedding-cache TTL.
//   2. The `users` block is the single declarative Telegram identity source:
//      one human, one `principalId`; its OpenAI bearer credential is declared
//      as an `apiKeys[]` entry whose `principal` shares that id (Q-E.24.2).
//   3. The single whole-process file may carry the four sibling sections
//      (`substrate:` / `memory:` / `engine:` / `dispatcher:`) alongside
//      `access:`; the access loader reads only `access:` and ignores the
//      rest — proving the "one file feeds all five loaders" structure.
//   4. Defaults: an omitted `basePath` → `/v1`; omitted `telegram` → no
//      channel; omitted `users` → no bindings; omitted `anchor` → disabled
//      screen; omitted `personas` → `null` (the default vocabulary);
//      omitted `classifier` → 5-minute TTL.
//   5. Forward-only schema (AC-12): an unknown top-level section, and an
//      unknown key *within* `access:` (or any subsection / user entry), is
//      rejected at load — never silently ignored.
//   6. `${env:NAME}` substitution expands each `apiKeys[]` credential, the
//      Telegram bot token, and each user's Telegram user ids from the
//      supplied env map; an undefined token is a loud error; the loader never
//      reads `Platform.environment` itself.
//   7. Required-field and type errors carry the dotted key path.
//   8. The whole surface reaches through the package barrel.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show HistorySizing, foregroundAnswerLaneId;

/// A complete, well-formed whole-process document. The four sibling
/// sections are present-but-ignored stand-ins, proving the access loader
/// reads only its own section.
const String _fullDoc = '''
substrate:
  providers: []
memory:
  store: {}
engine:
  scriptsDir: scripts/system
dispatcher:
  foregroundQueueDepth: 4
access:
  openai:
    port: 8080
    basePath: /v1
  telegram:
    botToken: "bot-123:abc"
  users:
    - id: alice
      username: alice_login
      displayName: Alice
      numericId: 7
      claims:
        role: user
        tier: 2
      telegramUserIds:
        - "12345"
    - id: bob
      telegramUserIds:
        - "67890"
  apiKeys:
    - key: "secret-token-alice"
      principal: alice
      displayName: Alice
  rateLimit:
    capacity: 30
    refillTokens: 30
    refillPeriodSeconds: 60
  quota:
    dailyCap: 500
  anchor:
    disallowedSignatures:
      - "ignore previous instructions"
      - "disregard your"
  personas:
    - tom-assistant
    - tom-assistant:terse
  classifier:
    embeddingCacheTtlSeconds: 120
''';

/// The minimum viable `access:` section — only the required keys.
const String _minimalDoc = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
''';

void main() {
  group('E.44 full document roundtrip', () {
    late AccessConfig config;

    setUp(() {
      config = AccessConfigLoader.parse(_fullDoc);
    });

    test('parses the OpenAI port + base path', () {
      expect(config.openAiPort, 8080);
      expect(config.openAiBasePath, '/v1');
    });

    test('parses the declared users (Q-E.24.2)', () {
      expect(config.users.map((u) => u.id), ['alice', 'bob']);
      final alice = config.users.first;
      expect(alice.username, 'alice_login');
      expect(alice.displayName, 'Alice');
      expect(alice.numericId, 7);
      expect(alice.claims['role'], 'user');
      expect(alice.claims['tier'], 2);
      expect(alice.telegramUserIds, ['12345']);
      final bob = config.users[1];
      expect(bob.telegramUserIds, ['67890']);
    });

    test('derives the bearer-token bindings from the apiKeys block', () {
      // OpenAI bearer credentials are declared as `access.apiKeys[]` (MSPP-61
      // / G-3); the binding they yield is minimal (principalId + displayName),
      // username defaulting to the principal and no claims/numericId.
      expect(config.bearerTokenBindings.keys, ['secret-token-alice']);
      final binding = config.bearerTokenBindings['secret-token-alice']!;
      expect(binding.principalId, 'alice');
      expect(binding.username, 'alice');
      expect(binding.displayName, 'Alice');
      expect(binding.numericId, -1);
      expect(binding.claims, isEmpty);
    });

    test('derives the Telegram bindings + whitelist from the users block', () {
      expect(config.telegramBotToken, 'bot-123:abc');
      expect(config.hasTelegram, isTrue);
      expect(config.telegramUserIdBindings.keys, ['12345', '67890']);
      expect(config.telegramUserIdBindings['12345']!.principalId, 'alice');
      expect(config.telegramUserIdBindings['67890']!.principalId, 'bob');
      // The whitelist is the binding key set (one source of truth).
      expect(config.telegramWhitelist, {'12345', '67890'});
    });

    test('the apiKey bearer and the Telegram credential share the principal '
        '(Q-E.24.2)', () {
      // Alice's OpenAI bearer credential (an `apiKeys[]` entry, principal:
      // alice) and her Telegram credential resolve to the *same* principal id
      // — the unifying fact. The apiKey binding is minimal, so the richer
      // human facts (username/numericId/claims) live on the Telegram binding
      // derived from the `users[]` entry.
      final viaBearer = config.bearerTokenBindings['secret-token-alice']!;
      final viaTelegram = config.telegramUserIdBindings['12345']!;
      expect(viaBearer.principalId, viaTelegram.principalId);
      expect(viaTelegram.username, 'alice_login');
      expect(viaTelegram.numericId, 7);
      expect(viaTelegram.claims['tier'], 2);
    });

    test('parses the rate-limit policy', () {
      expect(config.rateLimitPolicy.capacity, 30);
      expect(config.rateLimitPolicy.refillTokens, 30);
      expect(config.rateLimitPolicy.refillPeriod, const Duration(seconds: 60));
    });

    test('parses the daily quota cap', () {
      expect(config.dailyQuotaPolicy.dailyCap, 500);
    });

    test('parses the anchor signatures preserving order and casing', () {
      expect(config.anchorPolicy.disallowedSignatures,
          ['ignore previous instructions', 'disregard your']);
      expect(config.anchorPolicy.isEmpty, isFalse);
    });

    test('parses the persona vocabulary', () {
      expect(config.personaVocabulary, ['tom-assistant', 'tom-assistant:terse']);
    });

    test('parses the embedding-cache TTL', () {
      expect(config.embeddingCacheTtl, const Duration(seconds: 120));
    });

    test('ignores the four sibling whole-process sections', () {
      // The presence of substrate/memory/engine/dispatcher must not throw
      // and must not leak into the access config — the access loader reads
      // only its own key.
      expect(() => AccessConfigLoader.parse(_fullDoc), returnsNormally);
    });
  });

  group('E.44 user block (Q-E.24.2)', () {
    test('a Telegram-only user yields a Telegram binding and no bearer', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: svc
      telegramUserIds: ["42"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.bearerTokenBindings, isEmpty);
      expect(config.telegramUserIdBindings.keys, ['42']);
      expect(config.telegramWhitelist, {'42'});
    });

    test('username defaults to the user id when omitted', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: ["7"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.telegramUserIdBindings['7']!.username, 'alice');
    });

    test('a user with no credentials is a loud error', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: ghost
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('access.users[0]'),
              contains('at least one Telegram user id')),
        )),
      );
    });

    test('a duplicate user id is rejected', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: ["123"]
    - id: alice
      telegramUserIds: ["456"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('access.users'), contains('duplicate user id')),
        )),
      );
    });

    test('a Telegram id shared by two users is rejected', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: ["999"]
    - id: bob
      telegramUserIds: ["999"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('access.users'),
              contains('shared by two users')),
        )),
      );
    });

    test('rejects an unknown key within a user entry', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: ["1"]
      mystery: 1
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users[0] has unknown key "mystery"'),
        )),
      );
    });

    test('rejects the retired openaiBearerTokens key (MSPP-61 / G-3)', () {
      // The legacy per-user OpenAI bearer channel is removed, not tolerated —
      // declaring it is an unknown-key error (Hard principle 1, no shim).
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: ["1"]
      openaiBearerTokens: ["sk-a"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users[0] has unknown key "openaiBearerTokens"'),
        )),
      );
    });

    test('rejects a non-list users section', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    alice: { telegramUserIds: ["1"] }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users'),
        )),
      );
    });

    test('rejects a non-map user entry', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - "not-a-map"
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users[0] must be a map'),
        )),
      );
    });

    test('an empty user id is rejected', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: ""
      telegramUserIds: ["1"]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users[0].id must be non-empty'),
        )),
      );
    });

    test('an empty Telegram user id entry is rejected', () {
      const doc = '''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds: [""]
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.users[0].telegramUserIds[0] must be non-empty'),
        )),
      );
    });
  });

  group('E.44 defaults', () {
    late AccessConfig config;

    setUp(() {
      config = AccessConfigLoader.parse(_minimalDoc);
    });

    test('basePath defaults to /v1', () {
      expect(config.openAiBasePath, '/v1');
    });

    test('no telegram section ⇒ no channel, empty whitelist', () {
      expect(config.telegramBotToken, isNull);
      expect(config.hasTelegram, isFalse);
      expect(config.telegramUserIdBindings, isEmpty);
      expect(config.telegramWhitelist, isEmpty);
    });

    test('no users section ⇒ no users, empty bindings', () {
      expect(config.users, isEmpty);
      expect(config.bearerTokenBindings, isEmpty);
    });

    test('no anchor section ⇒ disabled screen', () {
      expect(config.anchorPolicy.isEmpty, isTrue);
    });

    test('no personas ⇒ null (default vocabulary)', () {
      expect(config.personaVocabulary, isNull);
    });

    test('no classifier section ⇒ 5-minute TTL', () {
      expect(config.embeddingCacheTtl, const Duration(minutes: 5));
    });

    test('no edgeState section ⇒ null (in-process state)', () {
      expect(config.edgeStateDirectory, isNull);
    });

    test('no history block ⇒ answer lane uses the standard sizing', () {
      // todo #7: the foreground answer lane resolves to HistorySizing.standard()
      // when the document carries no top-level `history:` block.
      expect(config.answerLaneSizing, const HistorySizing.standard());
    });
  });

  // todo #7: the top-level `history:` block sizes the foreground answer lane.
  // The loader resolves `history.lanes.foreground ?? history.defaults` into
  // `AccessConfig.answerLaneSizing`; boot hands it to the SessionManager,
  // replacing the formerly hardcoded `HistorySizing.standard()` (HP1).
  group('todo #7 — top-level history: block sizes the answer lane', () {
    test('the defaults block sizes the foreground answer lane', () {
      const doc = '''
history:
  defaults:
    rawCount: 20
    compactionThreshold: 55
    maxCompactedTokens: 2048
    maxCompactedChars: 8000
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.answerLaneSizing.rawCount, 20);
      expect(config.answerLaneSizing.compactionThreshold, 55);
      expect(config.answerLaneSizing.maxCompactedTokens, 2048);
      expect(config.answerLaneSizing.maxCompactedChars, 8000);
    });

    test('a foreground lane override wins over the defaults', () {
      const doc = '''
history:
  defaults:
    rawCount: 12
  lanes:
    foreground:
      rawCount: 30
    dream_slow:
      rawCount: 50
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      final config = AccessConfigLoader.parse(doc);
      // The foreground lane wins; the dream lane override is irrelevant here.
      expect(config.answerLaneSizing.rawCount, 30);
    });

    test('with a history block but no foreground lane ⇒ the defaults size it',
        () {
      const doc = '''
history:
  defaults:
    rawCount: 18
  lanes:
    dream_fast:
      rawCount: 40
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.answerLaneSizing.rawCount, 18);
    });

    test('a below-floor rawCount is rejected with a located message', () {
      const doc = '''
history:
  lanes:
    foreground:
      rawCount: 4
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(
          isA<AccessConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('history.lanes.foreground.rawCount'),
              contains('minimum of 10'),
            ),
          ),
        ),
      );
    });

    test('a non-map top-level history block is rejected', () {
      const doc = '''
history: not-a-map
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>()),
      );
    });

    test('the resolved lane id is the foreground answer lane constant', () {
      // Guards the wiring: the loader resolves exactly `foregroundAnswerLaneId`,
      // so naming the lane by that constant in the config sizes the answer lane.
      final doc = '''
history:
  lanes:
    $foregroundAnswerLaneId:
      rawCount: 27
access:
  openai: { port: 9090 }
  rateLimit: { capacity: 10, refillTokens: 5, refillPeriodSeconds: 30 }
  quota: { dailyCap: 100 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.answerLaneSizing.rawCount, 27);
    });
  });

  group('#29 Ollama + Anthropic channels', () {
    // Plan-2 #29 adds two optional bearer HTTP channels alongside OpenAI.
    // They share the OpenAI transport shape (required port, optional
    // `/`-rooted basePath) but carry their own listening port + mount path;
    // identity / personas / policies remain the shared ones.

    test('the full document declares neither channel ⇒ both off', () {
      final config = AccessConfigLoader.parse(_fullDoc);
      expect(config.hasOllama, isFalse);
      expect(config.hasAnthropic, isFalse);
    });

    test('a declared ollama section turns the channel on', () {
      const doc = '''
access:
  openai: { port: 8080 }
  ollama:
    port: 11434
    basePath: /api
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.hasOllama, isTrue);
      expect(config.ollamaPort, 11434);
      expect(config.ollamaBasePath, '/api');
      // The Anthropic sibling is still off — the two are independent.
      expect(config.hasAnthropic, isFalse);
      expect(config.anthropicPort, isNull);
    });

    test('a declared anthropic section turns the channel on', () {
      const doc = '''
access:
  openai: { port: 8080 }
  anthropic:
    port: 8443
    basePath: /v1
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.hasAnthropic, isTrue);
      expect(config.anthropicPort, 8443);
      expect(config.anthropicBasePath, '/v1');
      expect(config.hasOllama, isFalse);
      expect(config.ollamaPort, isNull);
    });

    test('all four channels may coexist in one document', () {
      const doc = '''
access:
  openai: { port: 8080 }
  telegram: { botToken: "bot-1:x" }
  ollama: { port: 11434 }
  anthropic: { port: 8443 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.openAiPort, 8080);
      expect(config.hasTelegram, isTrue);
      expect(config.hasOllama, isTrue);
      expect(config.hasAnthropic, isTrue);
    });

    test('basePath defaults to /api (ollama) and /v1 (anthropic) when omitted',
        () {
      const doc = '''
access:
  openai: { port: 8080 }
  ollama: { port: 11434 }
  anthropic: { port: 8443 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.ollamaBasePath, '/api');
      expect(config.anthropicBasePath, '/v1');
    });

    test('an omitted section ⇒ channel off, default base path retained', () {
      // _minimalDoc declares only OpenAI; both optional channels are absent.
      final config = AccessConfigLoader.parse(_minimalDoc);
      expect(config.hasOllama, isFalse);
      expect(config.ollamaPort, isNull);
      expect(config.ollamaBasePath, '/api');
      expect(config.hasAnthropic, isFalse);
      expect(config.anthropicPort, isNull);
      expect(config.anthropicBasePath, '/v1');
    });

    test('rejects a non-positive ollama port', () {
      const doc = '''
access:
  openai: { port: 8080 }
  ollama: { port: 0 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.ollama.port must be > 0'),
        )),
      );
    });

    test('rejects a missing required anthropic port', () {
      const doc = '''
access:
  openai: { port: 8080 }
  anthropic: { basePath: /v1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.anthropic.port'),
        )),
      );
    });

    test('rejects an ollama base path that is not /-rooted', () {
      const doc = '''
access:
  openai: { port: 8080 }
  ollama: { port: 11434, basePath: "api" }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.ollama.basePath'),
        )),
      );
    });

    test('rejects an unknown key within the ollama section', () {
      const doc = '''
access:
  openai: { port: 8080 }
  ollama: { port: 11434, mystery: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.ollama has unknown key "mystery"'),
        )),
      );
    });

    test('rejects an unknown key within the anthropic section', () {
      const doc = '''
access:
  openai: { port: 8080 }
  anthropic: { port: 8443, mystery: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.anthropic has unknown key "mystery"'),
        )),
      );
    });
  });

  group('E.44 edgeState (P1.4)', () {
    test('parses access.edgeState.directory', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  edgeState:
    directory: /var/lib/tom_brain/edge_state
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.edgeStateDirectory, '/var/lib/tom_brain/edge_state');
    });

    test('expands \${env:NAME} in the directory', () {
      const doc = r'''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  edgeState:
    directory: "${env:STATE_DIR}/edge"
''';
      final config = AccessConfigLoader.parse(
        doc,
        envVars: const {'STATE_DIR': '/srv/state'},
      );
      expect(config.edgeStateDirectory, '/srv/state/edge');
    });

    test('rejects an unknown key within edgeState', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  edgeState: { directory: /x, mystery: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.edgeState has unknown key "mystery"'),
        )),
      );
    });

    test('rejects an empty directory', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  edgeState: { directory: "" }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.edgeState.directory must be non-empty'),
        )),
      );
    });
  });

  group('history persistence (§ 21.10 — "nothing is ever lost")', () {
    test('no history section ⇒ null (in-process histories)', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(AccessConfigLoader.parse(doc).historyDirectory, isNull);
    });

    test('parses access.history.directory', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  history:
    directory: /var/lib/tom_brain/history
''';
      final config = AccessConfigLoader.parse(doc);
      expect(config.historyDirectory, '/var/lib/tom_brain/history');
    });

    test('expands \${env:NAME} in the directory', () {
      const doc = r'''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  history:
    directory: "${env:HISTORY_DIR}/history"
''';
      final config = AccessConfigLoader.parse(
        doc,
        envVars: const {'HISTORY_DIR': '/srv/state'},
      );
      expect(config.historyDirectory, '/srv/state/history');
    });

    test('rejects an unknown key within history', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  history: { directory: /x, mystery: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.history has unknown key "mystery"'),
        )),
      );
    });

    test('rejects an empty directory', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  history: { directory: "" }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.history.directory must be non-empty'),
        )),
      );
    });
  });

  group('E.44 forward-only schema (AC-12)', () {
    test('rejects an unknown top-level section', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
mystery:
  foo: bar
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('Unknown top-level config section "mystery"'),
        )),
      );
    });

    // The whole-process document now also carries a `trail:` section (owned by
    // the run package's `TrailConfigLoader`; logging-spec §8). The access loader
    // tolerates it as a sibling — exactly as it tolerates substrate / memory /
    // engine / dispatcher — so the single file feeds every section loader.
    test('tolerates a sibling trail: section', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
trail:
  root: /srv/brain/trail
''';
      expect(() => AccessConfigLoader.parse(doc), returnsNormally);
    });

    // The whole-process document also carries the run package's `dream:` and
    // `cognition:` sections (owned by `DreamConfigLoader` / the cognition
    // loader; memory-spec § 9.7 / `prompt_configuration.md` §7.4). The access
    // loader tolerates both as siblings so the single file feeds every loader.
    test('tolerates sibling dream: and cognition: sections', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
dream:
  enabled: false
cognition:
  root: /srv/brain/cognition
''';
      expect(() => AccessConfigLoader.parse(doc), returnsNormally);
    });

    test('rejects an unknown key within access:', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  surprise: true
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access has unknown key "surprise"'),
        )),
      );
    });

    test('rejects an unknown key within a subsection', () {
      const doc = '''
access:
  openai: { port: 1, mystery: 2 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.openai has unknown key "mystery"'),
        )),
      );
    });
  });

  group('E.44 \${env:NAME} substitution', () {
    test('expands apiKey credentials and the Telegram bot token', () {
      const doc = r'''
access:
  openai:
    port: 8080
  telegram:
    botToken: "${env:TG_TOKEN}"
  users:
    - id: alice
      telegramUserIds:
        - "111"
  apiKeys:
    - key: "${env:ALICE_TOKEN}"
      principal: alice
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(
        doc,
        envVars: const {
          'ALICE_TOKEN': 'sk-alice-xyz',
          'TG_TOKEN': 'bot-999:zzz',
        },
      );
      expect(config.bearerTokenBindings.keys, ['sk-alice-xyz']);
      expect(config.telegramBotToken, 'bot-999:zzz');
    });

    test('an undefined env token is a loud error', () {
      const doc = r'''
access:
  openai:
    port: 8080
  apiKeys:
    - key: "${env:MISSING}"
      principal: alice
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('undefined env var `\${env:MISSING}`'),
        )),
      );
    });

    test('expands a user\'s Telegram user ids from the env map', () {
      // The deployment workflow sources the owner whitelist from the shell
      // profile (e.g. `${env:TELEGRAM_TOM_BRAIN_USER}`); the expanded numeric id —
      // not the placeholder — becomes the identity-binding key a real sender
      // is matched against.
      const doc = r'''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds:
        - "${env:OWNER_ID}"
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      final config = AccessConfigLoader.parse(
        doc,
        envVars: const {'OWNER_ID': '279417862'},
      );
      expect(config.telegramUserIdBindings.keys, ['279417862']);
    });

    test('an undefined Telegram-user-id env var is a loud error', () {
      const doc = r'''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds:
        - "${env:MISSING_OWNER}"
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('undefined env var `\${env:MISSING_OWNER}`'),
        )),
      );
    });

    test('a literal numeric Telegram user id is unaffected by expansion', () {
      const doc = r'''
access:
  openai: { port: 8080 }
  users:
    - id: alice
      telegramUserIds:
        - "279417862"
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      // No `${}` in a numeric id, so expansion is a no-op and no env is needed.
      final config = AccessConfigLoader.parse(doc);
      expect(config.telegramUserIdBindings.keys, ['279417862']);
    });
  });

  group('E.44 errors carry dotted key paths', () {
    test('missing access: map', () {
      expect(
        () => AccessConfigLoader.parse('substrate: {}'),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('Missing top-level `access:` map'),
        )),
      );
    });

    test('non-map document root', () {
      expect(
        () => AccessConfigLoader.parse('- a\n- b'),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('Config root must be a YAML map'),
        )),
      );
    });

    test('missing required openai.port', () {
      const doc = '''
access:
  openai: {}
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.openai.port'),
        )),
      );
    });

    test('wrong type for a field carries the path', () {
      const doc = '''
access:
  openai: { port: "not-a-number" }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('access.openai.port'), contains('integer')),
        )),
      );
    });

    test('a zero daily cap is a misconfiguration', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 0 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.quota'),
        )),
      );
    });

    test('an empty anchor signature is rejected', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  anchor:
    disallowedSignatures:
      - ""
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.anchor'),
        )),
      );
    });

    test('empty personas list when present is rejected', () {
      const doc = '''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  personas: []
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.personas'),
        )),
      );
    });

    test('basePath must start with /', () {
      const doc = '''
access:
  openai: { port: 1, basePath: "v1" }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('access.openai.basePath'),
        )),
      );
    });
  });

  group('E.44 AccessConfig direct construction guards', () {
    test('rejects a non-positive port', () {
      expect(
        () => AccessConfig(
          openAiPort: 0,
          rateLimitPolicy: RateLimitPolicy(
            capacity: 1,
            refillTokens: 1,
            refillPeriod: const Duration(seconds: 1),
          ),
          dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 1),
          anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
        ),
        throwsArgumentError,
      );
    });

    test('bindings are unmodifiable defensive copies', () {
      final config = AccessConfig(
        openAiPort: 1,
        rateLimitPolicy: RateLimitPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
        dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 1),
        anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
        bearerTokenBindings: {
          'tok': IdentityBinding(principalId: 'a'),
        },
      );
      expect(
        () => config.bearerTokenBindings['x'] = IdentityBinding(principalId: 'b'),
        throwsUnsupportedError,
      );
    });
  });

  group('E.44 AccessUser construction guards (Q-E.24.2)', () {
    test('rejects an empty id', () {
      expect(
        () => AccessUser(id: '', telegramUserIds: const ['1']),
        throwsArgumentError,
      );
    });

    test('rejects a user with no credentials', () {
      expect(
        () => AccessUser(id: 'ghost'),
        throwsArgumentError,
      );
    });

    test('username defaults to the id', () {
      final user = AccessUser(id: 'alice', telegramUserIds: const ['1']);
      expect(user.username, 'alice');
    });

    test('toBinding carries the user facts onto one binding', () {
      final user = AccessUser(
        id: 'alice',
        username: 'alice_login',
        numericId: 7,
        displayName: 'Alice',
        claims: const {'role': 'user'},
        telegramUserIds: const ['1'],
      );
      final binding = user.toBinding();
      expect(binding.principalId, 'alice');
      expect(binding.username, 'alice_login');
      expect(binding.numericId, 7);
      expect(binding.displayName, 'Alice');
      expect(binding.claims['role'], 'user');
    });

    test('bindingsForUsers projects the Telegram credentials', () {
      final telegram = AccessConfig.bindingsForUsers([
        AccessUser(
          id: 'alice',
          telegramUserIds: const ['12345'],
        ),
      ]);
      expect(telegram['12345']!.principalId, 'alice');
    });

    test('bindingsForUsers rejects a shared Telegram credential', () {
      expect(
        () => AccessConfig.bindingsForUsers([
          AccessUser(id: 'alice', telegramUserIds: const ['999']),
          AccessUser(id: 'bob', telegramUserIds: const ['999']),
        ]),
        throwsArgumentError,
      );
    });

    test('users list is an unmodifiable defensive copy', () {
      final config = AccessConfig(
        openAiPort: 1,
        rateLimitPolicy: RateLimitPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(seconds: 1),
        ),
        dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 1),
        anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
        users: [AccessUser(id: 'a', telegramUserIds: const ['1'])],
      );
      expect(
        () => config.users.add(AccessUser(id: 'b', telegramUserIds: const ['2'])),
        throwsUnsupportedError,
      );
    });
  });
}
