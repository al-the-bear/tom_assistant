// Telegram profile commands + active-profile persistence + cross-axis seeding
// (session_configuration.md § 6, plan step 10; decisions SCP-39…SCP-42).
//
// Three layers are proven here, mirroring the shipped active-memory machinery
// (telegram_memory_commands_test.dart):
//
//   * The `TelegramSessionRegistry` profile surface — `/list_profiles`,
//     `/switch_profile`, and `resolveActiveProfile`. Unlike sessions/memory,
//     profiles are **operator config, not user-minted** (§ 6): there is no
//     `/create_profile`. The registry lists the *configured* profile names
//     (an injected provider) and rejects a switch to an unknown one (SC-6).
//     The active selection is stored bare on the same per-user row as the
//     active session/memory (one record, three knobs) and survives a restart.
//
//   * Cross-axis default seeding (SC-Q14, § 6) — a profile carrying
//     `defaultSession`/`defaultMemory` seeds an *unset* (first-contact) active
//     session/memory, while an explicit `/create_session` / `/switch_memory`
//     always wins, surviving restart.
//
//   * The parser — `parseTelegramCommand` recognises the two new words.
//
// The edge-end stamping (that the chat's active profile lands on `Access` and
// that `/switch_profile` changes the next prompt's profile) lives in the
// `TelegramAccessEdge` group below.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart' show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../_support/loopback_chat_api.dart';

