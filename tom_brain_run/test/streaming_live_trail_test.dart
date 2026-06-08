// StreamingLiveTrailWriter — the §5.9 per-session live-trail, written
// step-by-step in the tom-ai `LiveTrailWriter` format (`tom_brain_logging.md`
// §5.9 / §10 step #6).
//
// Unlike the §5.4 summary writer (one block from the turn-complete summary),
// this writer is driven by the four per-step sinks and appends one fragment per
// completed cognitive step, so a file-watcher sees the turn unfold:
//
//   beginPrompt  → `## 🚀 PROMPT <turnId> [<channel> / <profile>]` + `> User:`
//   onLlmCall    → `### 🧠 thinking (<role>)`  (internal) / `### 💬 assistant`
//   onMemoryCall → `### 🔧 <primitive> [<turnId>__<seq>]` + json + 📤 details
//   endPrompt    → `### ✅ DONE (llmCalls=…, memCalls=…, <ms>ms)`
//
// Routing is keyed by `turnId`: the per-step records (`LlmTrailRecord`,
// `MemoryAccessRecord`, `TurnSummary`) carry the turn id as a bare string equal
// to `IncomingTrailRecord.turnId.value`, so the fixtures here use real
// `YYMMDD-HHMMSS.ssssss` ids and thread the same string everywhere.
//
// This suite proves the per-fragment rendering, the streaming order within one
// block, the `turnId → sessionId` routing, the internal-role gate, the last-N
// window, and the turn-less / no-open-block no-ops.

import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart'
    show AccessChannel, IncomingTrailRecord;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show LlmCallObservation, LlmTrailRecord, MemoryAccessRecord, TurnSummary;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show TurnId;
import 'package:tom_brain_substrate/tom_brain_substrate.dart' show LlmCallReport;
import 'package:test/test.dart';

