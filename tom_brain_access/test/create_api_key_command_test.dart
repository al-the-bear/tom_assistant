// `/create_api_key` — the runtime-minted, live-now + durable credential
// (memory_session_profiles.md § 7 / § 13, MSP-7, decisions D-6, MSPP-42…47).
//
// Four layers are proven here, bottom-up:
//
//   * `uuidV4` (D-6) — the key shape: a canonical v4 UUID, unique per call, and
//     crucially `_`-free so it survives the §3.1 marker tokeniser as a clean
//     residual.
//   * `AccessAssembler` as the live [ApiKeyRegistrar] (MSPP-42) — `admit` makes
//     a fresh key *both* authenticate (identity registry) and scope
//     (`apiKeysByKey`) on the next request; `revoke` reverses exactly that, so a
//     failed persist can restore live == disk (§ 13).
//   * `ApiKeyCreator` — the orchestration: no-prefix ⇒ the key value is both
//     prefixes; explicit prefixes verbatim; the secret echoed once; and on a
//     persist failure the live admission is rolled back and the caller told.
//   * `TelegramAccessEdge._handleCreateApiKey` — the both-or-neither parse: 0
//     args ⇒ default prefixes, 2 args ⇒ verbatim, 1 arg ⇒ usage error (creator
//     not called), and the unavailable notice when no creator is wired.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart' show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show InboundRequest, ResolvedIdentity;

import '_support/loopback_chat_api.dart';

/// Records admissions/revocations so the creator's live-half and §13 rollback
/// are observable without a booted assembler.
final class _FakeRegistrar implements ApiKeyRegistrar {
  final List<ApiKeyConfig> admitted = <ApiKeyConfig>[];
  final List<ApiKeyConfig> revoked = <ApiKeyConfig>[];

  @override
  void admit(ApiKeyConfig config) => admitted.add(config);

  @override
  void revoke(ApiKeyConfig config) => revoked.add(config);
}

/// Records the prefixes and pinned default profile the edge passed the creator
/// (so the both-or-neither parse and the `profile=` token are observable) and
/// returns a canned reply.
final class _RecordingCreator implements TelegramApiKeyCreator {
  final List<({String? sessionPrefix, String? memoryPrefix, String? defaultProfile})>
      calls =
      <({String? sessionPrefix, String? memoryPrefix, String? defaultProfile})>[];
  final String reply = 'created-reply';

  @override
  Future<String> createApiKey({
    String? sessionPrefix,
    String? memoryPrefix,
    String? defaultProfile,
  }) async {
    calls.add((
      sessionPrefix: sessionPrefix,
      memoryPrefix: memoryPrefix,
      defaultProfile: defaultProfile,
    ));
    return reply;
  }
}

