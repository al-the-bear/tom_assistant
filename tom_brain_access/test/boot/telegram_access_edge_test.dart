// E.45 — the live Telegram channel edge.
//
// `TelegramAccessEdge` subscribes to the adapter's whitelist-gated
// `authorizedInboundRequests` stream and drives the booted `AccessAssembler`
// (E.41) for each request, recovering the sender id off the inbound metadata
// and addressing the answer / graceful decline through the same `ChatApi`.
// These tests drive the edge with a hand-fed inbound `StreamController` and a
// `LoopbackChatApi`, over a real booted layer wired to a recording dispatcher,
// so the edge's own job — sender recovery, admission, decline-on-failure,
// subscription lifecycle — is exercised with no Telegram network.
//
// What is proven:
//   1. An admitted request dispatches and the answer is sent to the sender.
//   2. A rate-limited request draws the graceful rate-limit decline.
//   3. A request carrying no sender id is dropped (no admit, no send).
//   4. `start` is idempotent; `stop` detaches so later inbound is ignored.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart'
    show ChatApi, ChatMessage, ChatReceiver, ChatResponse, ChatReceiverInfo,
        ChatAttachment, ChatMessageFilter, ChatSettings;

import '../_support/loopback_chat_api.dart';

DateTime _fixedNow() => DateTime.utc(2026, 6, 2, 12);

RateLimitPolicy _openPolicy() => RateLimitPolicy(
      capacity: 100,
      refillTokens: 100,
      refillPeriod: const Duration(seconds: 1),
    );

Map<String, IdentityBinding> _oneTelegramUser() => {
      'tg-42': IdentityBinding(principalId: 'principal-1'),
    };

({Dispatcher dispatcher, List<Access> routed}) _answeringDispatcher() {
  final routed = <Access>[];
  final dispatcher = Dispatcher(
    route: (access) async {
      routed.add(access);
      access.deliver(OutboundChunk(textDelta: 'the answer', isFinal: true));
    },
  );
  return (dispatcher: dispatcher, routed: routed);
}

/// An inbound request as the adapter's mapping would produce it: the sender id
/// rides on `metadata[telegramSenderIdMetadataKey]`.
InboundRequest _inbound({
  String senderId = 'tg-42',
  String text = 'hello there',
  String messageId = 'm1',
  bool withSenderId = true,
}) =>
    InboundRequest(
      text: text,
      conversationId: 'chat-$senderId',
      messageId: messageId,
      metadata: withSenderId
          ? <String, Object?>{telegramSenderIdMetadataKey: senderId}
          : const <String, Object?>{},
    );

({
  TelegramAccessEdge edge,
  BootedAccessLayer booted,
  LoopbackChatApi chatApi,
  StreamController<InboundRequest> inbound,
}) _edge({
  required Dispatcher dispatcher,
  RateLimitPolicy? rateLimitPolicy,
  int dailyCap = 100,
  TelegramSessionRegistry Function(BootedAccessLayer booted)? sessionRegistry,
}) {
  final booted = BrainAccessBoot.install(
    dispatcher: dispatcher,
    config: BrainAccessConfig(
      telegramUserIdBindings: _oneTelegramUser(),
      rateLimitPolicy: rateLimitPolicy ?? _openPolicy(),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: dailyCap),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      clock: _fixedNow,
    ),
  );
  final chatApi = LoopbackChatApi();
  final inbound = StreamController<InboundRequest>();
  final edge = TelegramAccessEdge(
    assembler: booted.assembler,
    chatApi: chatApi,
    authorizedInbound: inbound.stream,
    sessionRegistry: sessionRegistry?.call(booted) ?? _registry(booted),
  );
  return (edge: edge, booted: booted, chatApi: chatApi, inbound: inbound);
}

/// A deterministic, assertable, *valid `TimestampId`-shaped* session id for the
/// n-th mint — `260608-000000.00000N`. Valid-format ids matter: the registry's
/// invalid-session check recreates any active id that does not parse as a
/// `TimestampId` (corruption guard), and the production minter always yields
/// valid ids, so a realistic test minter must too.
String _vid(int n) => '260608-000000.${n.toString().padLeft(6, '0')}';

