// Conversation-history JSON codec suite (persistence of history, umbrella
// Hard principle 6 — "nothing is ever lost", access spec § 21.10).
//
// Pins the structural `toJson` / `fromJson` codec that lets the access layer's
// `JsonFileHistoryStore` write a session's running history to disk so it
// survives a process restart. The codec is pure (no file I/O — that is the
// store's job); these tests pin only the round-trip fidelity:
//
//   • a turn with no tool round round-trips `toolRound == null` (the `tool`
//     key is omitted, not nulled);
//   • an empty answer (a just-admitted, not-yet-answered turn) survives;
//   • a non-default sizing survives every knob;
//   • a populated history round-trips all four working views (rawWindow,
//     pending, durableRecord, compactedSummary) — the durable record in full,
//     so the "nothing is ever lost" invariant holds across the wire.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Encodes [value] to JSON text and decodes it back, exercising the real
/// `jsonEncode`/`jsonDecode` path the file store uses (catches anything not
/// JSON-encodable, not just map-shape bugs).
Map<String, Object?> _roundTripMap(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

void main() {
  group('HistoryTurn JSON codec', () {
    test('a turn with no tool round omits the tool key and round-trips null',
        () {
      const turn = HistoryTurn(userPrompt: 'hello', brainAnswer: 'hi');
      final json = turn.toJson();
      expect(json.containsKey('tool'), isFalse,
          reason: 'no tool round must not write a tool key');
      final back = HistoryTurn.fromJson(_roundTripMap(json));
      expect(back, turn);
      expect(back.toolRound, isNull);
    });

    test('a turn with a tool round round-trips the tool text', () {
      const turn = HistoryTurn(
        userPrompt: 'q',
        brainAnswer: 'a',
        toolRound: 'called search(...)',
      );
      final back = HistoryTurn.fromJson(_roundTripMap(turn.toJson()));
      expect(back, turn);
      expect(back.toolRound, 'called search(...)');
    });

    test('an empty answer (just-admitted turn) survives the round trip', () {
      const turn = HistoryTurn(userPrompt: 'pending question', brainAnswer: '');
      final back = HistoryTurn.fromJson(_roundTripMap(turn.toJson()));
      expect(back, turn);
      expect(back.brainAnswer, isEmpty);
    });

    test('missing prompt/answer keys read as empty', () {
      final back = HistoryTurn.fromJson(<String, Object?>{});
      expect(back.userPrompt, isEmpty);
      expect(back.brainAnswer, isEmpty);
      expect(back.toolRound, isNull);
    });
  });

  group('HistorySizing JSON codec', () {
    test('a non-default sizing round-trips every knob', () {
      const sizing = HistorySizing(
        rawCount: 6,
        compactionThreshold: 24,
        maxCompactedTokens: 512,
        maxCompactedChars: 3000,
      );
      final back = HistorySizing.fromJson(_roundTripMap(sizing.toJson()));
      expect(back, sizing);
    });

    test('the standard sizing round-trips', () {
      const sizing = HistorySizing.standard();
      final back = HistorySizing.fromJson(_roundTripMap(sizing.toJson()));
      expect(back, sizing);
    });

    test('missing knobs fall back to the documented defaults', () {
      final back = HistorySizing.fromJson(<String, Object?>{});
      expect(back, const HistorySizing.standard());
    });
  });

  group('ConversationHistory JSON codec', () {
    test('a fresh history round-trips to an empty history', () {
      final history = ConversationHistory();
      final back = ConversationHistory.fromJson(_roundTripMap(history.toJson()));
      expect(conversationHistoriesEqual(back, history), isTrue);
      expect(back.rawWindow, isEmpty);
      expect(back.pending, isEmpty);
      expect(back.durableRecord, isEmpty);
      expect(back.compactedSummary, isEmpty);
    });

    test('a populated history round-trips all four working views', () {
      final history = ConversationHistory(
        sizing: const HistorySizing(rawCount: 3),
        compactedSummary: 'older history summarized',
      );
      // Append more than rawCount so some turns spill into pending and the
      // durable record holds every turn.
      for (var i = 0; i < 6; i++) {
        history.append(
          HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i'),
        );
      }
      expect(history.rawWindow.length, 3);
      expect(history.pending.length, 3);
      expect(history.durableRecord.length, 6);

      final back = ConversationHistory.fromJson(_roundTripMap(history.toJson()));

      expect(conversationHistoriesEqual(back, history), isTrue);
      expect(back.sizing, history.sizing);
      expect(back.compactedSummary, 'older history summarized');
      expect(back.rawWindow, history.rawWindow);
      expect(back.pending, history.pending);
      expect(back.durableRecord, history.durableRecord);
    });

    test('a turn with a tool round survives inside a history', () {
      final history = ConversationHistory()
        ..append(const HistoryTurn(
          userPrompt: 'q',
          brainAnswer: 'a',
          toolRound: 'tool ran',
        ));
      final back = ConversationHistory.fromJson(_roundTripMap(history.toJson()));
      expect(back.durableRecord.single.toolRound, 'tool ran');
    });

    test('the restored history shares no mutable state with the source', () {
      final history = ConversationHistory()
        ..append(const HistoryTurn(userPrompt: 'q0', brainAnswer: 'a0'));
      final back = ConversationHistory.fromJson(_roundTripMap(history.toJson()));
      // Mutating the source must not leak into the restored copy.
      history.append(const HistoryTurn(userPrompt: 'q1', brainAnswer: 'a1'));
      expect(back.durableRecord.length, 1);
    });

    test('a missing sizing block falls back to the standard sizing', () {
      final back = ConversationHistory.fromJson(<String, Object?>{
        'compactedSummary': '',
        'rawWindow': <Object?>[],
        'pending': <Object?>[],
        'durableRecord': <Object?>[],
      });
      expect(back.sizing, const HistorySizing.standard());
    });
  });
}
