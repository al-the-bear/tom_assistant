// AccessEvent unit tests (Plan step D.12).
//
// Covers the three-variant access-lifecycle observability taxonomy that
// Phase E emits from the edge and the dispatcher / a Forge inspector
// observe off the shared `BrainEvent` base:
//   * AccessCreated   — field carry, `fromAccess` derivation (identity +
//                       persona + envelope, never the prompt text),
//                       accessId-defaults-to-messageId, kind + payload +
//                       toJson shape, UTC assertion via toJson.
//   * AccessDelivered — field carry, negative chunkCount rejection,
//                       kind + payload shape.
//   * AccessFailed    — field carry, empty failureKind rejection, optional
//                       principalId (edge failure before identity),
//                       kind + payload shape.
//   * AccessEvent     — exhaustive `switch` over the sealed sum compiles
//                       and dispatches; nullable runId honoured.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        AccessCreated,
        AccessDelivered,
        AccessEvent,
        AccessFailed,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

Stream<OutboundChunk> _echoDeliver(OutboundChunk chunk) =>
    Stream<OutboundChunk>.value(chunk);

Access _validAccess({
  String text = 'hello',
  String? conversationId,
  String? messageId,
  bool streaming = false,
  String? kindHint,
}) =>
    Access(
      envelope: InboundRequest(
        text: text,
        conversationId: conversationId,
        messageId: messageId,
        streaming: streaming,
        kindHint: kindHint,
      ),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: _echoDeliver,
    );

