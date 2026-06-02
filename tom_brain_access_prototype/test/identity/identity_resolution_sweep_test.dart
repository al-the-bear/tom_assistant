// E.27 contract test — the identity / session / persona resolution sweep.
//
// E.24, E.25 and E.26 each shipped with their own per-resolver suite. E.27 is
// the *cross-resolver* sweep the plan calls for ("token / user-id resolution;
// session reuse across calls; persona defaulting when no model id provided") —
// it exercises the three resolvers the way the edge composes them to fill an
// `Access`, and locks the contract that they cohere:
//
//   * Identity (E.24) resolves the *person* — one `principalId` per credential,
//     channel-blind, the same id whether the request arrived over OpenAI or
//     Telegram.
//   * Session (E.25) keys on that `principalId` + channel + conversation; reuse
//     across calls returns the *same* node (AC-8), and the channel splits one
//     person into two sessions.
//   * Persona (E.26) maps the model id (or its absence) to a `Persona`; an
//     absent / unrecognised model defaults (AC-5) while identity and session
//     stay stable.
//
// Per the E.27 scope ruling this test deliberately does NOT assert dispatcher
// wiring, `Access` construction, or memory-node persistence (E.41+ / E.55) —
// it exercises the three resolver outputs as a unit, not the running process.

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// One known OpenAI credential and its binding (secret token → stable id).
const _bearerToken = 'sk-secret-edge-token';

/// One known Telegram credential for the *same* person (public user id).
const _telegramUserId = '4242';

/// The stable, non-secret principal id both credentials map to.
const _principalId = 'principal:alex';

/// Builds a resolver where one person owns both a bearer token and a Telegram
/// user id, both mapping to [_principalId] — the cross-channel identity the
/// E.24 design guarantees.
IdentityResolver _identityResolver() => IdentityResolver(
      bearerTokenBindings: {
        _bearerToken: IdentityBinding(
          principalId: _principalId,
          displayName: 'Alex',
          claims: const {'role': 'owner'},
        ),
      },
      telegramUserIdBindings: {
        _telegramUserId: IdentityBinding(
          principalId: _principalId,
          displayName: 'Alex',
          claims: const {'role': 'owner'},
        ),
      },
    );

/// An inbound request fixture carrying the fields the session resolver reads.
InboundRequest _inbound({
  required String text,
  String? conversationId,
  String? messageId,
}) =>
    InboundRequest(
      text: text,
      conversationId: conversationId,
      messageId: messageId,
    );