void main() {
  group('uuidV4 (D-6)', () {
    final RegExp canonical = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    test('is a canonical v4 UUID', () {
      expect(uuidV4(), matches(canonical));
    });

    test('carries no underscore (survives the §3.1 tokeniser)', () {
      for (int i = 0; i < 50; i++) {
        expect(uuidV4(), isNot(contains('_')));
      }
    });

    test('is unique per call', () {
      final Set<String> seen = <String>{};
      for (int i = 0; i < 200; i++) {
        expect(seen.add(uuidV4()), isTrue, reason: 'duplicate UUID generated');
      }
    });
  });

  group('AccessAssembler as ApiKeyRegistrar (MSPP-42)', () {
    BootedAccessLayer boot() => BrainAccessBoot.install(
          dispatcher: Dispatcher(route: (_) async {}),
          config: BrainAccessConfig(
            rateLimitPolicy: RateLimitPolicy(
              capacity: 100,
              refillTokens: 100,
              refillPeriod: const Duration(seconds: 1),
            ),
            dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
            anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
          ),
        );

    test('admit makes the key both authenticate and scope on the next request',
        () async {
      final BootedAccessLayer booted = boot();
      addTearDown(booted.shutdown);
      final AccessAssembler assembler = booted.assembler;

      final ApiKeyConfig config = ApiKeyConfig(
        key: 'fresh-key',
        sessionPrefix: 'fresh-key_',
        memoryPrefix: 'fresh-key_',
      );
      assembler.admit(config);

      // Namespace index gained the key…
      expect(assembler.apiKeysByKey['fresh-key'], same(config));
      // …and the residual key now authenticates to its principal (the key
      // itself, since no `principal` was set — § 5.1).
      final ResolvedIdentity identity =
          assembler.identityResolver.resolveBearer('fresh-key', channel: 'openai');
      expect(identity.principalId, 'fresh-key');
    });

    test('revoke reverses exactly admit (live == disk after a failed persist)',
        () async {
      final BootedAccessLayer booted = boot();
      addTearDown(booted.shutdown);
      final AccessAssembler assembler = booted.assembler;

      final ApiKeyConfig config = ApiKeyConfig(key: 'doomed-key');
      assembler.admit(config);
      assembler.revoke(config);

      expect(assembler.apiKeysByKey.containsKey('doomed-key'), isFalse);
      expect(
        () => assembler.identityResolver
            .resolveBearer('doomed-key', channel: 'openai'),
        throwsA(isA<IdentityResolutionException>()),
      );
    });
  });

  group('ApiKeyCreator orchestration (§ 7 / § 13)', () {
    test('no prefixes ⇒ the key value is both session and memory prefix', () async {
      final _FakeRegistrar registrar = _FakeRegistrar();
      final List<ApiKeyConfig> persisted = <ApiKeyConfig>[];
      final ApiKeyCreator creator = ApiKeyCreator(
        registrar: registrar,
        persist: persisted.add,
        generateKey: () => 'KEY-123',
      );

      final String reply = await creator.createApiKey();

      // Admitted once, persisted once, with the key-derived prefixes.
      expect(registrar.admitted, hasLength(1));
      expect(persisted, hasLength(1));
      final ApiKeyConfig config = registrar.admitted.single;
      expect(config.key, 'KEY-123');
      expect(config.sessionPrefix, 'KEY-123_');
      expect(config.memoryPrefix, 'KEY-123_');
      expect(persisted.single, same(config));
      // The reply echoes the secret once and shows the resolved prefixes.
      expect(reply, contains('KEY-123'));
      expect(reply, contains('session prefix: KEY-123_'));
      expect(reply, contains('memory prefix: KEY-123_'));
      // No rollback on the happy path.
      expect(registrar.revoked, isEmpty);
    });

    test('explicit prefixes are used verbatim', () async {
      final _FakeRegistrar registrar = _FakeRegistrar();
      final List<ApiKeyConfig> persisted = <ApiKeyConfig>[];
      final ApiKeyCreator creator = ApiKeyCreator(
        registrar: registrar,
        persist: persisted.add,
        generateKey: () => 'KEY-456',
      );

      final String reply = await creator.createApiKey(
        sessionPrefix: 'sess_',
        memoryPrefix: 'mem_',
      );

      final ApiKeyConfig config = registrar.admitted.single;
      expect(config.key, 'KEY-456');
      expect(config.sessionPrefix, 'sess_');
      expect(config.memoryPrefix, 'mem_');
      expect(persisted.single, same(config));
      expect(reply, contains('session prefix: sess_'));
      expect(reply, contains('memory prefix: mem_'));
    });

    test('a failed persist rolls the live admission back and says so (§ 13)',
        () async {
      final _FakeRegistrar registrar = _FakeRegistrar();
      final ApiKeyCreator creator = ApiKeyCreator(
        registrar: registrar,
        persist: (_) => throw StateError('disk full'),
        generateKey: () => 'KEY-789',
      );

      final String reply = await creator.createApiKey();

      // Admitted, then revoked with the same config — live == disk restored.
      expect(registrar.admitted, hasLength(1));
      expect(registrar.revoked, hasLength(1));
      expect(registrar.revoked.single, same(registrar.admitted.single));
      // The caller is told it failed, with the reason.
      expect(reply, contains('rolled back'));
      expect(reply, contains('disk full'));
    });

    test('a pinned default profile is set on the config and echoed (I-7)',
        () async {
      final _FakeRegistrar registrar = _FakeRegistrar();
      final List<ApiKeyConfig> persisted = <ApiKeyConfig>[];
      final ApiKeyCreator creator = ApiKeyCreator(
        registrar: registrar,
        persist: persisted.add,
        generateKey: () => 'KEY-PRO',
      );

      final String reply = await creator.createApiKey(defaultProfile: 'fast');

      final ApiKeyConfig config = registrar.admitted.single;
      expect(config.defaultProfile, 'fast');
      expect(persisted.single, same(config));
      expect(reply, contains('default profile: fast'));
    });

    test('no pinned profile ⇒ defaultProfile null, not echoed (SC-5)', () async {
      final _FakeRegistrar registrar = _FakeRegistrar();
      final ApiKeyCreator creator = ApiKeyCreator(
        registrar: registrar,
        persist: (_) {},
        generateKey: () => 'KEY-PLAIN',
      );

      final String reply = await creator.createApiKey();

      expect(registrar.admitted.single.defaultProfile, isNull);
      expect(reply, isNot(contains('default profile')));
    });
  });

  group('TelegramAccessEdge — /create_api_key parse (MSPP-45)', () {
    DateTime fixedNow() => DateTime.utc(2026, 6, 2, 12);

    Map<String, IdentityBinding> oneTelegramUser() => <String, IdentityBinding>{
          'tg-42': IdentityBinding(principalId: 'principal-1'),
        };

    Dispatcher silentDispatcher() => Dispatcher(route: (_) async {});

    InboundRequest inbound({String text = 'hi', String messageId = 'm1'}) =>
        InboundRequest(
          text: text,
          conversationId: 'chat-tg-42',
          messageId: messageId,
          metadata: <String, Object?>{telegramSenderIdMetadataKey: 'tg-42'},
        );

    ({
      TelegramAccessEdge edge,
      BootedAccessLayer booted,
      LoopbackChatApi chatApi,
      StreamController<InboundRequest> inbound,
    }) buildEdge({TelegramInspectors inspectors = TelegramInspectors.none}) {
      final BootedAccessLayer booted = BrainAccessBoot.install(
        dispatcher: silentDispatcher(),
        config: BrainAccessConfig(
          telegramUserIdBindings: oneTelegramUser(),
          rateLimitPolicy: RateLimitPolicy(
            capacity: 100,
            refillTokens: 100,
            refillPeriod: const Duration(seconds: 1),
          ),
          dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
          anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
          clock: fixedNow,
        ),
      );
      final LoopbackChatApi chatApi = LoopbackChatApi();
      final StreamController<InboundRequest> controller =
          StreamController<InboundRequest>();
      final TelegramAccessEdge edge = TelegramAccessEdge(
        assembler: booted.assembler,
        chatApi: chatApi,
        authorizedInbound: controller.stream,
        sessionRegistry: TelegramSessionRegistry(
          store: MapEdgeStateStore(),
          adoptSession: booted.assembler.sessionManager.ensureSession,
        ),
        inspectors: inspectors,
      );
      return (edge: edge, booted: booted, chatApi: chatApi, inbound: controller);
    }

    test('no args ⇒ createApiKey() with default prefixes', () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key'));
      await pumpEventQueue();

      expect(creator.calls, hasLength(1));
      expect(creator.calls.single.sessionPrefix, isNull);
      expect(creator.calls.single.memoryPrefix, isNull);
      expect(f.chatApi.sentMessages, contains('created-reply'));
    });

    test('two args ⇒ createApiKey(sessionPrefix, memoryPrefix) verbatim',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key sess_ mem_'));
      await pumpEventQueue();

      expect(creator.calls, hasLength(1));
      expect(creator.calls.single.sessionPrefix, 'sess_');
      expect(creator.calls.single.memoryPrefix, 'mem_');
    });

    test('one arg ⇒ usage error, creator NOT called (both-or-neither)',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key only_one'));
      await pumpEventQueue();

      expect(creator.calls, isEmpty);
      expect(
        f.chatApi.sentMessages.single,
        allOf(contains('Usage:'), contains('both together')),
      );
    });

    test('no creator wired ⇒ unavailable notice', () async {
      final f = buildEdge();
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key'));
      await pumpEventQueue();

      expect(f.chatApi.sentMessages, contains(telegramInspectorUnavailableMessage));
    });

    test('profile=<name> alone ⇒ default prefixes + pinned profile (I-7)',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key profile=fast'));
      await pumpEventQueue();

      expect(creator.calls, hasLength(1));
      expect(creator.calls.single.sessionPrefix, isNull);
      expect(creator.calls.single.memoryPrefix, isNull);
      expect(creator.calls.single.defaultProfile, 'fast');
    });

    test('profile=<name> composes with two prefixes (I-7)', () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key sess_ mem_ profile=deep'));
      await pumpEventQueue();

      expect(creator.calls, hasLength(1));
      expect(creator.calls.single.sessionPrefix, 'sess_');
      expect(creator.calls.single.memoryPrefix, 'mem_');
      expect(creator.calls.single.defaultProfile, 'deep');
    });

    test('the profile= token may appear before the prefixes (I-7)', () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key profile=deep sess_ mem_'));
      await pumpEventQueue();

      expect(creator.calls, hasLength(1));
      expect(creator.calls.single.sessionPrefix, 'sess_');
      expect(creator.calls.single.memoryPrefix, 'mem_');
      expect(creator.calls.single.defaultProfile, 'deep');
    });

    test('empty profile= name ⇒ usage error, creator NOT called (I-7)',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key profile='));
      await pumpEventQueue();

      expect(creator.calls, isEmpty);
      expect(f.chatApi.sentMessages.single, contains('non-empty profile name'));
    });

    test('two profile= tokens ⇒ usage error, creator NOT called (I-7)',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key profile=a profile=b'));
      await pumpEventQueue();

      expect(creator.calls, isEmpty);
      expect(
        f.chatApi.sentMessages.single,
        contains('at most one profile=<name>'),
      );
    });

    test('one prefix arg with a profile= token is still a usage error (I-7)',
        () async {
      final _RecordingCreator creator = _RecordingCreator();
      final f = buildEdge(
        inspectors: const TelegramInspectors().withApiKeyCreator(creator),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/create_api_key only_one profile=fast'));
      await pumpEventQueue();

      expect(creator.calls, isEmpty);
      expect(
        f.chatApi.sentMessages.single,
        allOf(contains('Usage:'), contains('both together')),
      );
    });
  });
}
