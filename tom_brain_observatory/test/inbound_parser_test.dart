// PT-1.1 — the §5.3 incoming-prompt parser surfaces the processing-profile axis
// (`session_configuration.md` §7.2 item 6): the brain's incoming raw dump now
// carries `processingProfile` + `processingMode` + `anchored` alongside the
// memory `profile`, and the Observatory `Inbound` projection surfaces them so the
// prompt trace can show which profile/mode produced an answer and whether it was
// anchored (§7.1 auditability).

import 'dart:convert';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

String _incomingJson({
  String processingProfile = 'research',
  String processingMode = 'cognitive',
  bool anchored = true,
  String memoryProfile = 'work',
}) =>
    jsonEncode(<String, Object?>{
      'turnId': '260608-120831.402355',
      'channel': 'openai',
      'receivedAt': '2026-06-08T12:08:31.000Z',
      'principalId': 'owner',
      'sessionId': 'sess-1',
      'profile': memoryProfile,
      'processingProfile': processingProfile,
      'processingMode': processingMode,
      'anchored': anchored,
      'persona': 'tom-assistant',
      'text': 'hello',
      'attachments': <Object?>[],
      'rawEnvelope': <String, Object?>{'locale': 'en'},
    });

void main() {
  group('parseInbound — processing-profile axis (§7.2 item 6)', () {
    test('surfaces processingProfile + processingMode + anchored, parallel to '
        'the memory profile', () {
      final inbound = parseInbound(_incomingJson())!;

      expect(inbound.processingProfile, 'research');
      expect(inbound.processingMode, 'cognitive');
      expect(inbound.anchored, isTrue);
      // The memory profile remains its own distinct label.
      expect(inbound.profile, 'work');
    });

    test('an un-anchored run is visibly flagged anchored:false (§7.1)', () {
      final inbound = parseInbound(_incomingJson(
        processingProfile: 'relay',
        processingMode: 'passthrough',
        anchored: false,
      ))!;

      expect(inbound.anchored, isFalse);
      expect(inbound.processingProfile, 'relay');
      expect(inbound.processingMode, 'passthrough');
    });

    test('toJson round-trips the three fields', () {
      final json = parseInbound(_incomingJson(anchored: false))!.toJson();

      expect(json['processingProfile'], 'research');
      expect(json['processingMode'], 'cognitive');
      expect(json['anchored'], isFalse);
    });

    test('an older dump without the fields degrades to the SC-5 default '
        '(cognitive, anchored)', () {
      final legacy = jsonEncode(<String, Object?>{
        'turnId': '260101-120000.000001',
        'channel': 'openai',
        'principalId': 'u',
        'sessionId': 's',
        'persona': 'p',
        'text': 't',
      });

      final inbound = parseInbound(legacy)!;
      expect(inbound.processingProfile, 'default');
      expect(inbound.processingMode, 'cognitive');
      expect(inbound.anchored, isTrue);
    });
  });
}
