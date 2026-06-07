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
//   * Session (E.25 / Ext-G) resolves the conversation against two histories: a
//     per-(principal, channel) global "all prompts" history every request
//     appends to, and a per-session history keyed by a brain-minted id. A
//     sessionless request mints a fresh id and answers from the global; an
//     echoed known id answers from its dedicated history; the channel splits
//     one person into two globals (§ 7.2).
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

  group('E.27 / Ext-G — session resolution across calls', () {
    test('repeated sessionless calls mint distinct ids but the global history '
        'accumulates both (§ 7.2)', () {
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

      // The brain owns the id space — each sessionless turn mints a fresh id.
      expect(second.sessionId, isNot(first.sessionId));
      expect(first.mintedNewId, isTrue);
      expect(second.mintedNewId, isTrue);
      // Both turns landed in the one global "all prompts" history.
      final global = sessions.peekGlobal(
        principalId: identity.principalId,
        channel: AccessChannel.openai,
      );
      expect(
        [for (final t in global!.durableRecord) t.userPrompt],
        ['hello', 'again'],
      );
    });

    test('an echoed minted id answers from the dedicated per-session history',
        () {
      final identity = _identityResolver().resolveOpenAiBearer(_bearerToken);
      final sessions = SessionManager();

      final minted = sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'first', conversationId: 'c1'),
      );
      final attached = sessions.resolve(
        identity: identity,
        channel: AccessChannel.openai,
        envelope: InboundRequest(
          text: 'second',
          conversationId: 'c1',
          sessionId: minted.sessionId,
        ),
      );

      expect(attached.mintedNewId, isFalse);
      expect(attached.unknownSessionId, isFalse);
      expect(attached.sessionId, minted.sessionId);
      expect(
        [for (final t in attached.history.durableRecord) t.userPrompt],
        ['second'],
      );
    });

    test('the same person on a different channel is a different global history',
        () {
      final resolver = _identityResolver();
      final openAiIdentity = resolver.resolveOpenAiBearer(_bearerToken);
      final telegramIdentity = resolver.resolveTelegramUser(_telegramUserId);
      final sessions = SessionManager();

      sessions.resolve(
        identity: openAiIdentity,
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'over openai', conversationId: 'shared'),
      );
      sessions.resolve(
        identity: telegramIdentity,
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'over telegram', conversationId: 'shared'),
      );

      // Same principal id — but the channel splits the global histories.
      expect(openAiIdentity.principalId, telegramIdentity.principalId);
      final openAiGlobal = sessions.peekGlobal(
        principalId: openAiIdentity.principalId,
        channel: AccessChannel.openai,
      );
      final telegramGlobal = sessions.peekGlobal(
        principalId: telegramIdentity.principalId,
        channel: AccessChannel.telegram,
      );
      expect(identical(openAiGlobal, telegramGlobal), isFalse);
      expect(
        [for (final t in openAiGlobal!.durableRecord) t.userPrompt],
        ['over openai'],
      );
      expect(
        [for (final t in telegramGlobal!.durableRecord) t.userPrompt],
        ['over telegram'],
      );
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
        'dedicated history accumulates turns', () {
      final identityResolver = _identityResolver();
      final sessions = SessionManager();
      final personas = PersonaResolver();

      // Turn 1 — sessionless; the caller names a persona model id. The brain
      // mints a fresh session id and answers from the global history.
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

      // Turn 2 — same person, echoing turn 1's minted id, no model id named.
      final identity2 = identityResolver.resolveOpenAiBearer(_bearerToken);
      final session2 = sessions.resolve(
        identity: identity2,
        channel: AccessChannel.openai,
        envelope: InboundRequest(
          text: 'turn two',
          conversationId: 'thread-1',
          messageId: 'm2',
          sessionId: session1.sessionId,
        ),
      );
      final persona2 = personas.resolve(null);

      // Identity is stable across the two turns (same person).
      expect(identity1, identity2);
      expect(identity2.principalId, _principalId);

      // Turn 2 resolved the dedicated history turn 1 minted (a known id).
      expect(session2.mintedNewId, isFalse);
      expect(session2.sessionId, session1.sessionId);
      expect(
        [for (final t in session2.history.durableRecord) t.userPrompt],
        ['turn two'],
      );

      // The global history accumulates every prompt of the person + channel —
      // the resolvers cohere through the resolved principal id.
      final global = sessions.peekGlobal(
        principalId: identity2.principalId,
        channel: AccessChannel.openai,
      );
      expect(
        [for (final t in global!.durableRecord) t.userPrompt],
        ['turn one', 'turn two'],
      );

      // Persona reflects each turn's model id independently of identity /
      // session: the named verbose persona on turn 1, the default on turn 2.
      expect(persona1.personaId, 'tom-assistant:verbose');
      expect(persona2, Persona.assistant());
    });

    test('the resolved session handle carries the conversation the edge '
        'resolved', () {
      final identity = _identityResolver().resolveTelegramUser(_telegramUserId);
      final sessions = SessionManager();

      final res = sessions.resolve(
        identity: identity,
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'hi', conversationId: 'tg-chat-7'),
      );

      expect(res.session.sessionId, res.sessionId);
      expect(res.session.conversationId, 'tg-chat-7');
    });
  });
}