void main() {
  final ts = DateTime.utc(2026, 6, 2, 12, 0, 0);

  group('AccessCreated', () {
    test('carries every field and exposes the right kind', () {
      final e = AccessCreated(
        occurredAt: ts,
        accessId: 'a1',
        runId: 'r1',
        causedBy: 'ev0',
        principalId: 'p1',
        personaId: 'tom-assistant',
        conversationId: 'c1',
        messageId: 'm1',
        streaming: true,
        kindHint: 'answer_with_memory_v1',
      );

      expect(e.kind, 'access.created');
      expect(e.accessId, 'a1');
      expect(e.runId, 'r1');
      expect(e.causedBy, 'ev0');
      expect(e.principalId, 'p1');
      expect(e.personaId, 'tom-assistant');
      expect(e.conversationId, 'c1');
      expect(e.messageId, 'm1');
      expect(e.streaming, isTrue);
      expect(e.kindHint, 'answer_with_memory_v1');
    });

    test('runId is nullable (event precedes the run)', () {
      final e = AccessCreated(
        occurredAt: ts,
        principalId: 'p1',
        personaId: 'tom-assistant',
        streaming: false,
      );
      expect(e.runId, isNull);
      expect(e.accessId, isNull);
    });

    test('payloadJson omits null optionals and carries the rest', () {
      final e = AccessCreated(
        occurredAt: ts,
        principalId: 'p1',
        personaId: 'tom-assistant',
        streaming: false,
      );
      expect(e.payloadJson(), <String, Object?>{
        'principalId': 'p1',
        'personaId': 'tom-assistant',
        'streaming': false,
      });
    });

    test('toJson composes kind + base fields + payload (UTC enforced)', () {
      final e = AccessCreated(
        occurredAt: ts,
        accessId: 'a1',
        runId: 'r1',
        principalId: 'p1',
        personaId: 'tom-assistant',
        streaming: true,
      );
      final json = e.toJson();
      expect(json['kind'], 'access.created');
      expect(json['occurredAt'], ts.toIso8601String());
      expect(json['runId'], 'r1');
      expect(json.containsKey('causedBy'), isFalse);
      expect(json['payload'], isA<Map<String, Object?>>());
      expect(
        (json['payload'] as Map<String, Object?>)['accessId'],
        'a1',
      );
    });

    test('fromAccess derives identity/persona/envelope, never the text', () {
      final access = _validAccess(
        text: 'a secret prompt body',
        conversationId: 'c9',
        messageId: 'm9',
        streaming: true,
        kindHint: 'hint_v1',
      );
      final e = AccessCreated.fromAccess(access, occurredAt: ts);

      expect(e.principalId, 'p1');
      expect(e.personaId, 'tom-assistant');
      expect(e.conversationId, 'c9');
      expect(e.messageId, 'm9');
      expect(e.streaming, isTrue);
      expect(e.kindHint, 'hint_v1');
      // accessId defaults to the envelope messageId.
      expect(e.accessId, 'm9');
      // The prompt text never leaks into the event payload.
      expect(e.payloadJson().values, isNot(contains('a secret prompt body')));
      expect(e.toString(), isNot(contains('a secret prompt body')));
    });

    test('fromAccess: explicit accessId overrides the messageId default', () {
      final access = _validAccess(messageId: 'm9');
      final e = AccessCreated.fromAccess(
        access,
        occurredAt: ts,
        accessId: 'explicit',
      );
      expect(e.accessId, 'explicit');
    });

    test('fromAccess: no messageId leaves accessId null', () {
      final access = _validAccess();
      final e = AccessCreated.fromAccess(access, occurredAt: ts);
      expect(e.accessId, isNull);
    });
  });

  group('AccessDelivered', () {
    test('carries every field and exposes the right kind', () {
      final e = AccessDelivered(
        occurredAt: ts,
        accessId: 'a1',
        runId: 'r1',
        principalId: 'p1',
        chunkCount: 3,
        conversationId: 'c1',
      );
      expect(e.kind, 'access.delivered');
      expect(e.principalId, 'p1');
      expect(e.chunkCount, 3);
      expect(e.conversationId, 'c1');
      expect(e.payloadJson(), <String, Object?>{
        'accessId': 'a1',
        'principalId': 'p1',
        'chunkCount': 3,
        'conversationId': 'c1',
      });
    });

    test('a zero chunk count is allowed', () {
      expect(
        AccessDelivered(occurredAt: ts, principalId: 'p1', chunkCount: 0)
            .chunkCount,
        0,
      );
    });

    test('a negative chunk count is rejected', () {
      expect(
        () =>
            AccessDelivered(occurredAt: ts, principalId: 'p1', chunkCount: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('payloadJson omits null optionals', () {
      final e =
          AccessDelivered(occurredAt: ts, principalId: 'p1', chunkCount: 1);
      expect(e.payloadJson(), <String, Object?>{
        'principalId': 'p1',
        'chunkCount': 1,
      });
    });
  });

  group('AccessFailed', () {
    test('carries every field and exposes the right kind', () {
      final e = AccessFailed(
        occurredAt: ts,
        accessId: 'a1',
        failureKind: 'access.dispatch.failed',
        message: 'boom',
        principalId: 'p1',
        conversationId: 'c1',
      );
      expect(e.kind, 'access.failed');
      expect(e.failureKind, 'access.dispatch.failed');
      expect(e.message, 'boom');
      expect(e.principalId, 'p1');
      expect(e.payloadJson(), <String, Object?>{
        'accessId': 'a1',
        'failureKind': 'access.dispatch.failed',
        'message': 'boom',
        'principalId': 'p1',
        'conversationId': 'c1',
      });
    });

    test('an empty failureKind is rejected', () {
      expect(
        () => AccessFailed(occurredAt: ts, failureKind: '', message: 'm'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('principalId is optional (edge failure before identity resolves)', () {
      final e = AccessFailed(
        occurredAt: ts,
        failureKind: 'access.auth.rejected',
        message: 'no token',
      );
      expect(e.principalId, isNull);
      expect(e.payloadJson(), <String, Object?>{
        'failureKind': 'access.auth.rejected',
        'message': 'no token',
      });
    });
  });

  group('AccessEvent sealed sum', () {
    test('exhaustive switch dispatches over the three variants', () {
      String describe(AccessEvent e) => switch (e) {
            AccessCreated() => 'created',
            AccessDelivered() => 'delivered',
            AccessFailed() => 'failed',
          };

      expect(
        describe(AccessCreated(
          occurredAt: ts,
          principalId: 'p1',
          personaId: 'tom-assistant',
          streaming: false,
        )),
        'created',
      );
      expect(
        describe(
            AccessDelivered(occurredAt: ts, principalId: 'p1', chunkCount: 1)),
        'delivered',
      );
      expect(
        describe(
            AccessFailed(occurredAt: ts, failureKind: 'x.y', message: 'm')),
        'failed',
      );
    });

    test('all variants share the kebab-case access.<name> kind prefix', () {
      final kinds = <String>[
        AccessCreated(
          occurredAt: ts,
          principalId: 'p1',
          personaId: 'tom-assistant',
          streaming: false,
        ).kind,
        AccessDelivered(occurredAt: ts, principalId: 'p1', chunkCount: 1).kind,
        AccessFailed(occurredAt: ts, failureKind: 'x.y', message: 'm').kind,
      ];
      expect(kinds.every((k) => k.startsWith('access.')), isTrue);
      expect(kinds.toSet().length, 3, reason: 'kinds must be distinct');
    });
  });
}
