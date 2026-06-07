// Conversation-history store acceptance suite (Plan step G.21; hub spec
// § 22.3; access spec § 21.3).
//
// Pins the pure value/store that holds a session's running history:
//
//   • `HistoryTurn`     — one exchange (user prompt + brain answer + optional
//                         tool round), an immutable value.
//   • `HistorySizing`   — the four sizing knobs with their documented
//                         defaults (rawCount 10, compactionThreshold 40,
//                         maxCompactedTokens 1024, maxCompactedChars 6000).
//   • `ConversationHistory` — rawWindow (newest rawCount verbatim) + pending
//                         (older turns behind the window) + compactedSummary,
//                         plus a durable append-only record. Appending past
//                         rawCount evicts the oldest into pending; reaching
//                         compactionThreshold flags `needsCompaction`;
//                         `applyCompaction` rewrites the summary and clears
//                         pending **without** touching the durable record
//                         (Hard principle 6 — derivation, not deletion).
//
// The substrate-call half of compaction lives in `tom_brain_procedure_prototype`
// (engine, access spec § 21.10); this suite is the pure-store half only.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

HistoryTurn _turn(int i) =>
    HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i');

void main() {
  group('G.21-1 HistorySizing defaults', () {
    test('the standard sizing carries the documented defaults', () {
      const sizing = HistorySizing.standard();
      expect(sizing.rawCount, 10);
      expect(sizing.compactionThreshold, 40);
      expect(sizing.maxCompactedTokens, 1024);
      expect(sizing.maxCompactedChars, 6000);
    });

    test('value equality holds over the four knobs', () {
      expect(const HistorySizing.standard(), const HistorySizing());
      expect(
        const HistorySizing(rawCount: 3),
        isNot(const HistorySizing.standard()),
      );
    });
  });

  group('G.21-2 HistoryTurn value', () {
    test('a turn records the prompt, answer, and optional tool round', () {
      final bare = HistoryTurn(userPrompt: 'hi', brainAnswer: 'hello');
      expect(bare.userPrompt, 'hi');
      expect(bare.brainAnswer, 'hello');
      expect(bare.toolRound, isNull);

      final withTool = HistoryTurn(
        userPrompt: 'weather?',
        brainAnswer: 'sunny',
        toolRound: 'get_weather() -> sunny',
      );
      expect(withTool.toolRound, 'get_weather() -> sunny');
    });

    test('value equality holds over the three fields', () {
      expect(
        HistoryTurn(userPrompt: 'q', brainAnswer: 'a'),
        HistoryTurn(userPrompt: 'q', brainAnswer: 'a'),
      );
      expect(
        HistoryTurn(userPrompt: 'q', brainAnswer: 'a', toolRound: 't'),
        isNot(HistoryTurn(userPrompt: 'q', brainAnswer: 'a')),
      );
    });
  });

  group('G.21-3 raw window + pending eviction', () {
    test('appending up to rawCount keeps everything raw, pending empty', () {
      final h = ConversationHistory(
        sizing: const HistorySizing(rawCount: 3, compactionThreshold: 5),
      );
      for (var i = 0; i < 3; i++) {
        h.append(_turn(i));
      }
      expect(h.rawWindow, hasLength(3));
      expect(h.pending, isEmpty);
    });

    test('appending past rawCount evicts the oldest into pending', () {
      final h = ConversationHistory(
        sizing: const HistorySizing(rawCount: 3, compactionThreshold: 5),
      );
      for (var i = 0; i < 5; i++) {
        h.append(_turn(i));
      }
      // The newest 3 stay raw; the oldest 2 spilled into pending in order.
      expect(h.rawWindow, [_turn(2), _turn(3), _turn(4)]);
      expect(h.pending, [_turn(0), _turn(1)]);
    });

    test('the durable record keeps every appended turn', () {
      final h = ConversationHistory(
        sizing: const HistorySizing(rawCount: 2, compactionThreshold: 10),
      );
      for (var i = 0; i < 6; i++) {
        h.append(_turn(i));
      }
      expect(h.durableRecord, [for (var i = 0; i < 6; i++) _turn(i)]);
    });
  });

  group('G.21-4 needsCompaction threshold', () {
    test('needsCompaction flips only once pending reaches the threshold', () {
      const sizing = HistorySizing(rawCount: 2, compactionThreshold: 3);
      final h = ConversationHistory(sizing: sizing);
      // rawCount + compactionThreshold turns put exactly threshold in pending.
      for (var i = 0; i < sizing.rawCount + sizing.compactionThreshold - 1; i++) {
        h.append(_turn(i));
        expect(h.needsCompaction, isFalse, reason: 'turn $i');
      }
      h.append(_turn(99));
      expect(h.pending, hasLength(sizing.compactionThreshold));
      expect(h.needsCompaction, isTrue);
    });
  });

  group('G.21-5 applyCompaction is derivation, not deletion', () {
    test('applyCompaction rewrites the summary and clears pending only', () {
      const sizing = HistorySizing(rawCount: 2, compactionThreshold: 3);
      final h = ConversationHistory(sizing: sizing);
      for (var i = 0; i < 5; i++) {
        h.append(_turn(i));
      }
      final rawBefore = h.rawWindow;
      final recordBefore = h.durableRecord;
      expect(h.pending, hasLength(3));

      h.applyCompaction('a distilled summary of turns 0..2');

      expect(h.compactedSummary, 'a distilled summary of turns 0..2');
      expect(h.pending, isEmpty);
      // Derivation, not deletion: raw window and the durable record survive.
      expect(h.rawWindow, rawBefore);
      expect(h.durableRecord, recordBefore);
      expect(h.durableRecord, hasLength(5));
    });

    test('a fresh history starts with an empty compacted summary', () {
      final h = ConversationHistory();
      expect(h.compactedSummary, isEmpty);
      expect(h.rawWindow, isEmpty);
      expect(h.pending, isEmpty);
      expect(h.durableRecord, isEmpty);
      expect(h.sizing, const HistorySizing.standard());
    });
  });

  group('G.21-6 read views are unmodifiable', () {
    test('rawWindow / pending / durableRecord cannot be mutated by callers', () {
      final h = ConversationHistory(
        sizing: const HistorySizing(rawCount: 1, compactionThreshold: 5),
      );
      h.append(_turn(0));
      h.append(_turn(1));
      expect(() => h.rawWindow.add(_turn(2)), throwsUnsupportedError);
      expect(() => h.pending.add(_turn(2)), throwsUnsupportedError);
      expect(() => h.durableRecord.add(_turn(2)), throwsUnsupportedError);
    });
  });
}
