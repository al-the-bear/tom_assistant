// Telegram memory commands + active-memory persistence + stamping
// (memory_session_profiles.md § 9.2, plan step 10; MSPP-32…36).
//
// Two layers are proven here:
//
//   * The `TelegramSessionRegistry` memory surface — `/create_memory`,
//     `/list_memory`, `/switch_memory`, and `resolveActiveMemory` — all scoped
//     to the chat's `memoryPrefix` (MSP-6). The registry stores **bare** names
//     and applies the prefix per call (MSPP-33), so one registry serves chats
//     with different namespaces, and the active selection survives a restart
//     (a fresh registry over the same store).
//
//   * The `TelegramAccessEdge` end of the wire — that the chat's active memory
//     profile is stamped onto the `Access` the dispatcher receives, that the
//     three commands resolve within the chat's prefix scope, and that a
//     `/switch_memory` changes the profile stamped on the next prompt.
//
// What is proven (registry):
//   1. First contact starts on `default`; `resolveActiveMemory` prefixes it.
//   2. `/create_memory` registers + activates a bare name and acknowledges with
//      the prefixed id; a `_`-bearing / path-unsafe name is rejected (MSP-6).
//   3. `/list_memory` numbers from 000, marks the active one, and renders each
//      as `prefix + name` (every listed profile is in scope).
//   4. `/switch_memory` activates by index or by name, rejecting an
//      out-of-range index, an unknown name, and an out-of-scope (`_`) argument.
//   5. The active memory persists across a restart.
//   6. Two users keep independent memory state.
//   7. The same registry serves two chats with different prefixes.
//
// What is proven (edge):
//   8. An ordinary prompt stamps the chat's active memory profile onto Access —
//      the default chat resolves `defaultmemory_default`.
//   9. A configured chat's prefix scopes the stamped profile.
//  10. `/switch_memory` over the edge changes the profile stamped next prompt.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart' show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '_support/loopback_chat_api.dart';

