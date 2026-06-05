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
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
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
  );
  return (edge: edge, booted: booted, chatApi: chatApi, inbound: inbound);
}

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
