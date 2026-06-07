// Access module unit tests (Plan step D.11).
//
// Covers the value-type contract Phase D (consumer) and Phase E (producer)
// both rely on:
//   * `InboundRequest`     — field carry, empty / whitespace-only rejection,
//                            metadata defensive-copy, value equality.
//   * `OutboundChunk`      — field carry, isFinal / index defaults, negative
//                            index rejection, value equality.
//   * `ResolvedIdentity`   — empty principal rejection, claims defensive
//                            copy, value equality.
//   * `Session`            — empty session-id rejection, value equality.
//   * `Persona`            — empty-field rejection, the `assistant()`
//                            default, value equality.
//   * `Access`             — construction validation, the `deliver` callback
//                            actually streams chunks, empty-inbound
//                            rejection (D.13 intent), and equality /
//                            identity semantics over the function field.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        ConversationHistory,
        DeliverCallback,
        HistoryTurn,
        InboundRequest,
        OutboundChunk,
        Persona,
        PriorTurn,
        RemoteToolDef,
        RemoteToolResult,
        ResolvedIdentity,
        Session;

/// A trivial deliver callback: echoes the chunk it is handed back as a
/// single-element stream. Used wherever a test needs a real
/// [DeliverCallback].
Stream<OutboundChunk> _echoDeliver(OutboundChunk chunk) =>
    Stream<OutboundChunk>.value(chunk);

Access _validAccess({DeliverCallback? deliver}) => Access(
      envelope: InboundRequest(text: 'hello'),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: deliver ?? _echoDeliver,
    );

