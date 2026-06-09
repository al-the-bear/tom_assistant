// IncomingTrailWriter — the §5.3 raw incoming-prompt trail
// (`tom_brain_logging.md` §10 step #7).
//
// For every admitted inbound request the writer emits one
// `incoming/<channel>/<turnId>.raw.json` carrying the §5.3 fields (turnId,
// channel, receivedAt, principalId, sessionId, conversationId, profile,
// persona, text, attachments, rawEnvelope). Secret-looking `rawEnvelope` keys
// are redacted before serialisation; writes are best-effort (§9).

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessChannel, IncomingTrailRecord;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show TurnId;
import 'package:test/test.dart';

IncomingTrailRecord _record({
  AccessChannel channel = AccessChannel.telegram,
  String turnId = '260608-120831.402355',
  String principalId = 'owner',
  String sessionId = 'sess-1',
  String? conversationId = 'conv-1',
  String? profile = 'default',
  String persona = 'tom-assistant',
  String text = 'And what were the three prompts before?',
  Map<String, Object?> rawEnvelope = const {'locale': 'en'},
}) =>
    IncomingTrailRecord(
      turnId: TurnId.fromString(turnId),
      channel: channel,
      receivedAt: DateTime.utc(2026, 6, 8, 12, 8, 31),
      principalId: principalId,
      sessionId: sessionId,
      conversationId: conversationId,
      profile: profile,
      persona: persona,
      text: text,
      rawEnvelope: rawEnvelope,
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_incoming_trail_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('IncomingTrailWriter — raw §5.3 file', () {
    test('writes incoming/<channel>/<turnId>.raw.json with the §5.3 fields',
        () {
      IncomingTrailWriter(root: root).write(_record());

      final file = File(
        '${root.path}/incoming/telegram/'
        '260608-120831.402355.raw.json',
      );
      expect(file.existsSync(), isTrue,
          reason: 'the §5.3 path is incoming/<channel>/<turnId>.raw.json');

      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json['turnId'], '260608-120831.402355');
      expect(json['channel'], 'telegram');
      expect(json['receivedAt'], '2026-06-08T12:08:31.000Z');
      expect(json['principalId'], 'owner');
      expect(json['sessionId'], 'sess-1');
      expect(json['conversationId'], 'conv-1');
      expect(json['profile'], 'default');
      expect(json['persona'], 'tom-assistant');
      expect(json['text'], 'And what were the three prompts before?');
      expect(json['attachments'], isEmpty);
      expect(json['rawEnvelope'], {'locale': 'en'});
    });

    test('routes each channel to its own sub-folder', () {
      final writer = IncomingTrailWriter(root: root);
      writer.write(_record(channel: AccessChannel.openai));
      writer.write(_record(channel: AccessChannel.anthropic));

      expect(
        File('${root.path}/incoming/openai/'
                '260608-120831.402355.raw.json')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${root.path}/incoming/anthropic/'
                '260608-120831.402355.raw.json')
            .existsSync(),
        isTrue,
      );
    });

    test('omits absent optional fields (conversationId / profile)', () {
      IncomingTrailWriter(root: root)
          .write(_record(conversationId: null, profile: null));

      final file = File(
        '${root.path}/incoming/telegram/'
        '260608-120831.402355.raw.json',
      );
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json.containsKey('conversationId'), isFalse);
      expect(json.containsKey('profile'), isFalse);
    });
  });

  group('IncomingTrailWriter — secret redaction (§5.3)', () {
    test('redacts secret-looking rawEnvelope keys, keeps the rest', () {
      IncomingTrailWriter(root: root).write(
        _record(rawEnvelope: {
          'authorization': 'Bearer sk-live-123',
          'X-Api-Key': 'secret-key',
          'bot_token': '999:abc',
          'cookie': 'session=zzz',
          'locale': 'en',
          'channelMessageId': 42,
        }),
      );

      final file = File(
        '${root.path}/incoming/telegram/'
        '260608-120831.402355.raw.json',
      );
      final raw = file.readAsStringSync();
      expect(raw.contains('sk-live-123'), isFalse);
      expect(raw.contains('secret-key'), isFalse);
      expect(raw.contains('999:abc'), isFalse);
      expect(raw.contains('session=zzz'), isFalse);

      final json = jsonDecode(raw) as Map<String, Object?>;
      final envelope = json['rawEnvelope'] as Map<String, Object?>;
      expect(envelope['authorization'], '[redacted]');
      expect(envelope['X-Api-Key'], '[redacted]');
      expect(envelope['bot_token'], '[redacted]');
      expect(envelope['cookie'], '[redacted]');
      expect(envelope['locale'], 'en');
      expect(envelope['channelMessageId'], 42);
    });
  });

  group('IncomingTrailWriter — best-effort (§9)', () {
    test('a write failure never throws into the caller', () {
      // A file (not a directory) at the trail root makes every mkdir/write
      // under it fail; the writer must swallow it.
      final blocked = File('${root.path}/blocker')..createSync();
      final writer = IncomingTrailWriter(root: Directory(blocked.path));
      expect(() => writer.write(_record()), returnsNormally);
    });
  });
}
