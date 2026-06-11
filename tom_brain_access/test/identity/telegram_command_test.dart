// The Telegram slash-command vocabulary, its parser, and the `/help` text
// (access spec § 6.5 + the inspection commands).
//
// What is proven:
//   1. `parseTelegramCommand` recognises every command word (session,
//      `/help`, and the five inspection commands) and lifts its argument.
//   2. It strips a `@botname` suffix and is case-insensitive on the word.
//   3. It returns null for an ordinary prompt or an unknown `/word`.
//   4. `telegramHelpText` mentions every command word — so no command can ship
//      undiscoverable.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

void main() {
  group('parseTelegramCommand', () {
    test('parses each session command with its argument', () {
      expect(parseTelegramCommand('/create_session work')!.kind,
          TelegramCommandKind.createSession);
      expect(parseTelegramCommand('/create_session work')!.argument, 'work');
      expect(parseTelegramCommand('/list_sessions')!.kind,
          TelegramCommandKind.listSessions);
      expect(parseTelegramCommand('/pick_session 002')!.kind,
          TelegramCommandKind.pickSession);
      expect(parseTelegramCommand('/pick_session 002')!.argument, '002');
      expect(parseTelegramCommand('/rename_session new name')!.kind,
          TelegramCommandKind.renameSession);
      expect(parseTelegramCommand('/rename_session new name')!.argument,
          'new name');
    });

    test('parses /help and the five inspection commands', () {
      expect(parseTelegramCommand('/help')!.kind, TelegramCommandKind.help);
      expect(parseTelegramCommand('/observatory_show_prompts')!.kind,
          TelegramCommandKind.observatoryShowPrompts);
      expect(parseTelegramCommand('/observatory_analyze_prompt 3')!.kind,
          TelegramCommandKind.observatoryAnalyzePrompt);
      expect(parseTelegramCommand('/observatory_analyze_prompt 3')!.argument,
          '3');
      expect(parseTelegramCommand('/show_logs')!.kind,
          TelegramCommandKind.showLogs);
      expect(parseTelegramCommand('/memory_status')!.kind,
          TelegramCommandKind.memoryStatus);
      expect(parseTelegramCommand('/check_status')!.kind,
          TelegramCommandKind.checkStatus);
    });

    test('strips a @botname suffix and is case-insensitive', () {
      expect(parseTelegramCommand('/list_sessions@tom_brain_bot')!.kind,
          TelegramCommandKind.listSessions);
      expect(parseTelegramCommand('/LIST_SESSIONS')!.kind,
          TelegramCommandKind.listSessions);
      expect(parseTelegramCommand('/HELP@tom_brain_bot')!.kind,
          TelegramCommandKind.help);
    });

    test('returns null for an ordinary prompt or unknown command', () {
      expect(parseTelegramCommand('hello there'), isNull);
      expect(parseTelegramCommand('/unknown_command'), isNull);
      expect(parseTelegramCommand('not a /command'), isNull);
    });
  });

  group('telegramHelpText', () {
    test('mentions every command word with its slash', () {
      final String help = telegramHelpText();
      for (final String word in telegramCommandWords.values) {
        expect(help, contains('/$word'),
            reason: 'help text must list /$word so it is discoverable');
      }
    });
  });
}
