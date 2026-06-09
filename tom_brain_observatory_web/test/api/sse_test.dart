// PT-4.2 (unit) — the SSE frame decoder. `sseDataFrames` turns a raw
// `text/event-stream` byte stream into the payload of each `data:` frame,
// re-assembling frames that arrive split across chunks (§ 4.8). Pure and
// transport-agnostic so the streaming client logic is testable without a server.

import 'dart:convert';

import 'package:tom_brain_observatory_web/src/api/sse.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<List<int>> _bytes(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode));

void main() {
  test('decodes the data payload of each frame', () async {
    final frames = await sseDataFrames(_bytes(<String>[
      'data: {"a":1}\n\n',
      'data: {"b":2}\n\n',
    ])).toList();
    expect(frames, <String>['{"a":1}', '{"b":2}']);
  });

  test('re-assembles a frame split across chunks', () async {
    final frames = await sseDataFrames(_bytes(<String>[
      'data: {"hea',
      'ding":"x"}\n',
      '\n',
    ])).toList();
    expect(frames, <String>['{"heading":"x"}']);
  });

  test('ignores non-data lines and trailing partial frames', () async {
    final frames = await sseDataFrames(_bytes(<String>[
      ': comment\ndata: ok\n\n',
      'data: partial-no-terminator',
    ])).toList();
    expect(frames, <String>['ok']);
  });
}
