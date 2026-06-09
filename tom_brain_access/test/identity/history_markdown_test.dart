// Readable-markdown mirror of conversation histories (access spec § 21.10;
// request "make the history readable"). Alongside the opaque histories.json
// snapshot, the access layer also writes, per conversation, two human-readable
// files — one for the raw turns, one for the compacted memory — organised in
// per-principal / per-session subfolders. These tests pin the pure renderers
// and the directory sink in isolation; session_manager_test.dart pins the
// manager wiring that drives them.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

ConversationHistory _history(List<HistoryTurn> turns, {String summary = ''}) {
  final history = ConversationHistory(compactedSummary: summary);
  for (final turn in turns) {
    history.append(turn);
  }
  return history;
}

void main() {
  group('renderConversationRaw', () {
    test('renders the title, every turn numbered, and both sides verbatim', () {
      final markdown = renderConversationRaw(
        _history([
          const HistoryTurn(
              userPrompt: 'My name is Alexis.',
              brainAnswer: 'Nice to meet you, Alexis!'),
          const HistoryTurn(
              userPrompt: 'What is my name?', brainAnswer: 'Your name is Alexis.'),
        ]),
        title: 'owner / telegram / global',
      );

      expect(markdown, contains('# owner / telegram / global'));
      expect(markdown, contains('Turn 1'));
      expect(markdown, contains('Turn 2'));
      expect(markdown, contains('My name is Alexis.'));
      expect(markdown, contains('Nice to meet you, Alexis!'));
      expect(markdown, contains('What is my name?'));
      expect(markdown, contains('Your name is Alexis.'));
      // The two prompts appear in order.
      expect(
        markdown.indexOf('My name is Alexis.'),
        lessThan(markdown.indexOf('What is my name?')),
      );
    });

    test('marks a turn whose answer has not been back-filled yet', () {
      final markdown = renderConversationRaw(
        _history([const HistoryTurn(userPrompt: 'Hi', brainAnswer: '')]),
        title: 't',
      );
      expect(markdown, contains('Hi'));
      expect(markdown, contains('(no answer recorded yet)'));
    });

    test('includes the tool round when a turn carries one', () {
      final markdown = renderConversationRaw(
        _history([
          const HistoryTurn(
            userPrompt: 'weather?',
            brainAnswer: 'Sunny.',
            toolRound: 'web_search("weather") -> sunny',
          ),
        ]),
        title: 't',
      );
      expect(markdown, contains('web_search("weather") -> sunny'));
    });

    test('renders an empty history as a readable "no turns" note', () {
      final markdown = renderConversationRaw(_history([]), title: 't');
      expect(markdown, contains('# t'));
      expect(markdown, contains('No turns recorded yet'));
    });
  });

  group('renderConversationMemory', () {
    test('renders the compacted summary and the pending-turn count', () {
      final history = _history(
        [for (var i = 0; i < 12; i++) HistoryTurn(userPrompt: 'q$i', brainAnswer: 'a$i')],
        summary: 'The user is named Alexis and lives on bomber.',
      );
      final markdown = renderConversationMemory(history, title: 'owner / telegram');
      expect(markdown, contains('# owner / telegram'));
      expect(markdown, contains('The user is named Alexis and lives on bomber.'));
      // 12 turns appended, rawCount 10 → 2 pending behind the window.
      expect(markdown, contains('2'));
    });

    test('renders a placeholder when nothing has been compacted yet', () {
      final markdown = renderConversationMemory(_history([]), title: 't');
      expect(markdown, contains('No compacted memory yet'));
    });
  });

  group('DirectoryHistoryMarkdownSink', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('brain_md_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('writes a .raw.md and a .memory.md at the nested segment path', () {
      final sink = DirectoryHistoryMarkdownSink(tempDir.path);
      sink.write([
        HistoryMarkdownRecord(
          pathSegments: const ['owner', 'telegram', 'global'],
          title: 'owner / telegram / global',
          history: _history([
            const HistoryTurn(userPrompt: 'hi', brainAnswer: 'hello'),
          ]),
        ),
      ]);

      final raw = File('${tempDir.path}/owner/telegram/global.raw.md');
      final memory = File('${tempDir.path}/owner/telegram/global.memory.md');
      expect(raw.existsSync(), isTrue);
      expect(memory.existsSync(), isTrue);
      expect(raw.readAsStringSync(), contains('hello'));
      expect(memory.readAsStringSync(), contains('owner / telegram / global'));
    });

    test('sanitises a segment that is not filesystem-safe', () {
      final sink = DirectoryHistoryMarkdownSink(tempDir.path);
      sink.write([
        HistoryMarkdownRecord(
          pathSegments: const ['a/b', 'sessions', 'id'],
          title: 't',
          history: _history([]),
        ),
      ]);
      // The slash in the segment must not create an extra directory level.
      expect(
        File('${tempDir.path}/a_b/sessions/id.raw.md').existsSync(),
        isTrue,
      );
    });
  });

  group('NullHistoryMarkdownSink', () {
    test('writes nothing', () {
      final tempDir = Directory.systemTemp.createTempSync('brain_md_null_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      const NullHistoryMarkdownSink().write([
        HistoryMarkdownRecord(
          pathSegments: const ['x'],
          title: 't',
          history: _history([]),
        ),
      ]);
      expect(tempDir.listSync(), isEmpty);
    });
  });
}