void main() {
  group('E.27 — token / user-id resolution', () {
    test('a bound bearer token resolves to the configured identity', () {
      final identity = _identityResolver().resolveOpenAiBearer(_bearerToken);

      expect(identity.principalId, _principalId);
      expect(identity.displayName, 'Alex');
      expect(identity.claims['role'], 'owner');
    });

    test('a bound Telegram user id resolves to the configured identity', () {
      final identity =
          _identityResolver().resolveTelegramUser(_telegramUserId);

      expect(identity.principalId, _principalId);
      expect(identity.displayName, 'Alex');
    });

    test('both channels of one person resolve to the same identity (AC-7)', () {
      final resolver = _identityResolver();

      final viaOpenAi = resolver.resolveOpenAiBearer(_bearerToken);
      final viaTelegram = resolver.resolveTelegramUser(_telegramUserId);

      // Channel-blind identity: same principal id, structurally equal handle.
      expect(viaOpenAi.principalId, viaTelegram.principalId);
      expect(viaOpenAi, viaTelegram);
    });

    test('the resolved principal id never echoes the secret bearer token', () {
      final identity = _identityResolver().resolveOpenAiBearer(_bearerToken);

      expect(identity.principalId, isNot(contains('sk-secret')));
    });

    test('an unbound credential surfaces a typed failure per channel', () {
      final resolver = _identityResolver();

      expect(
        () => resolver.resolveOpenAiBearer('sk-not-configured'),
        throwsA(isA<IdentityResolutionException>()
            .having((e) => e.channel, 'channel', 'openai')),
      );
      expect(
        () => resolver.resolveTelegramUser('9999'),
        throwsA(isA<IdentityResolutionException>()
            .having((e) => e.channel, 'channel', 'telegram')),
      );
    });
  });

  group('E.27 — session reuse across calls', () {
    test('repeated calls on one identity + channel + conversation reuse the '
        'same node (AC-8)', () {
      final identity = _identityResolver().resolveOpenAiBearer(_bearerToken);
      final sessions = SessionManager();

      final first = sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello', conversationId: 'c1'),
      );
      final second = sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'again', conversationId: 'c1'),
      );

      // Same node, not a re-creation — the second turn appended.
      expect(identical(first, second), isTrue);
      expect(second.sessionId, first.sessionId);
      expect(second.totalTurns, 2);
      expect(sessions.sessionCount, 1);
    });

    test('the same person on a different channel is a different session', () {
      final resolver = _identityResolver();
      final openAiIdentity = resolver.resolveOpenAiBearer(_bearerToken);
      final telegramIdentity = resolver.resolveTelegramUser(_telegramUserId);
      final sessions = SessionManager();

      final openAiSession = sessions.resolve(
        identity: openAiIdentity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'over openai', conversationId: 'shared'),
      );
      final telegramSession = sessions.resolve(
        identity: telegramIdentity,
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'over telegram', conversationId: 'shared'),
      );

      // Same principal id, same conversation id — but the channel splits them.
      expect(openAiSession.key.principalId, telegramSession.key.principalId);
      expect(identical(openAiSession, telegramSession), isFalse);
      expect(openAiSession.sessionId, isNot(telegramSession.sessionId));
      expect(sessions.sessionCount, 2);
    });

    test('different conversations on one channel are different sessions', () {
      final identity = _identityResolver().resolveOpenAiBearer(_bearerToken);
      final sessions = SessionManager();

      sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'first thread', conversationId: 'c1'),
      );
      sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'second thread', conversationId: 'c2'),
      );

      expect(sessions.sessionCount, 2);
    });
  });

  group('E.27 — persona defaulting', () {
    test('a recognised model id resolves to that persona', () {
      final persona = PersonaResolver().resolve('tom-assistant:terse');

      expect(persona.personaId, 'tom-assistant:terse');
      expect(persona.substrateRole, Persona.defaultSubstrateRole);
    });

    test('a null model id (no model named) defaults to the assistant '
        'persona (AC-5)', () {
      final persona = PersonaResolver().resolve(null);

      expect(persona, Persona.assistant());
      expect(persona.personaId, Persona.defaultPersonaId);
    });

    test('an unrecognised model id defaults rather than erroring (AC-5)', () {
      final persona = PersonaResolver().resolve('gpt-4o');

      expect(persona, Persona.assistant());
    });
  });

  group('E.27 — the three resolvers compose into one coherent edge result', () {
    test('a multi-turn conversation keeps identity + persona stable while the '
        'session accumulates turns', () {
      final identityResolver = _identityResolver();
      final sessions = SessionManager();
      final personas = PersonaResolver();

      // Turn 1 — the caller names a persona model id.
      final identity1 = identityResolver.resolveOpenAiBearer(_bearerToken);
      final session1 = sessions.resolve(
        identity: identity1,
        channel: AccessChannel.openai,
        envelope: _inbound(
          text: 'turn one',
          conversationId: 'thread-1',
          messageId: 'm1',
        ),
      );
      final persona1 = personas.resolve('tom-assistant:verbose');

      // Turn 2 — same person, same conversation, no model id named.
      final identity2 = identityResolver.resolveOpenAiBearer(_bearerToken);
      final session2 = sessions.resolve(
        identity: identity2,
        channel: AccessChannel.openai,
        envelope: _inbound(
          text: 'turn two',
          conversationId: 'thread-1',
          messageId: 'm2',
        ),
      );
      final persona2 = personas.resolve(null);

      // Identity is stable across the two turns (same person).
      expect(identity1, identity2);
      expect(identity2.principalId, _principalId);

      // The session is reused (same node) and accumulates both turns.
      expect(identical(session1, session2), isTrue);
      expect(session2.totalTurns, 2);
      expect(session2.window.last.messageId, 'm2');

      // The session is keyed by the resolved principal id — the resolvers
      // cohere through it.
      expect(session2.key.principalId, identity2.principalId);

      // Persona reflects each turn's model id independently of identity /
      // session: the named verbose persona on turn 1, the default on turn 2.
      expect(persona1.personaId, 'tom-assistant:verbose');
      expect(persona2, Persona.assistant());
    });

    test('the session handle projection carries the conversation the edge '
        'resolved', () {
      final identity = _identityResolver().resolveTelegramUser(_telegramUserId);
      final sessions = SessionManager();

      final node = sessions.resolve(
        identity: identity,
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'hi', conversationId: 'tg-chat-7'),
      );
      final handle = node.toSessionHandle();

      expect(handle.sessionId, node.sessionId);
      expect(handle.conversationId, 'tg-chat-7');
    });
  });
}
