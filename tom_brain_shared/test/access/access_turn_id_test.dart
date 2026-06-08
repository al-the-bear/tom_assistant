// Tests for the optional `Access.turnId` field (logging-spec §3 / §9).
//
// The access edge mints a `turnId` and rides it onto the `Access` so the whole
// turn shares one correlation id. It is optional for the same reason `history`
// is: the dispatcher's own conformance tests build synthetic `Access` objects
// that exercise routing without a turn, so a missing `turnId` is `null`, not an
// error. The assembler always sets it.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        TurnId;

Stream<OutboundChunk> _noDeliver(OutboundChunk chunk) =>
    const Stream<OutboundChunk>.empty();

Access _access({TurnId? turnId}) => Access(
      envelope: InboundRequest(text: 'hello'),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: _noDeliver,
      turnId: turnId,
    );

void main() {
  group('Access.turnId', () {
    test('defaults to null when omitted (synthetic-Access path)', () {
      expect(_access().turnId, isNull);
    });

    test('carries the minted turnId when supplied', () {
      final turnId = TurnId.generate();
      expect(_access(turnId: turnId).turnId, same(turnId));
    });

    test('participates in equality', () {
      final turnId = TurnId.generate();
      Access build(TurnId? id) => Access(
            envelope: InboundRequest(text: 'hello'),
            identity: ResolvedIdentity(principalId: 'p1'),
            session: Session(sessionId: 's1'),
            persona: Persona.assistant(),
            deliver: _noDeliver,
            turnId: id,
          );
      expect(build(turnId), equals(build(turnId)));
      expect(build(turnId), isNot(equals(build(null))));
    });
  });
}