void main() {
  group('InboundRequest', () {
    test('carries its fields; optionals default sensibly', () {
      final r = InboundRequest(text: 'what is the time?');
      expect(r.text, 'what is the time?');
      expect(r.kindHint, isNull);
      expect(r.conversationId, isNull);
      expect(r.messageId, isNull);
      expect(r.streaming, isFalse);
      expect(r.metadata, isEmpty);
    });

    test('carries all fields when supplied', () {
      final r = InboundRequest(
        text: 'go',
        kindHint: 'answer_with_memory_v1',
        conversationId: 'c1',
        messageId: 'm1',
        streaming: true,
        metadata: {'locale': 'en'},
      );
      expect(r.kindHint, 'answer_with_memory_v1');
      expect(r.conversationId, 'c1');
      expect(r.messageId, 'm1');
      expect(r.streaming, isTrue);
      expect(r.metadata, {'locale': 'en'});
    });

    test('rejects empty text', () {
      expect(() => InboundRequest(text: ''), throwsArgumentError);
    });

    test('rejects whitespace-only text', () {
      expect(() => InboundRequest(text: '   \t\n'), throwsArgumentError);
    });

    test('metadata is an unmodifiable defensive copy', () {
      final source = <String, Object?>{'k': 1};
      final r = InboundRequest(text: 't', metadata: source);
      source['k'] = 2; // mutating the source must not leak in
      expect(r.metadata['k'], 1);
      expect(() => r.metadata['k'] = 9, throwsUnsupportedError);
    });

    test('value equality / hashCode over all fields', () {
      final a = InboundRequest(text: 't', kindHint: 'k', streaming: true);
      final b = InboundRequest(text: 't', kindHint: 'k', streaming: true);
      final c = InboundRequest(text: 't', kindHint: 'k', streaming: false);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('toString previews long prompts and never throws', () {
      final r = InboundRequest(text: 'x' * 200);
      expect(r.toString(), contains('…'));
    });

    // Extension G (G.19): four optional request-fidelity fields.

    test('Extension-G fields default empty/null', () {
      final r = InboundRequest(text: 'hi');
      expect(r.priorTurns, isEmpty);
      expect(r.toolResults, isEmpty);
      expect(r.remoteTools, isEmpty);
      expect(r.sessionId, isNull);
    });

    test('a text-only request is structurally equal to the old shape '
        '(PE-9 regression guard)', () {
      // Two requests built with only `text` — the pre-Extension-G shape —
      // must remain equal and hash equal. The new fields, defaulting to
      // empty/null, contribute nothing to identity for an old caller.
      final oldShape = InboundRequest(text: 'unchanged');
      final alsoOld = InboundRequest(text: 'unchanged');
      expect(oldShape, equals(alsoOld));
      expect(oldShape.hashCode, equals(alsoOld.hashCode));
    });

    test('carries all four Extension-G fields when supplied', () {
      final r = InboundRequest(
        text: 'go',
        priorTurns: [
          PriorTurn(role: 'user', text: 'earlier?'),
          PriorTurn(role: 'assistant', text: 'earlier!'),
        ],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: '42')],
        remoteTools: [RemoteToolDef(name: 'get_weather')],
        sessionId: 'sess-9',
      );
      expect(r.priorTurns, hasLength(2));
      expect(r.priorTurns.first.role, 'user');
      expect(r.toolResults.single.toolCallId, 'c1');
      expect(r.remoteTools.single.name, 'get_weather');
      expect(r.sessionId, 'sess-9');
    });

    test('a request with all four fields round-trips through equality', () {
      InboundRequest build() => InboundRequest(
            text: 'go',
            priorTurns: [PriorTurn(role: 'user', text: 'q')],
            toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'r')],
            remoteTools: [RemoteToolDef(name: 'tool', description: 'd')],
            sessionId: 'sess-1',
          );
      final a = build();
      final b = build();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality when any single Extension-G field differs', () {
      final base = InboundRequest(
        text: 'go',
        priorTurns: [PriorTurn(role: 'user', text: 'q')],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'r')],
        remoteTools: [RemoteToolDef(name: 'tool')],
        sessionId: 'sess-1',
      );
      final diffTurns = InboundRequest(
        text: 'go',
        priorTurns: [PriorTurn(role: 'user', text: 'other')],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'r')],
        remoteTools: [RemoteToolDef(name: 'tool')],
        sessionId: 'sess-1',
      );
      final diffResults = InboundRequest(
        text: 'go',
        priorTurns: [PriorTurn(role: 'user', text: 'q')],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'other')],
        remoteTools: [RemoteToolDef(name: 'tool')],
        sessionId: 'sess-1',
      );
      final diffTools = InboundRequest(
        text: 'go',
        priorTurns: [PriorTurn(role: 'user', text: 'q')],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'r')],
        remoteTools: [RemoteToolDef(name: 'other')],
        sessionId: 'sess-1',
      );
      final diffSession = InboundRequest(
        text: 'go',
        priorTurns: [PriorTurn(role: 'user', text: 'q')],
        toolResults: [RemoteToolResult(toolCallId: 'c1', content: 'r')],
        remoteTools: [RemoteToolDef(name: 'tool')],
        sessionId: 'sess-2',
      );
      expect(base, isNot(equals(diffTurns)));
      expect(base, isNot(equals(diffResults)));
      expect(base, isNot(equals(diffTools)));
      expect(base, isNot(equals(diffSession)));
    });

    test('priorTurns / toolResults / remoteTools are unmodifiable '
        'defensive copies', () {
      final turns = [PriorTurn(role: 'user', text: 'q')];
      final results = [RemoteToolResult(toolCallId: 'c1', content: 'r')];
      final tools = [RemoteToolDef(name: 'tool')];
      final r = InboundRequest(
        text: 'go',
        priorTurns: turns,
        toolResults: results,
        remoteTools: tools,
      );
      // Mutating the sources must not leak in.
      turns.add(PriorTurn(role: 'assistant', text: 'leak'));
      results.add(RemoteToolResult(toolCallId: 'c2', content: 'leak'));
      tools.add(RemoteToolDef(name: 'leak'));
      expect(r.priorTurns, hasLength(1));
      expect(r.toolResults, hasLength(1));
      expect(r.remoteTools, hasLength(1));
      expect(
        () => r.priorTurns.add(PriorTurn(role: 'x', text: 'y')),
        throwsUnsupportedError,
      );
      expect(
        () => r.toolResults.add(RemoteToolResult(toolCallId: 'x', content: 'y')),
        throwsUnsupportedError,
      );
      expect(
        () => r.remoteTools.add(RemoteToolDef(name: 'x')),
        throwsUnsupportedError,
      );
    });
  });

  group('OutboundChunk', () {
    test('carries its fields; defaults isFinal false and index null', () {
      final c = OutboundChunk(textDelta: 'tok');
      expect(c.textDelta, 'tok');
      expect(c.isFinal, isFalse);
      expect(c.index, isNull);
    });

    test('terminator chunk with empty delta is allowed', () {
      final c = OutboundChunk(textDelta: '', isFinal: true);
      expect(c.textDelta, isEmpty);
      expect(c.isFinal, isTrue);
    });

    test('rejects a negative index', () {
      expect(
        () => OutboundChunk(textDelta: 'x', index: -1),
        throwsArgumentError,
      );
    });

    test('value equality / hashCode', () {
      final a = OutboundChunk(textDelta: 'a', isFinal: true, index: 3);
      final b = OutboundChunk(textDelta: 'a', isFinal: true, index: 3);
      final c = OutboundChunk(textDelta: 'a', isFinal: true, index: 4);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('ResolvedIdentity', () {
    test('carries principal id; optionals default', () {
      final id = ResolvedIdentity(principalId: 'user-1');
      expect(id.principalId, 'user-1');
      expect(id.displayName, isNull);
      expect(id.claims, isEmpty);
    });

    test('rejects empty principal id', () {
      expect(
        () => ResolvedIdentity(principalId: ''),
        throwsArgumentError,
      );
    });

    test('claims are an unmodifiable defensive copy', () {
      final source = <String, Object?>{'role': 'admin'};
      final id = ResolvedIdentity(principalId: 'p', claims: source);
      source['role'] = 'guest';
      expect(id.claims['role'], 'admin');
      expect(() => id.claims['x'] = 1, throwsUnsupportedError);
    });

    test('value equality / hashCode', () {
      final a = ResolvedIdentity(principalId: 'p', displayName: 'P');
      final b = ResolvedIdentity(principalId: 'p', displayName: 'P');
      final c = ResolvedIdentity(principalId: 'p', displayName: 'Q');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('Session', () {
    test('carries session id; conversation id optional', () {
      final s = Session(sessionId: 'sess-1');
      expect(s.sessionId, 'sess-1');
      expect(s.conversationId, isNull);
    });

    test('rejects empty session id', () {
      expect(() => Session(sessionId: ''), throwsArgumentError);
    });

    test('value equality / hashCode', () {
      final a = Session(sessionId: 's', conversationId: 'c');
      final b = Session(sessionId: 's', conversationId: 'c');
      final c = Session(sessionId: 's', conversationId: 'd');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('memoryProfile is optional and null by default (Extension H § 4.4)',
        () {
      final s = Session(sessionId: 's1');
      expect(s.memoryProfile, isNull);
    });

    test('memoryProfile carries the pinned profile when set', () {
      final s = Session(sessionId: 's1', memoryProfile: 'work');
      expect(s.memoryProfile, 'work');
    });

    test('memoryProfile participates in equality / hashCode', () {
      final a = Session(sessionId: 's', memoryProfile: 'work');
      final b = Session(sessionId: 's', memoryProfile: 'work');
      final c = Session(sessionId: 's', memoryProfile: 'home');
      final d = Session(sessionId: 's');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('withMemoryProfile stamps a profile without touching identity', () {
      final s = Session(sessionId: 's1', conversationId: 'c1');
      final pinned = s.withMemoryProfile('work');
      expect(pinned.sessionId, 's1');
      expect(pinned.conversationId, 'c1');
      expect(pinned.memoryProfile, 'work');
      // The original is unchanged (immutable copy).
      expect(s.memoryProfile, isNull);
    });

    test('withMemoryProfile(null) clears the profile back to process default',
        () {
      final s = Session(sessionId: 's1', memoryProfile: 'work');
      expect(s.withMemoryProfile(null).memoryProfile, isNull);
    });
  });

  group('Persona', () {
    test('assistant() maps the default persona to assistant_to_user', () {
      final p = Persona.assistant();
      expect(p.personaId, Persona.defaultPersonaId);
      expect(p.substrateRole, Persona.defaultSubstrateRole);
      expect(p.substrateRole, 'assistant_to_user');
    });

    test('rejects empty persona id', () {
      expect(
        () => Persona(personaId: '', substrateRole: 'r'),
        throwsArgumentError,
      );
    });

    test('rejects empty substrate role', () {
      expect(
        () => Persona(personaId: 'p', substrateRole: ''),
        throwsArgumentError,
      );
    });

    test('value equality / hashCode', () {
      final a = Persona(personaId: 'p', substrateRole: 'r');
      final b = Persona(personaId: 'p', substrateRole: 'r');
      final c = Persona(personaId: 'p', substrateRole: 's');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('Access', () {
    test('constructs from valid field objects', () {
      final access = _validAccess();
      expect(access.envelope.text, 'hello');
      expect(access.identity.principalId, 'p1');
      expect(access.session.sessionId, 's1');
      expect(access.persona.substrateRole, 'assistant_to_user');
    });

    test('an empty inbound request is rejected before an Access exists', () {
      // D.13 intent: an empty prompt can never reach the dispatcher inside
      // a valid Access. The envelope rejects it at construction, so the
      // Access can never be built.
      expect(
        () => Access(
          envelope: InboundRequest(text: ''),
          identity: ResolvedIdentity(principalId: 'p1'),
          session: Session(sessionId: 's1'),
          persona: Persona.assistant(),
          deliver: _echoDeliver,
        ),
        throwsArgumentError,
      );
    });

    test('deliver callback streams the chunks it is handed', () async {
      final delivered = <OutboundChunk>[];
      Stream<OutboundChunk> capturing(OutboundChunk chunk) {
        delivered.add(chunk);
        return Stream<OutboundChunk>.value(chunk);
      }

      final access = _validAccess(deliver: capturing);

      final first = OutboundChunk(textDelta: 'Hel', index: 0);
      final last = OutboundChunk(textDelta: 'lo', isFinal: true, index: 1);

      final echoedFirst = await access.deliver(first).first;
      final echoedLast = await access.deliver(last).first;

      expect(delivered, [first, last]);
      expect(echoedFirst, first);
      expect(echoedLast, last);
      expect(echoedLast.isFinal, isTrue);
    });

    test('equality holds for the same closure and equal value fields', () {
      final shared = _echoDeliver;
      final a = _validAccess(deliver: shared);
      final b = _validAccess(deliver: shared);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality when the deliver closure differs', () {
      Stream<OutboundChunk> other(OutboundChunk c) =>
          Stream<OutboundChunk>.value(c);
      final a = _validAccess(deliver: _echoDeliver);
      final b = _validAccess(deliver: other);
      expect(a, isNot(equals(b)));
    });

    test('inequality when a value field differs', () {
      final a = _validAccess();
      final b = Access(
        envelope: InboundRequest(text: 'different'),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: _echoDeliver,
      );
      expect(a, isNot(equals(b)));
    });

    test('toString does not invoke the deliver callback', () {
      var called = false;
      Stream<OutboundChunk> tracking(OutboundChunk c) {
        called = true;
        return Stream<OutboundChunk>.value(c);
      }

      final access = _validAccess(deliver: tracking);
      final s = access.toString();
      expect(s, contains('Access('));
      expect(s, contains('<callback>'));
      expect(called, isFalse);
    });

    // Extension G (step #22): the optional `history` handoff.

    test('history defaults to null when unsupplied', () {
      expect(_validAccess().history, isNull);
    });

    test('carries the supplied history by reference identity', () {
      final history = ConversationHistory()
        ..append(HistoryTurn(userPrompt: 'q', brainAnswer: 'a'));
      final access = Access(
        envelope: InboundRequest(text: 'hello'),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: _echoDeliver,
        history: history,
      );
      expect(identical(access.history, history), isTrue);
      expect(access.toString(), contains('<history>'));
    });

    test('two no-history Accesses remain equal / hash-equal '
        '(PE-9 regression guard)', () {
      final shared = _echoDeliver;
      final a = _validAccess(deliver: shared);
      final b = _validAccess(deliver: shared);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('a history difference breaks equality', () {
      final shared = _echoDeliver;
      final withHistory = Access(
        envelope: InboundRequest(text: 'hello'),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: shared,
        history: ConversationHistory(),
      );
      final without = _validAccess(deliver: shared);
      expect(withHistory, isNot(equals(without)));
    });
  });
}
