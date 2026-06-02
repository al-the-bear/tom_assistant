// Access contract tests (Plan step D.13).
//
// D.13 makes the three `Access` contract points a step of their own:
//
//   1. `Access` construction validation
//   2. the `deliver` callback is actually invoked / streams chunks
//   3. an empty inbound request is rejected
//
// D.11 exercised all three inline against the D.11 code; D.13 hardens them
// into a dedicated, exhaustive suite (the dispatcher entry surface D.14 does
// not exist yet, so there is nothing dispatcher-facing to drive). The cases
// here go past D.11: they pin the value-object reference semantics, the
// `deliver` *backpressure stream* contract (multi-element, empty, and
// error-propagating — the channel E.39 `DeliveryStalled` rides), the lazy
// (construction never calls `deliver`) discipline, and every whitespace
// shape of the empty-inbound rejection.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

/// A trivial deliver callback: echoes the chunk it is handed back as a
/// single-element stream.
Stream<OutboundChunk> _echoDeliver(OutboundChunk chunk) =>
    Stream<OutboundChunk>.value(chunk);

Access _accessWith({
  InboundRequest? envelope,
  ResolvedIdentity? identity,
  Session? session,
  Persona? persona,
  DeliverCallback? deliver,
}) =>
    Access(
      envelope: envelope ?? InboundRequest(text: 'hello'),
      identity: identity ?? ResolvedIdentity(principalId: 'p1'),
      session: session ?? Session(sessionId: 's1'),
      persona: persona ?? Persona.assistant(),
      deliver: deliver ?? _echoDeliver,
    );

