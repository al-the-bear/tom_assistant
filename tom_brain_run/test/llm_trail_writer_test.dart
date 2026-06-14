// LlmTrailWriter — the §5.2 raw LLM-call trail + the §5.1 `↳` link
// (`tom_brain_logging.md` §10 step #4).
//
// For every LLM call the writer emits one
// `llm/<callType>/<turnId>__<callSeq>.raw.json` carrying the full wire body
// (the anchor scaffold the provider saw), the answer, and the call's
// provenance/metrics; and it emits one compact `brain.log` headline ending in
// `↳ <relative-path>` so an operator reading the high-level log can drill to
// the raw dump. Summary fan-out (§5.4/§5.5/§5.8) is step #5 — *not* this writer.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late List<String> headlines;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_llm_trail_');
    headlines = <String>[];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LlmTrailWriter buildWriter({
    bool captureWireBody = true,
    bool captureInternalRoles = true,
  }) =>
      LlmTrailWriter(
        root: root,
        captureWireBody: captureWireBody,
        captureInternalRoles: captureInternalRoles,
        headlineSink: headlines.add,
      );

  group('LlmTrailWriter — raw §5.2 file', () {
    test('writes llm/<role>/<turn>__<seq>.raw.json with the wire body', () {
      buildWriter().write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
      ));

      final file =
          File('${root.path}/llm/assistant_to_user/turn_01JZ__01.raw.json');
      expect(file.existsSync(), isTrue,
          reason: 'the §5.2 path is llm/<callType>/<turnId>__<callSeq>');

      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json['turnId'], 'turn_01JZ');
      expect(json['callSeq'], 1);
      expect(json['callType'], 'assistant_to_user');
      expect(json['runId'], 'disp-fg-run-7');
      expect(json['trailId'], 't_01K');
      expect(json['provider'], 'omlx');
      expect(json['model'], 'gemma-4');
      expect(json['tokensIn'], 174);
      expect(json['tokensOut'], 24);
      expect(json['wallClockMs'], 1298);
      expect(json['anchorHash'], 'sha256:anchor');
      expect(json['promptHash'], 'sha256:prompt');
      expect(json['answer'], 'the full answer');

      // The wire body — the closure of this step (gap #3): the full anchor
      // scaffold is captured, not just hashed.
      final wire = json['wire'] as Map<String, Object?>;
      final messages = wire['messages'] as List<Object?>;
      expect(messages, hasLength(1),
          reason: 'a single assembled body → one message (spec §5.2 '
              'reconciliation: WirePrompt is one anchor-first string)');
      final message = messages.single as Map<String, Object?>;
      expect(message['content'], 'ANCHOR_SCAFFOLD\n\nuser question');
    });

    test('emits a brain.log headline ending in the ↳ link to the raw file', () {
      buildWriter().write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
      ));

      expect(headlines, hasLength(1));
      final line = headlines.single;
      // §5.1 compact form: llm <role> <provider>/<model> <in>→<out> tok <ms>ms.
      expect(line, contains('llm assistant_to_user'));
      expect(line, contains('omlx/gemma-4'));
      expect(line, contains('174→24 tok'));
      expect(line, contains('1298ms'));
      // The link convention: a path relative to the trail root.
      expect(line, contains('↳ llm/assistant_to_user/turn_01JZ__01.raw.json'));
    });

    test('carries the call\'s generation settings (temperature/max/stops)', () {
      buildWriter().write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
        options: const LlmOptions(
          temperature: 0.35,
          maxOutputTokens: 512,
          stopSequences: <String>['STOP', '###'],
        ),
      ));

      final file =
          File('${root.path}/llm/assistant_to_user/turn_01JZ__01.raw.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json['temperature'], 0.35);
      expect(json['maxOutputTokens'], 512);
      expect(json['stopSequences'], <String>['STOP', '###']);
    });

    test('omits stopSequences when none are set; null knobs stay null', () {
      buildWriter().write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
      ));

      final file =
          File('${root.path}/llm/assistant_to_user/turn_01JZ__01.raw.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json.containsKey('stopSequences'), isFalse,
          reason: 'an empty stop set is omitted, not serialised as []');
      expect(json['temperature'], isNull);
      expect(json['maxOutputTokens'], isNull);
    });

    test('a turn-less call falls back to <runId>__<callId> for the stem', () {
      buildWriter().write(_record(
        callType: 'analyser',
        turnId: null,
        callSeq: null,
        callId: 'call-abc',
        runId: 'dream-run-3',
      ));

      final file =
          File('${root.path}/llm/analyser/dream-run-3__call-abc.raw.json');
      expect(file.existsSync(), isTrue,
          reason: 'turn-less internal/dream calls have no turnId/callSeq');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json['turnId'], isNull);
      expect(json['callSeq'], isNull);
    });
  });

  group('LlmTrailWriter — capture gates (§11)', () {
    test('captureWireBody=false omits the wire block but still writes', () {
      buildWriter(captureWireBody: false).write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
      ));

      final file =
          File('${root.path}/llm/assistant_to_user/turn_01JZ__01.raw.json');
      expect(file.existsSync(), isTrue);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json.containsKey('wire'), isFalse,
          reason: 'the §8 capture.wireBody=false gate suppresses the body');
      // The metrics are still there — only the body is gated.
      expect(json['tokensIn'], 174);
    });

    test('captureInternalRoles=false skips a non-user-facing role entirely', () {
      buildWriter(captureInternalRoles: false).write(_record(
        callType: 'analyser',
        turnId: 'turn_01JZ',
        callSeq: 2,
      ));

      expect(Directory('${root.path}/llm').existsSync(), isFalse,
          reason: 'an internal role is not trailed when the gate is off');
      expect(headlines, isEmpty);
    });

    test('captureInternalRoles=false still trails the user-facing role', () {
      buildWriter(captureInternalRoles: false).write(_record(
        callType: 'assistant_to_user',
        turnId: 'turn_01JZ',
        callSeq: 1,
      ));

      expect(
        File('${root.path}/llm/assistant_to_user/turn_01JZ__01.raw.json')
            .existsSync(),
        isTrue,
      );
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

LlmTrailRecord _record({
  required String callType,
  required String? turnId,
  required int? callSeq,
  String callId = 'c1',
  String runId = 'disp-fg-run-7',
  LlmOptions options = LlmOptions.empty,
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
        answer: 'the full answer',
        report: const LlmCallReport(
          providerId: 'omlx',
          modelId: 'gemma-4',
          anchorHash: 'sha256:anchor',
          promptHash: 'sha256:prompt',
          tokensIn: 174,
          tokensOut: 24,
          retries: 0,
          wallClockMs: 1298,
        ),
        options: options,
      ),
      runId: runId,
      trailId: 't_01K',
      sessionId: 'sess-1',
      profile: 'default',
      principalId: 'owner',
    );
