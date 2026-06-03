// E.44 — whole-process YAML config loader conformance tests.
//
// What this file locks (proto spec § 11.4 / § 13.1; AC-11 / AC-12):
//
//   1. A well-formed `access:` section roundtrips into a typed
//      `AccessConfig` with every documented field — OpenAI port + base
//      path, Telegram bot token + whitelist, bearer + Telegram identity
//      bindings, the rate-limit / quota / anchor policies, the persona
//      vocabulary, the session window, and the embedding-cache TTL.
//   2. The single whole-process file may carry the four sibling sections
//      (`substrate:` / `memory:` / `engine:` / `dispatcher:`) alongside
//      `access:`; the access loader reads only `access:` and ignores the
//      rest — proving the "one file feeds all five loaders" structure.
//   3. Defaults: an omitted `basePath` → `/v1`; omitted `telegram` → no
//      channel; omitted `anchor` → disabled screen; omitted `personas` →
//      `null` (the default vocabulary); omitted `session` → the canonical
//      `defaultMaxWindowTurns`; omitted `classifier` → 5-minute TTL.
//   4. Forward-only schema (AC-12): an unknown top-level section, and an
//      unknown key *within* `access:` (or any subsection), is rejected at
//      load — never silently ignored.
//   5. `${ENV}` substitution expands bearer-token keys and the Telegram
//      bot token from the supplied env map; an undefined token is a loud
//      error; the loader never reads `Platform.environment` itself.
//   6. Required-field and type errors carry the dotted key path.
//   7. The whole surface reaches through the package barrel.

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';

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
    bearerTokens:
      "secret-token-alice":
        principalId: alice
        username: alice_login
        displayName: Alice
        numericId: 7
        claims:
          role: user
          tier: 2
  telegram:
    botToken: "bot-123:abc"
    users:
      "12345":
        principalId: alice
      "67890":
        principalId: bob
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
  session:
    maxWindowTurns: 12
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

    test('parses the bearer-token identity bindings', () {
      expect(config.bearerTokenBindings.keys, ['secret-token-alice']);
      final binding = config.bearerTokenBindings['secret-token-alice']!;
      expect(binding.principalId, 'alice');
      expect(binding.username, 'alice_login');
      expect(binding.displayName, 'Alice');
      expect(binding.numericId, 7);
      expect(binding.claims['role'], 'user');
      expect(binding.claims['tier'], 2);
    });

    test('parses the Telegram bot token and the whitelist bindings', () {
      expect(config.telegramBotToken, 'bot-123:abc');
      expect(config.hasTelegram, isTrue);
      expect(config.telegramUserIdBindings.keys, ['12345', '67890']);
      expect(config.telegramUserIdBindings['12345']!.principalId, 'alice');
      // The whitelist is the binding key set (one source of truth).
      expect(config.telegramWhitelist, {'12345', '67890'});
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

    test('parses the session window and the embedding-cache TTL', () {
      expect(config.sessionMaxWindowTurns, 12);
      expect(config.embeddingCacheTtl, const Duration(seconds: 120));
    });

    test('ignores the four sibling whole-process sections', () {
      // The presence of substrate/memory/engine/dispatcher must not throw
      // and must not leak into the access config — the access loader reads
      // only its own key.
      expect(() => AccessConfigLoader.parse(_fullDoc), returnsNormally);
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

    test('no bearer tokens ⇒ empty bindings', () {
      expect(config.bearerTokenBindings, isEmpty);
    });

    test('no anchor section ⇒ disabled screen', () {
      expect(config.anchorPolicy.isEmpty, isTrue);
    });

    test('no personas ⇒ null (default vocabulary)', () {
      expect(config.personaVocabulary, isNull);
    });

    test('no session section ⇒ canonical default window', () {
      expect(config.sessionMaxWindowTurns, defaultMaxWindowTurns);
    });

    test('no classifier section ⇒ 5-minute TTL', () {
      expect(config.embeddingCacheTtl, const Duration(minutes: 5));
    });

    test('no edgeState section ⇒ null (in-process state)', () {
      expect(config.edgeStateDirectory, isNull);
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

    test('expands \${ENV} in the directory', () {
      const doc = r'''
access:
  openai: { port: 1 }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
  edgeState:
    directory: "${STATE_DIR}/edge"
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

  group('E.44 \${ENV} substitution', () {
    test('expands bearer-token keys and the Telegram bot token', () {
      const doc = r'''
access:
  openai:
    port: 8080
    bearerTokens:
      "${ALICE_TOKEN}":
        principalId: alice
  telegram:
    botToken: "${TG_TOKEN}"
    users:
      "111": { principalId: alice }
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
    bearerTokens:
      "${MISSING}": { principalId: alice }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      expect(
        () => AccessConfigLoader.parse(doc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.message,
          'message',
          contains('undefined env var `\${MISSING}`'),
        )),
      );
    });

    test('Telegram user ids are NOT env-expanded (verbatim keys)', () {
      const doc = r'''
access:
  openai: { port: 8080 }
  telegram:
    users:
      "${LITERAL}": { principalId: alice }
  rateLimit: { capacity: 1, refillTokens: 1, refillPeriodSeconds: 1 }
  quota: { dailyCap: 1 }
''';
      // No env supplied; the user id is used verbatim and does not raise.
      final config = AccessConfigLoader.parse(doc);
      expect(config.telegramUserIdBindings.keys, [r'${LITERAL}']);
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
}