void main() {
  group('TelegramSessionRegistry — memory commands (§ 9.2)', () {
    // The default chat namespace (an unconfigured chat): `defaultmemory_`.
    const String prefix = 'defaultmemory_';

    TelegramSessionRegistry build({MapEdgeStateStore? store}) =>
        TelegramSessionRegistry(
          store: store ?? MapEdgeStateStore(),
          mintSessionId: () => '260608-000000.000000',
          adoptSession: (_) {},
        );

    test('first contact starts on default; resolveActiveMemory prefixes it', () {
      final registry = build();
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_default',
      );
    });

    test('/create_memory registers, activates, and acknowledges the prefixed id',
        () {
      final registry = build();
      final reply =
          registry.createMemory('u1', 'work', memoryPrefix: prefix);
      expect(
        reply,
        'New memory defaultmemory_work named work created and is in use now',
      );
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_work',
      );
    });

    test('/create_memory rejects an out-of-scope (_ / path) name (MSP-6)', () {
      final registry = build();
      expect(
        registry.createMemory('u1', 'other_default', memoryPrefix: prefix),
        contains('Invalid memory name'),
      );
      expect(
        registry.createMemory('u1', '../escape', memoryPrefix: prefix),
        contains('Invalid memory name'),
      );
      // Neither was created — the active memory is still the default.
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_default',
      );
    });

    test('/list_memory numbers from 000, marks active, renders prefixed ids', () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: prefix); // active = work
      final lines =
          registry.listMemory('u1', memoryPrefix: prefix).split('\n');
      expect(lines.first, 'Memories:');
      // 000 default, 001 work — work is active and every line carries the prefix.
      expect(lines[1], allOf(startsWith('000'), contains('default'),
          contains('defaultmemory_default'), isNot(contains('*'))));
      expect(lines[2], allOf(startsWith('001'), contains('work'),
          contains('defaultmemory_work'), contains('*')));
    });

    test('/switch_memory activates by three-digit index', () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: prefix); // active = work
      final reply = registry.switchMemory('u1', '000', memoryPrefix: prefix);
      expect(reply, 'Now using memory default (defaultmemory_default)');
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_default',
      );
    });

    test('/switch_memory activates by name', () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: prefix);
      registry.switchMemory('u1', '000', memoryPrefix: prefix); // → default
      final reply = registry.switchMemory('u1', 'work', memoryPrefix: prefix);
      expect(reply, 'Now using memory work (defaultmemory_work)');
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_work',
      );
    });

    test('/switch_memory rejects out-of-range index, unknown name, and _ arg',
        () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: prefix);
      expect(registry.switchMemory('u1', '099', memoryPrefix: prefix),
          contains('No memory numbered'));
      expect(registry.switchMemory('u1', 'absent', memoryPrefix: prefix),
          contains('No memory named'));
      expect(registry.switchMemory('u1', 'other_default', memoryPrefix: prefix),
          contains('Out-of-scope memory'));
      // The active memory is unchanged by any rejected switch.
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_work',
      );
    });

    test('active memory persists across a restart (new registry, same store)',
        () {
      final store = MapEdgeStateStore();
      build(store: store).createMemory('u1', 'work', memoryPrefix: prefix);

      final restarted = TelegramSessionRegistry(
        store: store,
        mintSessionId: () => fail('restart must not mint a fresh id'),
        adoptSession: (_) {},
      );
      expect(
        restarted.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_work',
      );
      // The list survived too.
      expect(restarted.listMemory('u1', memoryPrefix: prefix), contains('work'));
    });

    test('two users keep independent memory state', () {
      final registry = build();
      registry.createMemory('u1', 'work', memoryPrefix: prefix);
      // u2 never created anything — still on the default.
      expect(
        registry.resolveActiveMemory('u2', memoryPrefix: prefix),
        'defaultmemory_default',
      );
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: prefix),
        'defaultmemory_work',
      );
    });

    test('the same registry serves two chats with different prefixes (MSPP-33)',
        () {
      final registry = build();
      // The same bare active name renders under whatever prefix the chat carries.
      registry.createMemory('u1', 'work', memoryPrefix: 'team_');
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: 'team_'),
        'team_work',
      );
      expect(
        registry.resolveActiveMemory('u1', memoryPrefix: 'project_'),
        'project_work',
      );
    });
  });

  group('TelegramAccessEdge — active-memory stamping (§ 9.2)', () {
    DateTime fixedNow() => DateTime.utc(2026, 6, 2, 12);

    Map<String, IdentityBinding> oneTelegramUser() => {
          'tg-42': IdentityBinding(principalId: 'principal-1'),
        };

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
        ),
        resolveChat: resolveChat,
      );
      return (edge: edge, booted: booted, chatApi: chatApi, inbound: controller);
    }

    test('an ordinary prompt stamps the default chat memory profile onto Access',
        () async {
      final d = answeringDispatcher();
      final f = buildEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound());
      await pumpEventQueue();

      expect(d.routed, hasLength(1));
      expect(d.routed.single.session.memoryProfile, 'defaultmemory_default');
    });

    test('a configured chat prefix scopes the stamped profile', () async {
      final d = answeringDispatcher();
      final f = buildEdge(
        dispatcher: d.dispatcher,
        resolveChat: (chatId) =>
            TelegramChatProfileConfig(chatId: chatId, memoryPrefix: 'team_'),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(inbound());
      await pumpEventQueue();

      expect(d.routed.single.session.memoryProfile, 'team_default');
    });

    test('/switch_memory over the edge changes the next prompt stamp', () async {
      final d = answeringDispatcher();
      final f = buildEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      // Create a second profile, then a prompt: it is stamped with the new one.
      f.inbound.add(inbound(text: '/create_memory work', messageId: 'c1'));
      await pumpEventQueue();
      f.inbound.add(inbound(text: 'a real prompt', messageId: 'p1'));
      await pumpEventQueue();

      expect(d.routed, hasLength(1)); // the command did not dispatch
      expect(d.routed.single.session.memoryProfile, 'defaultmemory_work');

      // Switch back to the default and prompt again.
      f.inbound.add(inbound(text: '/switch_memory 000', messageId: 's1'));
      await pumpEventQueue();
      f.inbound.add(inbound(text: 'another prompt', messageId: 'p2'));
      await pumpEventQueue();

      expect(d.routed, hasLength(2));
      expect(d.routed.last.session.memoryProfile, 'defaultmemory_default');
    });
  });
}