void main() {
  group('TelegramSessionRegistry — profile commands (§ 6)', () {
    // The configured profile set an operator declared (not a per-user list).
    List<String> configured() => const <String>['default', 'research', 'relay'];

    TelegramSessionRegistry build({MapEdgeStateStore? store}) =>
        TelegramSessionRegistry(
          store: store ?? MapEdgeStateStore(),
          adoptSession: (_) {},
          configuredProfiles: configured,
        );

    test('first contact resolves to the chat default profile', () {
      final registry = build();
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'default',
      );
      // A chat whose configured defaultProfile is non-default starts there.
      expect(
        registry.resolveActiveProfile('u2', chatDefaultProfile: 'research'),
        'research',
      );
    });

    test('/list_profiles numbers from 000 and marks the active one', () {
      final registry = build();
      final lines = registry
          .listProfiles('u1', chatDefaultProfile: 'default')
          .split('\n');
      expect(lines.first, 'Profiles:');
      // default (active by chat-default), research, relay — in configured order.
      expect(lines[1],
          allOf(startsWith('000'), contains('default'), contains('*')));
      expect(lines[2],
          allOf(startsWith('001'), contains('research'), isNot(contains('*'))));
      expect(lines[3],
          allOf(startsWith('002'), contains('relay'), isNot(contains('*'))));
    });

    test('/switch_profile activates by three-digit index', () {
      final registry = build();
      final reply =
          registry.switchProfile('u1', '001', chatDefaultProfile: 'default');
      expect(reply, 'Now using profile research');
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'research',
      );
    });

    test('/switch_profile activates by name', () {
      final registry = build();
      final reply =
          registry.switchProfile('u1', 'relay', chatDefaultProfile: 'default');
      expect(reply, 'Now using profile relay');
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'relay',
      );
    });

    test('/switch_profile to an unknown name errors, active unchanged (SC-6)',
        () {
      final registry = build();
      registry.switchProfile('u1', 'research', chatDefaultProfile: 'default');
      expect(
        registry.switchProfile('u1', 'absent', chatDefaultProfile: 'default'),
        contains('No profile named'),
      );
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'research',
      );
    });

    test('/switch_profile to an out-of-range index errors, active unchanged',
        () {
      final registry = build();
      registry.switchProfile('u1', 'relay', chatDefaultProfile: 'default');
      expect(
        registry.switchProfile('u1', '099', chatDefaultProfile: 'default'),
        contains('No profile numbered'),
      );
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'relay',
      );
    });

    test('the active profile persists across a restart (new registry)', () {
      final store = MapEdgeStateStore();
      build(store: store)
          .switchProfile('u1', 'research', chatDefaultProfile: 'default');

      final restarted = TelegramSessionRegistry(
        store: store,
        adoptSession: (_) {},
        configuredProfiles: configured,
      );
      expect(
        restarted.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'research',
      );
    });

    test('two users keep independent profile state', () {
      final registry = build();
      registry.switchProfile('u1', 'relay', chatDefaultProfile: 'default');
      expect(
        registry.resolveActiveProfile('u2', chatDefaultProfile: 'default'),
        'default',
      );
      expect(
        registry.resolveActiveProfile('u1', chatDefaultProfile: 'default'),
        'relay',
      );
    });
  });

  group('TelegramSessionRegistry — cross-axis default seeding (§ 6)', () {
    const String sessionPrefix = 'defaultsession_';
    const String memoryPrefix = 'defaultmemory_';

    TelegramSessionRegistry build({MapEdgeStateStore? store}) =>
        TelegramSessionRegistry(
          store: store ?? MapEdgeStateStore(),
          adoptSession: (_) {},
        );

    test("a profile's defaultSession seeds an unset active session", () {
      final registry = build();
      final active = registry.resolveActive(
        'u1',
        sessionPrefix: sessionPrefix,
        profileDefaultSession: 'research',
      );
      expect(active.sessionId, 'defaultsession_research');
      expect(active.activeName, 'research');
    });

    test('an explicit /create_session wins over the seed', () {
      final registry = build();
      registry.createSession('u1', 'work', sessionPrefix: sessionPrefix);
      final active = registry.resolveActive(
        'u1',
        sessionPrefix: sessionPrefix,
        profileDefaultSession: 'research',
      );
      expect(active.sessionId, 'defaultsession_work');
      expect(active.activeName, 'work');
    });

    test("a profile's defaultMemory seeds an unset active memory", () {
      final registry = build();
      expect(
        registry.resolveActiveMemory(
          'u1',
          memoryPrefix: memoryPrefix,
          profileDefaultMemory: 'research',
        ),
        'defaultmemory_research',
      );
    });

    test('an explicit /switch_memory wins over the seed', () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: memoryPrefix);
      expect(
        registry.resolveActiveMemory(
          'u1',
          memoryPrefix: memoryPrefix,
          profileDefaultMemory: 'research',
        ),
        'defaultmemory_work',
      );
    });

    test('no profile default falls through to the first-contact default', () {
      final registry = build();
      expect(
        registry.resolveActive('u1', sessionPrefix: sessionPrefix).activeName,
        'default',
      );
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: memoryPrefix),
        'defaultmemory_default',
      );
    });

    test('the explicit-selection flags survive a restart', () {
      final store = MapEdgeStateStore();
      // Explicitly switch to the *literal default* name — without a persisted
      // explicit flag a restart would wrongly re-seed from the profile default.
      build(store: store)
          .switchMemory('u1', 'default', memoryPrefix: memoryPrefix);

      final restarted = TelegramSessionRegistry(
        store: store,
        adoptSession: (_) {},
      );
      expect(
        restarted.resolveActiveMemory(
          'u1',
          memoryPrefix: memoryPrefix,
          profileDefaultMemory: 'research',
        ),
        'defaultmemory_default',
      );
    });
  });

  group('parseTelegramCommand — profile commands', () {
    test('parses /list_profiles and /switch_profile', () {
      expect(parseTelegramCommand('/list_profiles')!.kind,
          TelegramCommandKind.listProfiles);
      expect(parseTelegramCommand('/switch_profile relay')!.kind,
          TelegramCommandKind.switchProfile);
      expect(parseTelegramCommand('/switch_profile relay')!.argument, 'relay');
      expect(parseTelegramCommand('/switch_profile 001')!.argument, '001');
    });
  });

  group('TelegramAccessEdge — active-profile stamping + seeding (§ 6)', () {
    DateTime fixedNow() => DateTime.utc(2026, 6, 24, 12);

    Map<String, IdentityBinding> oneTelegramUser() => {
          'tg-42': IdentityBinding(principalId: 'principal-1'),
        };

    // An operator profile registry: 'relay' is un-anchored passthrough, and
    // 'seeded' carries a defaultMemory the chat seeds when memory is unset.
    ResolvedProfile profileFor(String? selector) {
      switch (selector) {
        case 'relay':
          return ResolvedProfile(
            id: 'relay',
            mode: ProfileMode.passthrough,
            entryProcedure: 'passthrough_v1',
            role: 'assistant_to_user',
            anchored: false,
          );
        case 'seeded':
          return ResolvedProfile(
            id: 'seeded',
            mode: ProfileMode.cognitive,
            entryProcedure: 'answer_with_memory_v1',
            role: 'assistant_to_user',
            defaultMemory: 'research',
          );
        default:
          return const ResolvedProfile.cognitiveDefault();
      }
    }

    ({Dispatcher dispatcher, List<Access> routed}) answeringDispatcher() {
      final routed = <Access>[];
      final dispatcher = Dispatcher(
        route: (access) async {
          routed.add(access);
          access.deliver(OutboundChunk(textDelta: 'the answer', isFinal: true));
        },
      );
      return (dispatcher: dispatcher, routed: routed);
    }

    InboundRequest inbound({
      String senderId = 'tg-42',
      String text = 'hello there',
      String messageId = 'm1',
    }) =>
        InboundRequest(
          text: text,
          conversationId: 'chat-$senderId',
          messageId: messageId,
          metadata: <String, Object?>{telegramSenderIdMetadataKey: senderId},
        );

    ({
      TelegramAccessEdge edge,
      BootedAccessLayer booted,
      LoopbackChatApi chatApi,
      StreamController<InboundRequest> inbound,
    }) buildEdge({
      required Dispatcher dispatcher,
      ProfileResolver? profileResolver,
      List<String> Function()? configuredProfiles,
      TelegramChatProfileConfig Function(String chatId)? resolveChat,
    }) {
      final booted = BrainAccessBoot.install(
        dispatcher: dispatcher,
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
          profileResolver: profileResolver,
        ),
      );
      final chatApi = LoopbackChatApi();
      final controller = StreamController<InboundRequest>();
      final edge = TelegramAccessEdge(
        assembler: booted.assembler,
        chatApi: chatApi,
        authorizedInbound: controller.stream,
        sessionRegistry: TelegramSessionRegistry(
          store: MapEdgeStateStore(),
          adoptSession: booted.assembler.sessionManager.ensureSession,
          configuredProfiles: configuredProfiles,
        ),
        resolveChat: resolveChat,
      );
      return (edge: edge, booted: booted, chatApi: chatApi, inbound: controller);
    }

    test('an ordinary prompt stamps the default profile onto Access', () async {
      final d = answeringDispatcher();
      final f = buildEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound());
      await pumpEventQueue();

      expect(d.routed, hasLength(1));
      expect(d.routed.single.profile.id, 'default');
    });

    test('/switch_profile over the edge changes the next prompt profile',
        () async {
      final d = answeringDispatcher();
      final f = buildEdge(
        dispatcher: d.dispatcher,
        profileResolver: profileFor,
        configuredProfiles: () => const <String>['default', 'relay'],
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/switch_profile relay', messageId: 's1'));
      await pumpEventQueue();
      f.inbound.add(inbound(text: 'a real prompt', messageId: 'p1'));
      await pumpEventQueue();

      expect(d.routed, hasLength(1)); // the command did not dispatch
      expect(d.routed.single.profile.id, 'relay');
      expect(d.routed.single.profile.anchored, isFalse);
    });

    test("a selected profile's defaultMemory seeds the stamped memory profile",
        () async {
      final d = answeringDispatcher();
      final f = buildEdge(
        dispatcher: d.dispatcher,
        profileResolver: profileFor,
        configuredProfiles: () => const <String>['default', 'seeded'],
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound(text: '/switch_profile seeded', messageId: 's1'));
      await pumpEventQueue();
      f.inbound.add(inbound(text: 'a real prompt', messageId: 'p1'));
      await pumpEventQueue();

      expect(d.routed, hasLength(1));
      expect(d.routed.single.profile.id, 'seeded');
      // The profile's defaultMemory seeded the otherwise-unset active memory.
      expect(d.routed.single.session.memoryProfile, 'defaultmemory_research');
    });
  });
}
