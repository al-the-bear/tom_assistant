// G-3 / MSPP-61 — `users[].openaiBearerTokens` → `apiKeys[]` migration parity.
//
// Followup #7 retires the legacy per-user OpenAI bearer channel: every OpenAI
// bearer credential is now declared as a first-class `access.apiKeys[]` entry,
// and `users[]` carries only Telegram credentials (plus the rich identity
// facts). Per Hard principle 1 there is no compatibility shim — the legacy
// `openaiBearerTokens` key is *removed*, not tolerated.
//
// This suite locks the two halves of the done-when:
//
//   1. **Parity** — a token migrated into `apiKeys[]` authenticates to the same
//      `principalId` the legacy `users[]` token admitted. The shipped run
//      credential was `users[owner].openaiBearerTokens: [run-token]`, which
//      admitted `principalId == 'owner'`; the migrated
//      `apiKeys: [{key: run-token, principal: owner}]` must admit the same.
//
//   2. **No compatibility shim** — a config that still uses the legacy
//      `users[].openaiBearerTokens` key is rejected at load (AC-12 unknown-key),
//      so the legacy shape cannot silently keep working.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// A whole-process document whose only OpenAI credential is the migrated
/// `apiKeys[]` entry. `owner` remains a declared user for its Telegram
/// credential — exactly the shipped `brain_run.yaml` shape after migration.
const String _migratedDoc = '''
access:
  openai:
    port: 8080
  telegram:
    botToken: "bot-123:abc"
  users:
    - id: owner
      displayName: Owner
      telegramUserIds:
        - "555"
  apiKeys:
    - key: run-token
      principal: owner
      displayName: Owner
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
''';

/// The same intent expressed in the *legacy* shape — the OpenAI credential as a
/// per-user bearer token. After MSPP-61 this key no longer exists.
const String _legacyDoc = '''
access:
  openai:
    port: 8080
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - run-token
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
''';

void main() {
  group('G-3 / MSPP-61 apiKeys[] migration', () {
    test('the migrated apiKeys[] token admits the same principal the legacy '
        'users[] token did (run-token → owner)', () {
      final config = AccessConfigLoader.parse(_migratedDoc);

      // Authentication parity: the token resolves to a bearer binding whose
      // principalId is `owner` — identical to what `users[].openaiBearerTokens`
      // produced (a binding keyed on `user.id`).
      final binding = config.bearerTokenBindings['run-token'];
      expect(binding, isNotNull,
          reason: 'the migrated apiKeys[] entry is folded into the '
              'bearer-token bindings, so the token still authenticates');
      expect(binding!.principalId, 'owner');

      // The namespace side: the same key is indexed as an ApiKeyConfig so the
      // edge can resolve its session/memory scope after authentication.
      expect(config.apiKeyFor('run-token'), isNotNull);
      expect(config.apiKeyFor('run-token')!.effectivePrincipalId, 'owner');

      // owner stays a declared human via its Telegram credential.
      expect(config.telegramUserIdBindings['555']!.principalId, 'owner');
    });

    test('the legacy users[].openaiBearerTokens key is rejected — no '
        'compatibility shim (Hard principle 1)', () {
      expect(
        () => AccessConfigLoader.parse(_legacyDoc),
        throwsA(isA<AccessConfigException>().having(
          (e) => e.toString(),
          'message',
          contains('openaiBearerTokens'),
        )),
      );
    });
  });
}
