// memory_session_profiles_plan.md step 3 — `ApiKeyConfig` prefix resolution
// and the loader's fold of `access.apiKeys[]` into the bearer-token bindings.
//
// What this file locks (memory_session_profiles.md § 3.2 / § 5.1, MSP-4 /
// MSP-5):
//
//   1. The pure resolver `ApiKeyConfig.resolveScope(markers)` applies
//      `effective id = prefix + (selector ?? 'default')` for both the session
//      and the memory id — explicit prefixes, default prefixes, present and
//      absent selectors.
//   2. Sharing proof: two keys with identical prefixes resolve a given pair of
//      markers to identical ids (deliberate shared scope).
//   3. Isolation proof: two keys with distinct prefixes can never collide on
//      the same selectors (distinct namespaces).
//   4. `effectivePrincipalId` / `toBinding()`: an omitted principal falls back
//      to the key (§ 5.1); a set principal wins; the binding carries it.
//   5. The loader folds a parsed `apiKeys[]` block into `bearerTokenBindings`
//      (so an API key authenticates like a user token) and exposes each entry
//      via `apiKeyFor`, with default prefixes when omitted and `${env}`
//      expansion of the secret key.
//   6. Forward-only schema (AC-12) + collision rules: an unknown entry key, a
//      duplicate API key, and an API key colliding with a user bearer token are
//      all rejected at load.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

