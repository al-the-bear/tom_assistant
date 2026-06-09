// PT-4.2 — a minimal SSE decoder for the live-tail (§ 4.8). The Trail Read API
// frames each step as `data: <json>\n\n`; this turns the raw byte stream into
// the JSON payload of each `data:` line, re-assembling frames that span chunk
// boundaries. Read-only on the wire: it only consumes the response stream.

import 'dart:convert';

/// Yields the `data:` payload of every complete SSE frame in [bytes]. Frames are
/// terminated by a blank line (`\n\n`); a trailing partial frame is dropped when
/// the stream ends without its terminator.
Stream<String> sseDataFrames(Stream<List<int>> bytes) async* {
  var buffer = '';
  await for (final chunk in bytes.transform(utf8.decoder)) {
    buffer += chunk;
    var sep = buffer.indexOf('\n\n');
    while (sep >= 0) {
      final frame = buffer.substring(0, sep);
      buffer = buffer.substring(sep + 2);
      for (final line in const LineSplitter().convert(frame)) {
        if (line.startsWith('data: ')) yield line.substring('data: '.length);
      }
      sep = buffer.indexOf('\n\n');
    }
  }
}