// Real, distinct turn ids (logging-spec §3 timestamp form). Threaded as the
// bare string into the per-step records, and as a `TurnId` into the incoming.
const _t1 = '260608-120831.000001';
const _t2 = '260608-120831.000002';
const _t3 = '260608-120831.000003';
const _ta = '260608-120831.000010';
const _tb = '260608-120831.000011';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_live_trail_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String read(String relative) =>
      File('${root.path}/$relative').readAsStringSync();

  bool exists(String relative) => File('${root.path}/$relative').existsSync();

  group('StreamingLiveTrailWriter — beginPrompt', () {
    test('writes the PROMPT header, channel/profile, and the user line', () {
      StreamingLiveTrailWriter(root: root, turnsKept: 20).beginPrompt(_incoming(
        turnId: _t1,
        sessionId: 'sess-1',
        channel: AccessChannel.telegram,
        profile: 'default',
        text: 'what did we decide about the backup topology?',
      ));

      expect(exists('sessions/sess-1.live-trail.md'), isTrue);
      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('<!-- tom-brain session live-trail -->'));
      expect(md, contains('## 🚀 PROMPT $_t1 [telegram / default]'));
      expect(
          md,
          contains('> User: what did we decide about the backup topology?'));
    });

    test('a null profile renders as default', () {
      StreamingLiveTrailWriter(root: root, turnsKept: 20).beginPrompt(_incoming(
        turnId: _t1,
        sessionId: 'sess-1',
        channel: AccessChannel.openai,
        profile: null,
        text: 'hi',
      ));
      expect(read('sessions/sess-1.live-trail.md'),
          contains('[openai / default]'));
    });
  });

  group('StreamingLiveTrailWriter — onLlmCall', () {
    test('an internal-role call renders as 🧠 thinking (role)', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onLlmCall(
          _llm(turnId: _t1, role: 'recaller', answer: 'I recall the topology.'));

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('### 🧠 thinking (recaller)'));
      expect(md, contains('I recall the topology.'));
    });

    test('the user-facing default role renders as 💬 assistant', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onLlmCall(_llm(
          turnId: _t1,
          role: 'assistant_to_user',
          answer: 'The canonical authority is Big Beast.'));

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('### 💬 assistant'));
      expect(md, contains('The canonical authority is Big Beast.'));
      expect(md, isNot(contains('### 🧠 thinking')),
          reason: 'the user-facing role is not a thinking step');
    });

    test('captureInternalRoles=false suppresses internal calls but keeps the '
        'user-facing one', () {
      final w = StreamingLiveTrailWriter(
          root: root, turnsKept: 20, captureInternalRoles: false);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onLlmCall(_llm(turnId: _t1, role: 'recaller', answer: 'internal'));
      w.onLlmCall(
          _llm(turnId: _t1, role: 'assistant_to_user', answer: 'final'));

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, isNot(contains('🧠 thinking')),
          reason: 'internal roles gated off');
      expect(md, contains('### 💬 assistant'));
      expect(md, contains('final'));
    });

    test('a call with no open turn writes nothing', () {
      StreamingLiveTrailWriter(root: root, turnsKept: 20)
          .onLlmCall(_llm(turnId: _t1, role: 'recaller', answer: 'orphan'));
      expect(exists('sessions/sess-1.live-trail.md'), isFalse);
    });

    test('a turn-less (dream) call writes nothing', () {
      StreamingLiveTrailWriter(root: root, turnsKept: 20)
          .onLlmCall(_llm(turnId: null, role: 'connector', answer: 'dream'));
      final sessions = Directory('${root.path}/sessions');
      expect(sessions.existsSync() && sessions.listSync().isNotEmpty, isFalse);
    });
  });

  group('StreamingLiveTrailWriter — onMemoryCall', () {
    test('renders a 🔧 tool block with json input and a 📤 result details', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onMemoryCall(MemoryAccessRecord(
        primitive: 'recall',
        input: const {'query': 'backup topology', 'k': 8},
        result: const {'nodes': 8, 'degraded': false},
        at: DateTime.utc(2026, 6, 8, 12, 8, 31),
        turnId: _t1,
        profile: 'default',
      ));

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('### 🔧 recall [${_t1}__01]'),
          reason: 'first step of the turn gets seq 01');
      expect(md, contains('```json'));
      expect(md, contains('"query": "backup topology"'));
      expect(md, contains('<details><summary>📤 result'));
      expect(md, contains('"nodes": 8'));
    });
  });

  group('StreamingLiveTrailWriter — endPrompt', () {
    test('writes the DONE banner with the step counts', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onLlmCall(_llm(turnId: _t1, role: 'recaller', answer: 'r'));
      w.onMemoryCall(_mem(turnId: _t1, primitive: 'recall'));
      w.onLlmCall(_llm(turnId: _t1, role: 'assistant_to_user', answer: 'done'));
      w.endPrompt(_turn(turnId: _t1, sessionId: 'sess-1'));

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('### ✅ DONE (llmCalls=2, memCalls=1,'));
      expect(md,
          matches(RegExp(r'### ✅ DONE \(llmCalls=2, memCalls=1, \d+ms\)')));
    });

    test('endPrompt with no open turn is a no-op', () {
      StreamingLiveTrailWriter(root: root, turnsKept: 20)
          .endPrompt(_turn(turnId: _t1, sessionId: 'sess-1'));
      expect(exists('sessions/sess-1.live-trail.md'), isFalse);
    });
  });

  group('StreamingLiveTrailWriter — streaming order + sequencing', () {
    test('a full turn renders thinking → tool → assistant → DONE in order', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(
          _incoming(turnId: _t1, sessionId: 'sess-1', text: 'the question'));
      w.onLlmCall(_llm(turnId: _t1, role: 'recaller', answer: 'reasoning'));
      w.onMemoryCall(_mem(turnId: _t1, primitive: 'recall'));
      w.onLlmCall(
          _llm(turnId: _t1, role: 'assistant_to_user', answer: 'the answer'));
      w.endPrompt(_turn(turnId: _t1, sessionId: 'sess-1'));

      final md = read('sessions/sess-1.live-trail.md');
      final iPrompt = md.indexOf('## 🚀 PROMPT');
      final iThink = md.indexOf('### 🧠 thinking (recaller)');
      final iTool = md.indexOf('### 🔧 recall [${_t1}__02]');
      final iAssistant = md.indexOf('### 💬 assistant');
      final iDone = md.indexOf('### ✅ DONE');
      expect([iPrompt, iThink, iTool, iAssistant, iDone],
          everyElement(greaterThanOrEqualTo(0)));
      expect(iPrompt, lessThan(iThink));
      expect(iThink, lessThan(iTool));
      expect(iTool, lessThan(iAssistant));
      expect(iAssistant, lessThan(iDone));
    });

    test('the step seq covers both call kinds in execution order', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _t1, sessionId: 'sess-1', text: 'q'));
      w.onMemoryCall(_mem(turnId: _t1, primitive: 'recall')); // step 1
      w.onLlmCall(_llm(turnId: _t1, role: 'recaller', answer: 'r')); // step 2
      w.onMemoryCall(_mem(turnId: _t1, primitive: 'persist')); // step 3

      final md = read('sessions/sess-1.live-trail.md');
      expect(md, contains('### 🔧 recall [${_t1}__01]'));
      expect(md, contains('### 🔧 persist [${_t1}__03]'));
    });
  });

  group('StreamingLiveTrailWriter — last-N window', () {
    test('a new prompt past the window drops the oldest block', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 2);
      for (final id in <String>[_t1, _t2, _t3]) {
        w.beginPrompt(_incoming(turnId: id, sessionId: 'sess-1', text: 'p-$id'));
        w.endPrompt(_turn(turnId: id, sessionId: 'sess-1'));
      }
      final md = read('sessions/sess-1.live-trail.md');
      expect(md, isNot(contains('p-$_t1')),
          reason: 'the oldest prompt block dropped at turnsKept=2');
      expect(md, contains('p-$_t2'));
      expect(md, contains('p-$_t3'));
    });
  });

  group('StreamingLiveTrailWriter — routing by turnId → sessionId', () {
    test('per-step records land in the file of their turn\'s session', () {
      final w = StreamingLiveTrailWriter(root: root, turnsKept: 20);
      w.beginPrompt(_incoming(turnId: _ta, sessionId: 'sess-a', text: 'qa'));
      w.beginPrompt(_incoming(turnId: _tb, sessionId: 'sess-b', text: 'qb'));
      w.onLlmCall(_llm(turnId: _ta, role: 'recaller', answer: 'for-a'));
      w.onLlmCall(_llm(turnId: _tb, role: 'recaller', answer: 'for-b'));

      expect(read('sessions/sess-a.live-trail.md'), contains('for-a'));
      expect(read('sessions/sess-a.live-trail.md'), isNot(contains('for-b')));
      expect(read('sessions/sess-b.live-trail.md'), contains('for-b'));
      expect(read('sessions/sess-b.live-trail.md'), isNot(contains('for-a')));
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

IncomingTrailRecord _incoming({
  required String turnId,
  required String sessionId,
  required String text,
  AccessChannel channel = AccessChannel.openai,
  String? profile = 'default',
}) =>
    IncomingTrailRecord(
      turnId: TurnId.fromString(turnId),
      channel: channel,
      receivedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
      principalId: 'owner',
      sessionId: sessionId,
      persona: 'assistant',
      text: text,
      profile: profile,
    );

LlmTrailRecord _llm({
  required String? turnId,
  required String role,
  required String answer,
}) =>
    LlmTrailRecord(
      observation: LlmCallObservation(
        callType: role,
        turnId: turnId,
        callSeq: turnId == null ? null : 1,
        callId: 'c1',
        startedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
        wire: null,
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
      runId: 'run-7',
    );

MemoryAccessRecord _mem({
  required String turnId,
  required String primitive,
}) =>
    MemoryAccessRecord(
      primitive: primitive,
      input: const {'query': 'x'},
      result: const {'ok': true},
      at: DateTime.utc(2026, 6, 8, 12, 8, 31),
      turnId: turnId,
      profile: 'default',
    );

TurnSummary _turn({
  required String turnId,
  required String sessionId,
}) =>
    TurnSummary(
      turnId: turnId,
      sessionId: sessionId,
      principalId: 'owner',
      profile: null,
      persona: 'assistant',
      channel: null,
      startedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
      userPrompt: 'q',
      finalAnswer: 'a',
    );