void main() {
  // ---------------------------------------------------------------------------
  // D.13 (1) — construction validation
  // ---------------------------------------------------------------------------
  group('D.13 construction validation', () {
    test('carries every field as the exact object handed in (no copy)', () {
      final envelope = InboundRequest(
        text: 'what is the time?',
        kindHint: 'answer_with_memory_v1',
        conversationId: 'c1',
        messageId: 'm1',
        streaming: true,
      );
      final identity = ResolvedIdentity(principalId: 'user-7');
      final session = Session(sessionId: 'sess-7', conversationId: 'c1');
      final persona = Persona.assistant();

      final access = Access(
        envelope: envelope,
        identity: identity,
        session: session,
        persona: persona,
        deliver: _echoDeliver,
      );

      // A value object threads its fields through untouched — reference
      // identity, not just equality, so the dispatcher reads what Phase E
      // produced.
      expect(identical(access.envelope, envelope), isTrue);
      expect(identical(access.identity, identity), isTrue);
      expect(identical(access.session, session), isTrue);
      expect(identical(access.persona, persona), isTrue);
      expect(identical(access.deliver, _echoDeliver), isTrue);
    });

    test('exposes exactly the closed read-surface the dispatcher consumes', () {
      final access = _accessWith(
        envelope: InboundRequest(text: 'go', kindHint: 'k'),
      );
      // envelope.text, envelope.kindHint, persona.substrateRole,
      // identity (opaque), session (opaque), deliver — and nothing the
      // dispatcher is supposed to interpret beyond these.
      expect(access.envelope.text, 'go');
      expect(access.envelope.kindHint, 'k');
      expect(access.persona.substrateRole, 'assistant_to_user');
      expect(access.identity.principalId, 'p1');
      expect(access.session.sessionId, 's1');
      expect(access.deliver, isA<DeliverCallback>());
    });

    test('two Access objects with equal fields + same closure are equal', () {
      final a = _accessWith(deliver: _echoDeliver);
      final b = _accessWith(deliver: _echoDeliver);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differ when any single value field differs', () {
      final base = _accessWith();
      expect(
        base,
        isNot(equals(_accessWith(envelope: InboundRequest(text: 'other')))),
      );
      expect(
        base,
        isNot(equals(_accessWith(identity: ResolvedIdentity(principalId: 'x')))),
      );
      expect(
        base,
        isNot(equals(_accessWith(session: Session(sessionId: 'x')))),
      );
      expect(
        base,
        isNot(equals(_accessWith(
          persona: Persona(personaId: 'p', substrateRole: 'r'),
        ))),
      );
    });

    test('differ when only the deliver closure differs', () {
      Stream<OutboundChunk> other(OutboundChunk c) =>
          Stream<OutboundChunk>.value(c);
      expect(
        _accessWith(deliver: _echoDeliver),
        isNot(equals(_accessWith(deliver: other))),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // D.13 (2) — the deliver callback is invoked and streams chunks
  // ---------------------------------------------------------------------------
  group('D.13 deliver callback invocation', () {
    test('is invoked once per call, in order, with the chunks handed in',
        () async {
      final seen = <OutboundChunk>[];
      Stream<OutboundChunk> recording(OutboundChunk chunk) {
        seen.add(chunk);
        return Stream<OutboundChunk>.value(chunk);
      }

      final access = _accessWith(deliver: recording);
      final c0 = OutboundChunk(textDelta: 'Hel', index: 0);
      final c1 = OutboundChunk(textDelta: 'lo', index: 1);
      final c2 = OutboundChunk(textDelta: '', isFinal: true, index: 2);

      await access.deliver(c0).drain<void>();
      await access.deliver(c1).drain<void>();
      await access.deliver(c2).drain<void>();

      expect(seen, [c0, c1, c2]);
      expect(seen.last.isFinal, isTrue);
    });

    test('the returned backpressure stream may carry multiple chunks',
        () async {
      // The deliver signature returns Stream<OutboundChunk> — the planned
      // backpressure channel. A single deliver call may surface several
      // downstream chunks (e.g. the wire layer re-emitting).
      Stream<OutboundChunk> fanOut(OutboundChunk chunk) => Stream.fromIterable([
            chunk,
            OutboundChunk(textDelta: '${chunk.textDelta}!', isFinal: true),
          ]);

      final access = _accessWith(deliver: fanOut);
      final out = await access
          .deliver(OutboundChunk(textDelta: 'hi'))
          .toList();

      expect(out, hasLength(2));
      expect(out.first.textDelta, 'hi');
      expect(out.last.textDelta, 'hi!');
      expect(out.last.isFinal, isTrue);
    });

    test('an empty backpressure stream is allowed', () async {
      Stream<OutboundChunk> swallow(OutboundChunk _) =>
          const Stream<OutboundChunk>.empty();

      final access = _accessWith(deliver: swallow);
      final out =
          await access.deliver(OutboundChunk(textDelta: 'x')).toList();
      expect(out, isEmpty);
    });

    test('an error in the backpressure stream propagates to the caller',
        () async {
      // E.39 DeliveryStalled rides this channel: a stalled / failed channel
      // surfaces as an error on the returned stream rather than being
      // swallowed, so the engine can yield instead of buffering unbounded.
      Stream<OutboundChunk> failing(OutboundChunk _) =>
          Stream<OutboundChunk>.error(StateError('channel stalled'));

      final access = _accessWith(deliver: failing);
      await expectLater(
        access.deliver(OutboundChunk(textDelta: 'x')).toList(),
        throwsA(isA<StateError>()),
      );
    });

    test('construction never invokes deliver (the callback is lazy)', () {
      var called = false;
      Stream<OutboundChunk> tripwire(OutboundChunk c) {
        called = true;
        return Stream<OutboundChunk>.value(c);
      }

      final access = _accessWith(deliver: tripwire);
      // Building the Access, reading its fields, and stringifying it must
      // not call into the channel.
      expect(access.envelope.text, 'hello');
      access.toString();
      expect(called, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // D.13 (3) — an empty inbound request is rejected
  // ---------------------------------------------------------------------------
  group('D.13 empty inbound request rejection', () {
    test('an empty-string prompt is rejected at envelope construction', () {
      expect(() => InboundRequest(text: ''), throwsArgumentError);
    });

    test('every whitespace-only shape is rejected', () {
      for (final blank in <String>[' ', '\t', '\n', '\r\n', '   \t \n ']) {
        expect(
          () => InboundRequest(text: blank),
          throwsArgumentError,
          reason: 'whitespace-only ${blank.codeUnits} must be rejected',
        );
      }
    });

    test('the ArgumentError names the offending text field and value', () {
      try {
        InboundRequest(text: '   ');
        fail('expected an ArgumentError for whitespace-only text');
      } on ArgumentError catch (e) {
        expect(e.name, 'text');
        expect(e.invalidValue, '   ');
      }
    });

    test('an empty inbound request can never reach an Access', () {
      // The envelope rejects the empty prompt at construction, so the
      // Access constructor never runs with an empty inbound: an empty
      // request cannot reach the dispatcher inside a valid Access.
      expect(
        () => Access(
          envelope: InboundRequest(text: '   \t\n'),
          identity: ResolvedIdentity(principalId: 'p1'),
          session: Session(sessionId: 's1'),
          persona: Persona.assistant(),
          deliver: _echoDeliver,
        ),
        throwsArgumentError,
      );
    });

    test('a single non-whitespace character is accepted (boundary)', () {
      final access = _accessWith(envelope: InboundRequest(text: 'x'));
      expect(access.envelope.text, 'x');
    });

    test('leading/trailing whitespace is preserved when content is present',
        () {
      // Only fully-blank text is rejected; padding around real content is
      // carried verbatim (the adapter, not the value type, decides trimming).
      final access = _accessWith(envelope: InboundRequest(text: '  hi  '));
      expect(access.envelope.text, '  hi  ');
    });
  });
}