/// A registry with a deterministic, assertable minter ([_vid] 0, 1, …) for the
/// command / stamping tests that need to name the active id.
TelegramSessionRegistry _deterministicRegistry(BootedAccessLayer booted) {
  var n = 0;
  return TelegramSessionRegistry(
    store: MapEdgeStateStore(),
    mintSessionId: () => _vid(n++),
    adoptSession: booted.assembler.sessionManager.ensureSession,
  );
}

/// A registry over an in-memory store, for the two `announceStartup` cases that
/// build the edge directly (no inbound traffic, so the registry is unused but
/// still required).
TelegramSessionRegistry _registry(BootedAccessLayer booted) =>
    TelegramSessionRegistry(
      store: MapEdgeStateStore(),
      adoptSession: booted.assembler.sessionManager.ensureSession,
    );

void main() {
  group('TelegramAccessEdge', () {
    test('an admitted request dispatches and the answer is sent to the sender',
        () async {
      final d = _answeringDispatcher();
      final f = _edge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(_inbound());
      await pumpEventQueue();

      expect(d.routed, hasLength(1));
      expect(d.routed.single.identity.principalId, 'principal-1');
      expect(f.chatApi.sentMessages, contains('the answer'));
      expect(f.chatApi.sentReceivers.last.value, 'tg-42');
    });

    test(
        'an admitted request first sends the immediate "Processing" ack, then '
        'the answer', () async {
      final d = _answeringDispatcher();
      final f = _edge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(_inbound(text: 'Who are you?'));
      await pumpEventQueue();

      // The ack echoing the prompt precedes the answer (so a slow/failing run
      // never leaves the sender staring at silence), both to the same sender.
      expect(
        f.chatApi.sentMessages,
        equals([
          telegramProcessingAcknowledgement('Who are you?'),
          'the answer',
        ]),
      );
      expect(
        f.chatApi.sentReceivers.map((r) => r.value),
        equals(['tg-42', 'tg-42']),
      );
    });

    test('a rate-limited request draws the graceful rate-limit decline',
        () async {
      final d = _answeringDispatcher();
      final f = _edge(
        dispatcher: d.dispatcher,
        rateLimitPolicy: RateLimitPolicy(
          capacity: 1,
          refillTokens: 1,
          refillPeriod: const Duration(hours: 1),
        ),
      );
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(_inbound(messageId: 'm1'));
      await pumpEventQueue();
      f.inbound.add(_inbound(messageId: 'm2'));
      await pumpEventQueue();

      expect(d.routed, hasLength(1)); // only the first admitted
      expect(f.chatApi.sentMessages.last, telegramRateLimitMessage);
    });

    test('a request carrying no sender id is dropped (no admit, no send)',
        () async {
      final d = _answeringDispatcher();
      final f = _edge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.inbound.add(_inbound(withSenderId: false));
      await pumpEventQueue();

      expect(d.routed, isEmpty);
      expect(f.chatApi.sentMessages, isEmpty);
    });

    test('start is idempotent; stop detaches so later inbound is ignored',
        () async {
      final d = _answeringDispatcher();
      final f = _edge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);
      addTearDown(f.inbound.close);

      f.edge.start();
      f.edge.start(); // no-op
      expect(f.edge.isRunning, isTrue);

      await f.edge.stop();
      expect(f.edge.isRunning, isFalse);

      f.inbound.add(_inbound());
      await pumpEventQueue();
      expect(d.routed, isEmpty);
    });

    group('announceStartup', () {
      test('sends the host-named startup line to each whitelisted owner',
          () async {
        final d = _answeringDispatcher();
        final booted = BrainAccessBoot.install(
          dispatcher: d.dispatcher,
          config: BrainAccessConfig(
            telegramUserIdBindings: _oneTelegramUser(),
            rateLimitPolicy: _openPolicy(),
            dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
            anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
            clock: _fixedNow,
          ),
        );
        addTearDown(booted.shutdown);
        final chatApi = LoopbackChatApi();
        final edge = TelegramAccessEdge(
          assembler: booted.assembler,
          chatApi: chatApi,
          authorizedInbound: const Stream<InboundRequest>.empty(),
          sessionRegistry: _registry(booted),
        );

        await edge.announceStartup(
          recipientUserIds: const ['tg-42', 'tg-99'],
          host: 'bomber',
        );

        final String expected = telegramStartupAnnouncement('bomber');
        expect(expected, contains('bomber'));
        expect(chatApi.sentMessages, equals([expected, expected]));
        expect(
          chatApi.sentReceivers.map((r) => r.value),
          equals(['tg-42', 'tg-99']),
        );
      });

      test('is best-effort: a failing send to one owner still reaches the rest',
          () async {
        final d = _answeringDispatcher();
        final recorder = LoopbackChatApi();
        // The first owner's send throws; the announcement must still reach the
        // second. The edge owns the chatApi, so swap in a partly-failing one.
        final chatApi = _FailingOwnerChatApi(recorder, failFor: 'tg-42');
        final booted = BrainAccessBoot.install(
          dispatcher: d.dispatcher,
          config: BrainAccessConfig(
            telegramUserIdBindings: _oneTelegramUser(),
            rateLimitPolicy: _openPolicy(),
            dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
            anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
            clock: _fixedNow,
          ),
        );
        addTearDown(booted.shutdown);
        final edge = TelegramAccessEdge(
          assembler: booted.assembler,
          chatApi: chatApi,
          authorizedInbound: const Stream<InboundRequest>.empty(),
          sessionRegistry: _registry(booted),
        );

        // Does not throw despite the first recipient failing.
        await edge.announceStartup(
          recipientUserIds: const ['tg-42', 'tg-99'],
          host: 'bomber',
        );

        // Only the second owner's send was recorded (the first threw).
        expect(recorder.sentReceivers.map((r) => r.value), equals(['tg-99']));
        expect(
          recorder.sentMessages,
          equals([telegramStartupAnnouncement('bomber')]),
        );
      });
    });

    group('session commands + active-session stamping (§ 6.5)', () {
      test('an ordinary prompt is stamped with the active session id', () async {
        final d = _answeringDispatcher();
        final f = _edge(
          dispatcher: d.dispatcher,
          sessionRegistry: _deterministicRegistry,
        );
        addTearDown(f.booted.shutdown);
        addTearDown(f.inbound.close);

        f.edge.start();
        f.inbound.add(_inbound(text: 'hello'));
        await pumpEventQueue();

        // First contact silently activates `default` (minted `sess-0`); the
        // dispatched access carries that id — no command reply leaked in.
        expect(d.routed, hasLength(1));
        expect(d.routed.single.session.sessionId, _vid(0));
        expect(f.chatApi.sentMessages, contains('the answer'));
      });

      test('two prompts from one user reach the same dedicated session',
          () async {
        final d = _answeringDispatcher();
        final f = _edge(
          dispatcher: d.dispatcher,
          sessionRegistry: _deterministicRegistry,
        );
        addTearDown(f.booted.shutdown);
        addTearDown(f.inbound.close);

        f.edge.start();
        f.inbound.add(_inbound(text: 'first', messageId: 'm1'));
        await pumpEventQueue();
        f.inbound.add(_inbound(text: 'second', messageId: 'm2'));
        await pumpEventQueue();

        // Continuity: both turns carry the same active id (history builds up).
        expect(
          d.routed.map((a) => a.session.sessionId),
          equals([_vid(0), _vid(0)]),
        );
      });

      test('/create_session is intercepted, acknowledged, never dispatched',
          () async {
        final d = _answeringDispatcher();
        final f = _edge(
          dispatcher: d.dispatcher,
          sessionRegistry: _deterministicRegistry,
        );
        addTearDown(f.booted.shutdown);
        addTearDown(f.inbound.close);

        f.edge.start();
        f.inbound.add(_inbound(text: '/create_session work'));
        await pumpEventQueue();

        // The command never reaches the brain.
        expect(d.routed, isEmpty);
        // It is acknowledged with the exact wording; the minted id is the
        // first-contact default's successor (sess-1, after the silent sess-0).
        expect(
          f.chatApi.sentMessages.single,
          'New session ${_vid(1)} named work created and is in use now',
        );
      });

      test('a prompt after /create_session is stamped with the new session',
          () async {
        final d = _answeringDispatcher();
        final f = _edge(
          dispatcher: d.dispatcher,
          sessionRegistry: _deterministicRegistry,
        );
        addTearDown(f.booted.shutdown);
        addTearDown(f.inbound.close);

        f.edge.start();
        f.inbound.add(_inbound(text: '/create_session work'));
        await pumpEventQueue();
        f.inbound.add(_inbound(text: 'in the new session'));
        await pumpEventQueue();

        expect(d.routed, hasLength(1));
        expect(d.routed.single.session.sessionId, _vid(1));
      });

      test('/list_sessions is intercepted and lists global + default',
          () async {
        final d = _answeringDispatcher();
        final f = _edge(
          dispatcher: d.dispatcher,
          sessionRegistry: _deterministicRegistry,
        );
        addTearDown(f.booted.shutdown);
        addTearDown(f.inbound.close);

        f.edge.start();
        f.inbound.add(_inbound(text: '/list_sessions'));
        await pumpEventQueue();

        expect(d.routed, isEmpty);
        final String reply = f.chatApi.sentMessages.single;
        expect(reply, contains('000'));
        expect(reply, contains('global'));
        expect(reply, contains('default'));
      });
    });

    group('telegramProcessingAcknowledgement', () {
      test('echoes a short prompt whole behind the "Processing:" prefix', () {
        expect(
          telegramProcessingAcknowledgement('Who are you?'),
          'Processing: Who are you?',
        );
      });

      test('truncates a long prompt to its first 200 characters', () {
        final String longPrompt = 'x' * 500;
        final String ack = telegramProcessingAcknowledgement(longPrompt);

        expect(ack, 'Processing: ${'x' * telegramProcessingPreviewLength}');
        // 'Processing: ' (12) + 200 preview chars.
        expect(ack.length, 12 + telegramProcessingPreviewLength);
      });

      test('a prompt exactly at the preview length is echoed whole', () {
        final String exact = 'y' * telegramProcessingPreviewLength;
        expect(telegramProcessingAcknowledgement(exact), 'Processing: $exact');
      });
    });
  });
}

