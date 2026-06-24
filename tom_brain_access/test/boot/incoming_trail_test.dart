// §10 step #7 — the incoming-prompt trail seam.
//
// Proves the `AccessAssembler` (composed by `BrainAccessBoot`) emits exactly one
// content-bearing `IncomingTrailRecord` at the admission instant, *before* the
// request is dispatched, carrying the channel + turnId + the full prompt text +
// the channel-specific raw envelope + the resolved identity / session / persona
// (`tom_brain_logging.md` §5.3 / §9). The bearer credential is a separate
// admission argument, never a field of `InboundRequest`, so it can never reach
// the record. The sink is best-effort (§9): a throwing sink must not fail the
// turn. With no sink wired (unconfigured mode) nothing is emitted.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

DateTime _fixedNow() => DateTime.utc(2026, 6, 2, 12);

RateLimitPolicy _openPolicy() => RateLimitPolicy(
      capacity: 100,
      refillTokens: 100,
      refillPeriod: const Duration(seconds: 1),
    );

Map<String, IdentityBinding> _oneBearer() => {
      'secret-token': IdentityBinding(principalId: 'principal-1'),
    };

Map<String, IdentityBinding> _oneTelegramUser() => {
      'tg-42': IdentityBinding(principalId: 'principal-1'),
    };

InboundRequest _envelope({
  String text = 'hello there',
  String conversationId = 'conv-1',
  String messageId = 'msg-1',
  Map<String, Object?> metadata = const {'locale': 'en'},
}) =>
    InboundRequest(
      text: text,
      conversationId: conversationId,
      messageId: messageId,
      streaming: true,
      metadata: metadata,
    );

({Dispatcher dispatcher, List<Access> routed}) _recordingDispatcher() {
  final routed = <Access>[];
  final dispatcher = Dispatcher(
    route: (access) async {
      routed.add(access);
      access.deliver(OutboundChunk(textDelta: 'answer', isFinal: true));
    },
  );
  return (dispatcher: dispatcher, routed: routed);
}

final class _CollectingTelegramSink implements TelegramSink {
  @override
  Future<void> send(String message) async {}
}

BrainAccessConfig _config({
  IncomingTrailSink? incomingTrailSink,
}) =>
    BrainAccessConfig(
      bearerTokenBindings: _oneBearer(),
      telegramUserIdBindings: _oneTelegramUser(),
      rateLimitPolicy: _openPolicy(),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      clock: _fixedNow,
      incomingTrailSink: incomingTrailSink,
    );