void main() {
  group('ApiKeyConfig.resolveScope — § 3.2 / MSP-4', () {
    test('explicit prefixes + no markers → "<prefix>default"', () {
      final cfg = ApiKeyConfig(
        key: 'sk-acme',
        sessionPrefix: 'acme_',
        memoryPrefix: 'acme_',
      );
      const markers = ApiKeyMarkers(
        residualKey: 'sk-acme',
        sessionSelector: null,
        memorySelector: null,
      );
      final scope = cfg.resolveScope(markers);
      expect(scope.sessionId, 'acme_default');
      expect(scope.memoryProfile, 'acme_default');
    });

    test('default prefixes + no markers → the built-in "<default>default" ids',
        () {
      final cfg = ApiKeyConfig(key: 'sk-plain');
      // The constructor defaults are the MSP-4 built-ins.
      expect(cfg.sessionPrefix, defaultSessionPrefix);
      expect(cfg.memoryPrefix, defaultMemoryPrefix);
      const markers = ApiKeyMarkers(
        residualKey: 'sk-plain',
        sessionSelector: null,
        memorySelector: null,
      );
      final scope = cfg.resolveScope(markers);
      expect(scope.sessionId, 'defaultsession_default');
      expect(scope.memoryProfile, 'defaultmemory_default');
    });

    test('present selectors are concatenated onto the prefix verbatim (D-2)',
        () {
      final cfg = ApiKeyConfig(
        key: 'sk-acme',
        sessionPrefix: 'acme_',
        memoryPrefix: 'mem_',
      );
      final markers = parseApiKeyMarkers('session-foo_sk-acme_memory-bar');
      final scope = cfg.resolveScope(markers);
      expect(scope.sessionId, 'acme_foo');
      expect(scope.memoryProfile, 'mem_bar');
    });

    test('a present session selector with an absent memory selector mixes '
        'selector + default', () {
      final cfg = ApiKeyConfig(
        key: 'sk-acme',
        sessionPrefix: 'acme_',
        memoryPrefix: 'acme_',
      );
      final markers = parseApiKeyMarkers('session-foo_sk-acme');
      final scope = cfg.resolveScope(markers);
      expect(scope.sessionId, 'acme_foo');
      expect(scope.memoryProfile, 'acme_default');
    });

    test('sharing proof: identical prefixes resolve to identical ids', () {
      final a = ApiKeyConfig(
        key: 'sk-a',
        sessionPrefix: 'team_',
        memoryPrefix: 'team_',
      );
      final b = ApiKeyConfig(
        key: 'sk-b',
        sessionPrefix: 'team_',
        memoryPrefix: 'team_',
      );
      final markers = parseApiKeyMarkers('session-s_memory-m');
      // Different credentials, same namespace ⇒ same effective scope.
      expect(a.resolveScope(markers), b.resolveScope(markers));
      expect(a.resolveScope(markers).sessionId, 'team_s');
    });

    test('isolation proof: distinct prefixes never collide on equal selectors',
        () {
      final a = ApiKeyConfig(
        key: 'sk-a',
        sessionPrefix: 'red_',
        memoryPrefix: 'red_',
      );
      final b = ApiKeyConfig(
        key: 'sk-b',
        sessionPrefix: 'blue_',
        memoryPrefix: 'blue_',
      );
      // The *same* markers under two namespaces resolve disjointly.
      final markers = parseApiKeyMarkers('session-x_memory-x');
      final scopeA = a.resolveScope(markers);
      final scopeB = b.resolveScope(markers);
      expect(scopeA.sessionId, 'red_x');
      expect(scopeB.sessionId, 'blue_x');
      expect(scopeA.sessionId, isNot(scopeB.sessionId));
      expect(scopeA.memoryProfile, isNot(scopeB.memoryProfile));
    });

    test('ResolvedProfileScope has value equality', () {
      const a = ResolvedProfileScope(sessionId: 's', memoryProfile: 'm');
      const b = ResolvedProfileScope(sessionId: 's', memoryProfile: 'm');
      const c = ResolvedProfileScope(sessionId: 's', memoryProfile: 'other');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ApiKeyConfig.effectivePrincipalId / toBinding — § 5.1', () {
    test('an omitted principal falls back to the key itself', () {
      final cfg = ApiKeyConfig(key: 'sk-secret');
      expect(cfg.effectivePrincipalId, 'sk-secret');
      expect(cfg.toBinding().principalId, 'sk-secret');
    });

    test('a set principal wins and is carried onto the binding', () {
      final cfg = ApiKeyConfig(
        key: 'sk-secret',
        principal: 'owner',
        displayName: 'ACME bot',
      );
      expect(cfg.effectivePrincipalId, 'owner');
      final binding = cfg.toBinding();
      expect(binding.principalId, 'owner');
      expect(binding.displayName, 'ACME bot');
    });

    test('an empty key is rejected', () {
      expect(() => ApiKeyConfig(key: ''), throwsArgumentError);
    });
  });

  group('AccessConfig api-key wiring', () {
    test('bindingsForApiKeys keys the bearer map by the credential', () {
      final bearer = AccessConfig.bindingsForApiKeys([
        ApiKeyConfig(key: 'sk-a', principal: 'owner-a'),
        ApiKeyConfig(key: 'sk-b', principal: 'owner-b'),
      ]);
      expect(bearer.keys, ['sk-a', 'sk-b']);
      expect(bearer['sk-a']!.principalId, 'owner-a');
    });

    test('bindingsForApiKeys rejects a duplicate key', () {
      expect(
        () => AccessConfig.bindingsForApiKeys([
          ApiKeyConfig(key: 'sk-dup'),
          ApiKeyConfig(key: 'sk-dup'),
        ]),
        throwsArgumentError,
      );
    });

    test('apiKeyFor looks an entry up by residual key', () {
      final config = AccessConfig(
        openAiPort: 8080,
        rateLimitPolicy: RateLimitPolicy(
          capacity: 10,
          refillTokens: 5,
          refillPeriod: const Duration(seconds: 30),
        ),
        dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
        anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
        apiKeys: [
          ApiKeyConfig(key: 'sk-a', sessionPrefix: 'a_', memoryPrefix: 'a_'),
        ],
      );
      expect(config.apiKeyFor('sk-a')!.sessionPrefix, 'a_');
      expect(config.apiKeyFor('absent'), isNull);
    });

    test('the constructor rejects a duplicate api key', () {
      expect(
        () => AccessConfig(
          openAiPort: 8080,
          rateLimitPolicy: RateLimitPolicy(
            capacity: 10,
            refillTokens: 5,
            refillPeriod: const Duration(seconds: 30),
          ),
          dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
          anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
          apiKeys: [
            ApiKeyConfig(key: 'sk-dup'),
            ApiKeyConfig(key: 'sk-dup'),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('AccessConfigLoader fold of access.apiKeys[]', () {
    const doc = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
  apiKeys:
    - key: \${env:ACME_API_KEY}
      principal: owner
      sessionPrefix: acme_
      memoryPrefix: acme_
      displayName: ACME bot
    - key: no-key
''';

    test('parses entries, folds the secret into bearerTokenBindings, and '
        'applies defaults + env expansion', () {
      final config = AccessConfigLoader.parse(
        doc,
        envVars: const {'ACME_API_KEY': 'sk-real-acme'},
      );
      // The list is parsed in order with its prefixes.
      expect(config.apiKeys.map((k) => k.key), ['sk-real-acme', 'no-key']);
      final acme = config.apiKeys.first;
      expect(acme.sessionPrefix, 'acme_');
      expect(acme.memoryPrefix, 'acme_');
      expect(acme.principal, 'owner');
      expect(acme.displayName, 'ACME bot');
      // The well-known no-key entry takes the MSP-4 default prefixes.
      final noKey = config.apiKeys[1];
      expect(noKey.sessionPrefix, defaultSessionPrefix);
      expect(noKey.memoryPrefix, defaultMemoryPrefix);
      // Both fold into the bearer bindings (so they authenticate).
      expect(config.bearerTokenBindings.keys, ['sk-real-acme', 'no-key']);
      expect(config.bearerTokenBindings['sk-real-acme']!.principalId, 'owner');
      // no-key has no principal → its key is the principal (§ 5.1).
      expect(config.bearerTokenBindings['no-key']!.principalId, 'no-key');
      // The looked-up entry resolves a no-marker request to "<prefix>default".
      const noMarkers = ApiKeyMarkers(
        residualKey: 'sk-real-acme',
        sessionSelector: null,
        memorySelector: null,
      );
      final scope = config.apiKeyFor('sk-real-acme')!.resolveScope(noMarkers);
      expect(scope.sessionId, 'acme_default');
      expect(scope.memoryProfile, 'acme_default');
    });

    test('an omitted apiKeys block is legal — no entries, no bindings', () {
      const minimal = '''
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
      final config = AccessConfigLoader.parse(minimal);
      expect(config.apiKeys, isEmpty);
      expect(config.bearerTokenBindings, isEmpty);
    });

    test('an api key colliding with a user bearer token is rejected', () {
      const collide = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
  users:
    - id: alice
      openaiBearerTokens:
        - "shared-secret"
  apiKeys:
    - key: shared-secret
''';
      expect(
        () => AccessConfigLoader.parse(collide),
        throwsA(isA<AccessConfigException>()),
      );
    });

    test('a duplicate api key is rejected at load', () {
      const dup = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
  apiKeys:
    - key: sk-dup
    - key: sk-dup
''';
      expect(
        () => AccessConfigLoader.parse(dup),
        throwsA(isA<AccessConfigException>()),
      );
    });

    test('an unknown key in an apiKeys entry is rejected (AC-12)', () {
      const unknown = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
  apiKeys:
    - key: sk-a
      bogus: nope
''';
      expect(
        () => AccessConfigLoader.parse(unknown),
        throwsA(isA<AccessConfigException>()),
      );
    });

    test('a missing key in an apiKeys entry is rejected', () {
      const noKeyField = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
  apiKeys:
    - principal: orphan
''';
      expect(
        () => AccessConfigLoader.parse(noKeyField),
        throwsA(isA<AccessConfigException>()),
      );
    });
  });
}