/// A [ChatApi] that throws on a `sendMessage` to one chosen receiver and
/// delegates everything else to an inner [LoopbackChatApi] — used to prove
/// [TelegramAccessEdge.announceStartup] swallows a per-owner send failure and
/// still reaches the remaining owners.
final class _FailingOwnerChatApi implements ChatApi {
  _FailingOwnerChatApi(this._inner, {required String failFor})
      : _failFor = failFor;

  final LoopbackChatApi _inner;
  final String _failFor;

  @override
  Future<ChatMessage> sendMessage(
    ChatReceiver receiver,
    String text, {
    String? parseMode,
  }) {
    if (receiver.value == _failFor) {
      throw StateError('simulated send failure to $_failFor');
    }
    return _inner.sendMessage(receiver, text, parseMode: parseMode);
  }

  @override
  ChatSettings get settings => _inner.settings;
  @override
  set settings(ChatSettings value) => _inner.settings = value;
  @override
  bool get isConnected => _inner.isConnected;
  @override
  String get platform => _inner.platform;
  @override
  Future<void> initialize() => _inner.initialize();
  @override
  Stream<ChatMessage> get onMessage => _inner.onMessage;
  @override
  Future<ChatMessage> send(ChatReceiver receiver, ChatMessage message) =>
      _inner.send(receiver, message);
  @override
  Future<void> disconnect() => _inner.disconnect();
  @override
  Future<ChatResponse> getMessages(
    ChatReceiver receiver, {
    Duration maxWait = const Duration(seconds: 30),
    Duration minWait = Duration.zero,
    Duration interval = const Duration(seconds: 2),
    ChatMessageFilter? filter,
  }) =>
      _inner.getMessages(
        receiver,
        maxWait: maxWait,
        minWait: minWait,
        interval: interval,
        filter: filter,
      );
  @override
  Future<ChatReceiverInfo?> getReceiverInfo(ChatReceiver receiver) =>
      _inner.getReceiverInfo(receiver);
  @override
  Future<List<int>?> downloadAttachment(ChatAttachment attachment) =>
      _inner.downloadAttachment(attachment);
}
