// SummaryFanout — the §5.4 / §5.5 / §5.8 versioned narratives derived from the
// same call records the raw `LlmTrailWriter` dumps (`tom_brain_logging.md` §10
// step #5).
//
// One hub fans every completed LLM call out to the two §5.8 per-call projections
// (`by-role`, `by-llm`); on each completed turn it flushes one §5.4 session
// block and one §5.5 global block. Those blocks are now **readable transcripts**
// — the complete user prompt under `### Prompt` and the complete final answer
// under `### Answer`, verbatim — not a list of per-call metadata bullets. This
// suite proves the transcript blocks, the per-call projections, their
// cross-links to the raw dumps, the §8 caps, and the §11.1 internal-role gate.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
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

  group('SummaryFanout — §5.4 session transcript', () {
    test('a completed turn writes the complete prompt and answer verbatim', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(_turn(
        turnId: '260608-120831.402355',
        sessionId: 'sess-1',
        userPrompt: 'what were the three prompts before?',
        finalAnswer: 'There are no previous prompts.\n\nThis is the first thing '
            'you asked.',
      ));

      expect(exists('sessions/sess-1.summary.md'), isTrue,
          reason: 'the §5.4 file is keyed by sessionId only (Q3)');
      final md = read('sessions/sess-1.summary.md');
      expect(md, contains('<!-- tom-brain session summary -->'));
      expect(md, contains('# session sess-1  ·  principal: owner'));
      expect(md, contains('## turn 260608-120831.402355'));
      expect(md, contains('·  profile: default'),
          reason: 'a null profile annotates as the process default');
      expect(md, contains('### Prompt'));
      expect(md, contains('what were the three prompts before?'));
      expect(md, contains('### Answer'));
      // The answer is verbatim, including its internal paragraph break.
      expect(
          md,
          contains('There are no previous prompts.\n\nThis is the first thing '
              'you asked.'));
      // No per-call metadata bullets in the transcript.
      expect(md, isNot(contains('🧠 main')));
      expect(md, isNot(contains('[raw](')));
    });

    test('a turn with no answer renders the no-answer placeholder', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(_turn(
        turnId: 'turn_X',
        sessionId: 'sess-1',
        userPrompt: 'hi',
        finalAnswer: null,
      ));
      expect(read('sessions/sess-1.summary.md'),
          contains('_(no answer — the turn did not complete)_'));
    });

    test('a block whose answer contains a --- rule round-trips intact', () {
      // Regression: the block delimiter must not be a visible `---`, since a
      // verbatim answer legitimately containing one would corrupt the parse.
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(_turn(
          turnId: 'turn_A',
          sessionId: 'sess-1',
          userPrompt: 'one',
          finalAnswer: 'before\n\n---\n\nafter'));
      fanout.onTurnComplete(_turn(
          turnId: 'turn_B',
          sessionId: 'sess-1',
          userPrompt: 'two',
          finalAnswer: 'second answer'));
      final md = read('sessions/sess-1.summary.md');
      // Both turns survive — the `---` inside turn_A's answer did not split it.
      expect(md, contains('## turn turn_A'));
      expect(md, contains('## turn turn_B'));
      expect(md, contains('before\n\n---\n\nafter'));
      expect('## turn '.allMatches(md), hasLength(2),
          reason: 'exactly two turn blocks despite the embedded rule');
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
      expect('## turn '.allMatches(md), hasLength(2),
          reason: 'one transcript block per turn');
    });
  });

  group('SummaryFanout — §5.5 global transcript', () {
    test('every session interleaves into one file, sess id on each header', () {
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(
          _turn(turnId: 'turn_A', sessionId: 'sess-1', userPrompt: 'one'));
      fanout.onTurnComplete(
          _turn(turnId: 'turn_B', sessionId: 'sess-2', userPrompt: 'two'));

      expect(exists('summary/all-sessions.summary.md'), isTrue);
      final md = read('summary/all-sessions.summary.md');
      expect(md, contains('<!-- tom-brain global summary -->'));
      expect(md, contains('## turn turn_A  '));
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

    test('a turn-less (dream) call still projects but writes no transcript', () {
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

  group('SummaryFanout — cross-platform-safe filenames', () {
    test('a colon-bearing llm id never reaches the by-llm filename', () {
      // Regression: a cognition profile id like `claude:haiku:brain` flowed
      // straight into `by-llm/<provider>-<model>.summary.md`, and the colons
      // are reserved on Windows — `git checkout` aborts with `invalid path`,
      // permanently wedging legiondary01's `_ai` clone. The bucket must be
      // sanitized so no reserved character reaches disk.
      SummaryFanout.rootedAt(root).onCall(_record(
        callType: 'brain',
        turnId: 'turn_W',
        callSeq: 1,
        providerId: 'claude:haiku:brain',
        modelId: 'gemma',
        answer: 'sanitized',
      ));

      final byLlm = Directory('${root.path}/summary/by-llm');
      final names = byLlm
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, hasLength(1));
      // The colons collapse to `_`; the `-` provider/model separator survives.
      expect(names.single, 'claude_haiku_brain-gemma.summary.md');
      // No reserved Windows character survives in any trail filename.
      expect(
        RegExp(r'[\\/:*?"<>|]').hasMatch(names.single),
        isFalse,
        reason: 'colons/reserved chars abort git checkout on Windows',
      );
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
    test('captureInternalRoles=false skips internal calls in the projections',
        () {
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
          turnId: 'turn_01JZ',
          sessionId: 'sess-1',
          userPrompt: 'q',
          finalAnswer: 'a'));

      expect(exists('summary/by-role/recaller.summary.md'), isFalse,
          reason: 'an internal role is not projected when the gate is off');
      expect(exists('summary/by-role/assistant_to_user.summary.md'), isTrue);
      // The transcript is unaffected by the gate — it renders the turn's
      // prompt + answer regardless of which internal calls ran.
      final md = read('sessions/sess-1.summary.md');
      expect(md, contains('### Prompt'));
      expect(md, contains('### Answer'));
      expect(md, contains('a'));
    });
  });

  group('SummaryFanout — §5.9 live-trail is no longer its concern', () {
    test('a completed turn writes no live-trail from the fan-out', () {
      // The §5.9 streaming live-trail is now the standalone
      // StreamingLiveTrailWriter, driven by the four per-step sinks — not by the
      // turn-complete summary fan-out. The fan-out writes the §5.4 / §5.5
      // surfaces only.
      final fanout = SummaryFanout.rootedAt(root);
      fanout.onTurnComplete(_turn(
        turnId: '260608-120831.402355',
        sessionId: 'sess-1',
        userPrompt: 'what were the three prompts before?',
        finalAnswer: 'there are no previous prompts',
      ));

      expect(exists('sessions/sess-1.summary.md'), isTrue);
      expect(exists('sessions/sess-1.live-trail.md'), isFalse,
          reason: 'the live-trail is owned by StreamingLiveTrailWriter now');
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
  String providerId = 'omlx',
  String modelId = 'gemma-4',
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
        report: LlmCallReport(
          providerId: providerId,
          modelId: modelId,
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
