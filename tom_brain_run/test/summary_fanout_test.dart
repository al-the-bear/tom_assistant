// SummaryFanout — the §5.4 / §5.5 / §5.8 versioned narratives derived from the
// same call records the raw `LlmTrailWriter` dumps (`tom_brain_logging.md` §10
// step #5).
//
// One hub fans every completed LLM call out to the two §5.8 projections
// (`by-role`, `by-llm`) and buffers the turn's calls; on each completed turn it
// flushes one §5.4 session block and one §5.5 global block from the buffered
// calls plus the prompt/answer the `TurnSummary` carries. This suite proves the
// four projections' content, their cross-links to the raw dumps, the §8 caps,
// and the §11.1 internal-role gate.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show LlmCallObservation, LlmTrailRecord, TurnSummary;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show CapturedWirePrompt, LlmCallReport;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_summary_fanout_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String read(String relative) =>
      File('${root.path}/$relative').readAsStringSync();

  bool exists(String relative) => File('${root.path}/$relative').existsSync();

  group('SummaryFanout — §5.4 session narrative', () {
    test('a completed turn writes a session block with user, answer, bullets',
        () {
      final fanout = SummaryFanout.rootedAt(root);
      // Two calls of the turn: a recaller (seq 1) then the main answer (seq 3).
      fanout.onCall(_record(
        callType: 'recaller',
        turnId: 'turn_01JZ',
        callSeq: 1,
        answer: 'memory query',
      ));
      fanout.onCall(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 3,
        answer: 'the full answer',
      ));
      fanout.onTurnComplete(_turn(
        turnId: 'turn_01JZ',
        sessionId: 'sess-1',
        userPrompt: 'what were the three prompts before?',
        finalAnswer: 'there are no previous prompts',
      ));

      expect(exists('sessions/sess-1.summary.md'), isTrue,
          reason: 'the §5.4 file is keyed by sessionId only (Q3)');
      final md = read('sessions/sess-1.summary.md');
      expect(md, contains('<!-- tom-brain session summary -->'));
      expect(md, contains('# session sess-1  ·  principal: owner'));
      expect(md, contains('## turn_01JZ'));
      expect(md, contains('·  profile: default'),
          reason: 'a null profile annotates as the process default');
      expect(md, contains('> **User:** what were the three prompts before?'));
      expect(md, contains('**Answer:** there are no previous prompts'));
      // The main call is flagged `main ·` before its role (§5.4 example); the
      // link is root-relative with `../`.
      expect(
          md,
          contains('🧠 main · assistant_to_user · omlx/gemma-4 · 1→1 tok · 5ms '
              '— [raw](../llm/assistant_to_user/turn_01JZ__03.raw.json)'));
      expect(
          md,
          contains(
              '🔎 recaller · omlx/gemma-4 · 1→1 tok · 5ms '
              '— [raw](../llm/recaller/turn_01JZ__01.raw.json)'));
    });

    test('a turn with no answer renders the em dash answer placeholder', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(_turn(
        turnId: 'turn_X',
        sessionId: 'sess-1',
        userPrompt: 'hi',
        finalAnswer: null,
      ));
      expect(read('sessions/sess-1.summary.md'), contains('**Answer:** —'));
    });

    test('a second turn appends below the first (same file)', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(
          _turn(turnId: 'turn_A', sessionId: 'sess-1', userPrompt: 'first'));
      fanout.onTurnComplete(
          _turn(turnId: 'turn_B', sessionId: 'sess-1', userPrompt: 'second'));
      final md = read('sessions/sess-1.summary.md');
      expect(md.indexOf('turn_A'), lessThan(md.indexOf('turn_B')),
          reason: 'turns append in arrival order, oldest at the top');
      expect('---'.allMatches(md), hasLength(2),
          reason: 'one rule per turn block');
    });
  });

  group('SummaryFanout — §5.5 global narrative', () {
    test('every session interleaves into one file, sess id on each header', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(
          _turn(turnId: 'turn_A', sessionId: 'sess-1', userPrompt: 'one'));
      fanout.onTurnComplete(
          _turn(turnId: 'turn_B', sessionId: 'sess-2', userPrompt: 'two'));

      expect(exists('summary/all-sessions.summary.md'), isTrue);
      final md = read('summary/all-sessions.summary.md');
      expect(md, contains('<!-- tom-brain global summary -->'));
      expect(md, contains('## turn_A  '));
      expect(md, contains('session: sess-1  ·  profile: default'),
          reason: 'the §5.5 header carries the sess id, unlike §5.4');
      expect(md, contains('session: sess-2  ·  profile: default'));
    });
  });

  group('SummaryFanout — §5.8 per-role / per-LLM projections', () {
    test('every call lands in by-role/<role> and by-llm/<prov>-<model>', () {
      SummaryFanout.rootedAt(root).onCall(_record(
        callType: 'recaller',
        turnId: 'turn_01JZ',
        callSeq: 1,
        answer: 'a recall answer',
      ));

      expect(exists('summary/by-role/recaller.summary.md'), isTrue);
      final role = read('summary/by-role/recaller.summary.md');
      expect(role, contains('# role recaller'));
      // turn ref · compact prompt · compact answer · link (two hops up).
      expect(role, contains('turn_01JZ__01'));
      expect(role, contains('a recall answer'));
      expect(role,
          contains('[raw](../../llm/recaller/turn_01JZ__01.raw.json)'));

      expect(exists('summary/by-llm/omlx-gemma-4.summary.md'), isTrue);
      final llm = read('summary/by-llm/omlx-gemma-4.summary.md');
      expect(llm, contains('# llm omlx-gemma-4'));
      expect(llm,
          contains('[raw](../../llm/recaller/turn_01JZ__01.raw.json)'));
    });

    test('projections are newest-first', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onCall(_record(
          callType: 'recaller',
          turnId: 'turn_A',
          callSeq: 1,
          answer: 'older'));
      fanout.onCall(_record(
          callType: 'recaller',
          turnId: 'turn_B',
          callSeq: 1,
          answer: 'newer'));
      final md = read('summary/by-role/recaller.summary.md');
      expect(md.indexOf('newer'), lessThan(md.indexOf('older')),
          reason: 'the most recent call is at the top (§5.8 newest-first)');
    });

    test('a turn-less (dream) call still projects but writes no turn block', () {
      SummaryFanout.rootedAt(root).onCall(_record(
        callType: 'connector',
        turnId: null,
        callSeq: null,
        callId: 'c-dream',
        runId: 'dream-run-3',
        answer: 'a dream connection',
      ));
      expect(exists('summary/by-role/connector.summary.md'), isTrue);
      final md = read('summary/by-role/connector.summary.md');
      // A turn-less call's ref falls back to <runId>__<callId>.
      expect(md, contains('dream-run-3__c-dream'));
      expect(Directory('${root.path}/sessions').existsSync(), isFalse,
          reason: 'a dream call has no turn → no session narrative');
    });
  });

  group('SummaryFanout — §8 caps', () {
    test('session turn blocks cap, dropping the oldest from the head', () {
      final fanout = SummaryFanout.rootedAt(root, cap: 2);
      for (final id in <String>['turn_1', 'turn_2', 'turn_3']) {
        fanout.onTurnComplete(
            _turn(turnId: id, sessionId: 'sess-1', userPrompt: id));
      }
      final md = read('sessions/sess-1.summary.md');
      expect(md, isNot(contains('turn_1')),
          reason: 'the oldest block dropped at cap=2');
      expect(md, contains('turn_2'));
      expect(md, contains('turn_3'));
    });

    test('projection entries cap, dropping the oldest from the tail', () {
      final fanout = SummaryFanout.rootedAt(root, cap: 2);
      for (final id in <String>['turn_1', 'turn_2', 'turn_3']) {
        fanout.onCall(_record(
            callType: 'recaller',
            turnId: id,
            callSeq: 1,
            answer: 'ans-$id'));
      }
      final md = read('summary/by-role/recaller.summary.md');
      final entryLines = const LineSplitter()
          .convert(md)
          .where((l) => l.startsWith('- '))
          .toList();
      expect(entryLines, hasLength(2),
          reason: 'two entries kept at cap=2 (the header comment is not one)');
      expect(md, isNot(contains('turn_1')),
          reason: 'newest-first → the oldest entry (turn_1) is the tail drop');
      expect(md, contains('turn_3'));
    });
  });

  group('SummaryFanout — §11.1 internal-role gate', () {
    test('captureInternalRoles=false skips internal calls everywhere', () {
      final fanout =
          SummaryFanout.rootedAt(root, captureInternalRoles: false);
      fanout.onCall(_record(
          callType: 'recaller',
          turnId: 'turn_01JZ',
          callSeq: 1,
          answer: 'internal'));
      fanout.onCall(_record(
          callType: 'assistant_to_user',
          turnId: 'turn_01JZ',
          callSeq: 2,
          answer: 'main'));
      fanout.onTurnComplete(_turn(
          turnId: 'turn_01JZ', sessionId: 'sess-1', userPrompt: 'q'));

      expect(exists('summary/by-role/recaller.summary.md'), isFalse,
          reason: 'an internal role is not projected when the gate is off');
      expect(exists('summary/by-role/assistant_to_user.summary.md'), isTrue);
      final md = read('sessions/sess-1.summary.md');
      expect(md, isNot(contains('recaller')),
          reason: 'the turn block shows only the user-facing call');
      expect(md, contains('🧠 main'));
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

LlmTrailRecord _record({
  required String callType,
  required String? turnId,
  required int? callSeq,
  String callId = 'c1',
  String runId = 'run-7',
  String answer = 'an answer',
}) =>
    LlmTrailRecord(
      observation: LlmCallObservation(
        callType: callType,
        turnId: turnId,
        callSeq: callSeq,
        callId: callId,
        startedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
        wire: const CapturedWirePrompt(
          body: 'ANCHOR_SCAFFOLD\n\nuser question',
          anchorHash: 'sha256:anchor',
          roleId: 'assistant_to_user',
        ),
        answer: answer,
        report: const LlmCallReport(
          providerId: 'omlx',
          modelId: 'gemma-4',
          anchorHash: 'sha256:anchor',
          promptHash: 'sha256:prompt',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 5,
        ),
      ),
      runId: runId,
      trailId: 't_01K',
      sessionId: 'sess-1',
      profile: 'default',
      principalId: 'owner',
    );

TurnSummary _turn({
  required String turnId,
  required String sessionId,
  required String userPrompt,
  String? finalAnswer = 'an answer',
}) =>
    TurnSummary(
      turnId: turnId,
      sessionId: sessionId,
      principalId: 'owner',
      profile: null,
      persona: 'tom-assistant',
      channel: null,
      startedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
      userPrompt: userPrompt,
      finalAnswer: finalAnswer,
    );
