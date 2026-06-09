// Chunk-stream delivery (Ollama / Anthropic) — out-of-band notice handling.
//
// The adapter-renders channels forward each raw `OutboundChunk` to the adapter,
// which renders its own dialect. Out-of-band notices (`OutboundChunk.notice`,
// P2) are a Telegram-surface concern: a chunk carrying only a notice must NOT
// be forwarded here, or the adapter would render an empty-content frame. A
// notice riding a content chunk still forwards the content.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// An in-memory [OutboundChunkSink] that records every forwarded chunk — so the
/// suite can assert what reaches the adapter without an adapter.
final class _CollectingChunkSink implements OutboundChunkSink {
  final List<OutboundChunk> chunks = <OutboundChunk>[];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => false;

  @override
  void add(OutboundChunk chunk) {
    if (_closed) {
      throw StateError('add after close');
    }
    chunks.add(chunk);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

ChunkStreamDeliveryBinding _binding(OutboundChunkSink sink) =>
    ChunkStreamDeliveryBinding(
      channel: AccessChannel.ollama,
      identity: ResolvedIdentity(principalId: 'p-1'),
      envelope: InboundRequest(text: 'hi', conversationId: 'c-1'),
      sink: sink,
    );

void main() {
  group('ChunkStreamChannelDelivery — out-of-band notices', () {
    test('a notice-only chunk is not forwarded to the adapter', () {
      final sink = _CollectingChunkSink();
      final deliver =
          ChunkStreamChannelDelivery(AccessChannel.ollama).bindDeliver(
        _binding(sink),
      );

      deliver(OutboundChunk(textDelta: '', notice: '🔧 tool memory.read'));

      expect(sink.chunks, isEmpty);
      expect(sink.isClosed, isFalse);
    });

    test('a notice riding a content chunk still forwards the content', () {
      final sink = _CollectingChunkSink();
      final deliver =
          ChunkStreamChannelDelivery(AccessChannel.ollama).bindDeliver(
        _binding(sink),
      );

      deliver(OutboundChunk(textDelta: 'Hello', notice: 'ignored', index: 0));

      expect(sink.chunks, hasLength(1));
      expect(sink.chunks.single.textDelta, 'Hello');
    });

    test('notices interleaved with answer deltas leave only the deltas on the '
        'wire', () {
      final sink = _CollectingChunkSink();
      final deliver =
          ChunkStreamChannelDelivery(AccessChannel.ollama).bindDeliver(
        _binding(sink),
      );

      deliver(OutboundChunk(textDelta: 'Hello, ', index: 0));
      deliver(OutboundChunk(textDelta: '', notice: '🔧 tool memory.read'));
      deliver(OutboundChunk(textDelta: 'world.', isFinal: true, index: 1));

      expect(sink.chunks.map((c) => c.textDelta).toList(),
          <String>['Hello, ', 'world.']);
      expect(sink.isClosed, isTrue);
    });
  });
}
