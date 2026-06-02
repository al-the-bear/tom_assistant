// E.24 contract test — the `IdentityResolver` edge identity step.
//
// Three surfaces are exercised:
//   * `IdentityBinding` (the prototype principal-facts record): the
//     non-empty `principalId` guard, the `username` default, the
//     defensive-copy / unmodifiable `claims`.
//   * `IdentityResolver.resolveOpenAiBearer` / `.resolveTelegramUser`: a
//     bound credential resolves to the binding's `ResolvedIdentity` (the
//     `principalId` is the configured non-secret id, *never* the bearer
//     token); an unbound credential throws `IdentityResolutionException`
//     (and the OpenAI variant never leaks the token); the same `principalId`
//     configured on both channels yields one identity (AC-7 — identity is
//     the person, the channel distinction is the session's job, E.25).
//
// Per the E.24 scope ruling this test deliberately does NOT assert session
// resolution (E.25), persona resolution (E.26), credential *validation*
// (the auth step E.22/E.28), or dispatcher wiring (boot, E.41+).

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:test/test.dart';

void main() {
  group('IdentityBinding — principal-facts record', () {
    test('rejects an empty principalId', () {
      expect(
        () => IdentityBinding(principalId: ''),
        throwsArgumentError,
      );
    });

    test('username defaults to principalId when omitted', () {
      final binding = IdentityBinding(principalId: 'alexis');
      expect(binding.username, 'alexis');
    });

    test('username is used verbatim when supplied', () {
      final binding =
          IdentityBinding(principalId: 'p-1', username: 'alexis.k');
      expect(binding.username, 'alexis.k');
    });

    test('claims are stored as an unmodifiable copy', () {
      final source = <String, Object?>{'role': 'owner'};
      final binding = IdentityBinding(principalId: 'p-1', claims: source);
      // Mutating the source does not leak into the binding.
      source['role'] = 'tampered';
      expect(binding.claims['role'], 'owner');
      // The stored view itself is unmodifiable.
      expect(
        () => binding.claims['role'] = 'x',
        throwsUnsupportedError,
      );
    });

    test('numericId defaults to the kernel unset sentinel (-1)', () {
      expect(IdentityBinding(principalId: 'p-1').numericId, -1);
    });
  });

  group('IdentityResolver — OpenAI bearer token', () {
    test('resolves a bound token to its ResolvedIdentity', () {
      final resolver = IdentityResolver(
        bearerTokenBindings: {
          'sk-secret-123': IdentityBinding(
            principalId: 'alexis',
            displayName: 'Alexis',
            claims: const {'tier': 'owner'},
          ),
        },
      );

      final identity = resolver.resolveOpenAiBearer('sk-secret-123');

      expect(identity.principalId, 'alexis');
      expect(identity.displayName, 'Alexis');
      expect(identity.claims['tier'], 'owner');
    });

    test('the principalId is the configured id, never the bearer token', () {
      final resolver = IdentityResolver(
        bearerTokenBindings: {
          'sk-secret-123': IdentityBinding(principalId: 'alexis'),
        },
      );

      final identity = resolver.resolveOpenAiBearer('sk-secret-123');

      expect(identity.principalId, isNot(contains('sk-secret')));
      expect(identity.principalId, 'alexis');
    });

    test('throws on an unbound token without leaking it', () {
      final resolver = IdentityResolver(
        bearerTokenBindings: {
          'sk-known': IdentityBinding(principalId: 'alexis'),
        },
      );

      expect(
        () => resolver.resolveOpenAiBearer('sk-unknown-secret'),
        throwsA(
          isA<IdentityResolutionException>()
              .having((e) => e.channel, 'channel', 'openai')
              .having((e) => e.toString(), 'toString',
                  isNot(contains('sk-unknown-secret'))),
        ),
      );
    });
  });

  group('IdentityResolver — Telegram user id', () {
    test('resolves a bound user id to its ResolvedIdentity', () {
      final resolver = IdentityResolver(
        telegramUserIdBindings: {
          '42': IdentityBinding(
            principalId: 'alexis',
            displayName: 'Alexis',
          ),
        },
      );

      final identity = resolver.resolveTelegramUser('42');

      expect(identity.principalId, 'alexis');
      expect(identity.displayName, 'Alexis');
    });

    test('throws on an unbound user id, carrying the public id', () {
      final resolver = IdentityResolver(
        telegramUserIdBindings: {
          '42': IdentityBinding(principalId: 'alexis'),
        },
      );

      expect(
        () => resolver.resolveTelegramUser('999'),
        throwsA(
          isA<IdentityResolutionException>()
              .having((e) => e.channel, 'channel', 'telegram')
              .having((e) => e.toString(), 'toString', contains('999')),
        ),
      );
    });
  });

  group('IdentityResolver — cross-channel identity (AC-7)', () {
    test('the same principalId on both channels yields one identity', () {
      final binding = IdentityBinding(principalId: 'alexis');
      final resolver = IdentityResolver(
        bearerTokenBindings: {'sk-secret': binding},
        telegramUserIdBindings: {'42': binding},
      );

      final viaOpenAi = resolver.resolveOpenAiBearer('sk-secret');
      final viaTelegram = resolver.resolveTelegramUser('42');

      // Same person → same principalId for memory attribution; the channel
      // distinction is the SessionManager's job (E.25), not the identity's.
      expect(viaOpenAi.principalId, viaTelegram.principalId);
      expect(viaOpenAi, equals(viaTelegram));
    });

    test('an empty resolver throws for every credential', () {
      final resolver = IdentityResolver();
      expect(
        () => resolver.resolveOpenAiBearer('anything'),
        throwsA(isA<IdentityResolutionException>()),
      );
      expect(
        () => resolver.resolveTelegramUser('anything'),
        throwsA(isA<IdentityResolutionException>()),
      );
    });
  });
}