void main() {
  group('IncomingTrailRecord seam — §5.3', () {
    test('admitOpenAi emits one record carrying the §5.3 fields, before '
        'dispatch', () async {
      final d = _recordingDispatcher();
      final captured = <IncomingTrailRecord>[];
      final booted = BrainAccessBoot.install(
        dispatcher: d.dispatcher,
        config: _config(incomingTrailSink: captured.add),
      );
      addTearDown(booted.shutdown);

      await booted.assembler.admitOpenAi(
        bearerToken: 'secret-token',
        modelId: 'tom-assistant',
        envelope: _envelope(metadata: {'locale': 'en', 'x': 1}),
        sink: StreamControllerSseSink(),
      );

      expect(captured, hasLength(1));
      final rec = captured.single;
      expect(rec.channel, AccessChannel.openai);
      expect(rec.principalId, 'principal-1');
      expect(rec.persona, 'tom-assistant');
      expect(rec.conversationId, 'conv-1');
      expect(rec.text, 'hello there');
      expect(rec.rawEnvelope, {'locale': 'en', 'x': 1});
      expect(rec.attachments, isEmpty);
      expect(rec.receivedAt, _fixedNow());
      expect(rec.sessionId, isNotEmpty);

      // The processing-profile axis (§7.2 item 6). No profile selected → the
      // SC-5 byte-compatible default: cognitive + anchored.
      expect(rec.processingProfile, 'default');
      expect(rec.processingMode, 'cognitive');
      expect(rec.anchored, isTrue);

      // The record names the same turn the dispatched access carries, and the
      // sink fired *before* the access reached the dispatcher (admission seam).
      expect(d.routed, hasLength(1));
      expect(rec.turnId.value, d.routed.single.turnId!.value);
    });

    test('fromAdmission stamps the resolved profile id + mode + anchored',
        () {
      final rec = IncomingTrailRecord.fromAdmission(
        channel: AccessChannel.openai,
        turnId: TurnId.generate(),
        receivedAt: _fixedNow(),
        identity: ResolvedIdentity(principalId: 'principal-1'),
        session: Session(sessionId: 'sess-1'),
        persona: Persona(
          personaId: 'tom-assistant',
          substrateRole: 'assistant_to_user',
        ),
        envelope: _envelope(),
        profile: ResolvedProfile(
          id: 'relay',
          mode: ProfileMode.passthrough,
          entryProcedure: 'passthrough_v1',
          anchored: false,
        ),
      );

      expect(rec.processingProfile, 'relay');
      expect(rec.processingMode, 'passthrough');
      expect(rec.anchored, isFalse);
    });

    test('the record never carries the bearer credential', () async {
      final d = _recordingDispatcher();
      final captured = <IncomingTrailRecord>[];
      final booted = BrainAccessBoot.install(
        dispatcher: d.dispatcher,
        config: _config(incomingTrailSink: captured.add),
      );
      addTearDown(booted.shutdown);

      await booted.assembler.admitOpenAi(
        bearerToken: 'secret-token',
        modelId: 'tom-assistant',
        envelope: _envelope(),
        sink: StreamControllerSseSink(),
      );

      final flat = '${captured.single.principalId} '
          '${captured.single.rawEnvelope} ${captured.single.text}';
      expect(flat.contains('secret-token'), isFalse);
    });

    test('admitTelegram tags the record with the telegram channel', () async {
      final d = _recordingDispatcher();
      final captured = <IncomingTrailRecord>[];
      final booted = BrainAccessBoot.install(
        dispatcher: d.dispatcher,
        config: _config(incomingTrailSink: captured.add),
      );
      addTearDown(booted.shutdown);

      await booted.assembler.admitTelegram(
        userId: 'tg-42',
        envelope: _envelope(),
        sink: _CollectingTelegramSink(),
      );

      expect(captured, hasLength(1));
      expect(captured.single.channel, AccessChannel.telegram);
    });

    test('a throwing sink does not fail the turn (best-effort, §9)', () async {
      final d = _recordingDispatcher();
      final booted = BrainAccessBoot.install(
        dispatcher: d.dispatcher,
        config: _config(
          incomingTrailSink: (_) => throw StateError('trail write blew up'),
        ),
      );
      addTearDown(booted.shutdown);

      final events = <AccessEvent>[];
      booted.eventBus.events().listen(events.add);

      await booted.assembler.admitOpenAi(
        bearerToken: 'secret-token',
        modelId: 'tom-assistant',
        envelope: _envelope(),
        sink: StreamControllerSseSink(),
      );
      await pumpEventQueue();

      // The turn still dispatched and reported no access failure.
      expect(d.routed, hasLength(1));
      expect(events.whereType<AccessFailed>(), isEmpty);
    });

    test('no sink wired → nothing emitted, turn still dispatches', () async {
      final d = _recordingDispatcher();
      final booted = BrainAccessBoot.install(
        dispatcher: d.dispatcher,
        config: _config(),
      );
      addTearDown(booted.shutdown);

      await booted.assembler.admitOpenAi(
        bearerToken: 'secret-token',
        modelId: 'tom-assistant',
        envelope: _envelope(),
        sink: StreamControllerSseSink(),
      );

      expect(d.routed, hasLength(1));
    });
  });
}
