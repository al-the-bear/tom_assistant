// E.37 — SSE delivery path (OpenAI) suite.
//
// Locks the concrete `ChannelDelivery` for `AccessChannel.openai` (proto spec
// § 5.3 / § 10.1; AC-2): each `OutboundChunk` becomes one
// `chat.completion.chunk` `data: …\n\n` frame written to the binding's sink;
// the final chunk additionally writes `data: [DONE]\n\n` and closes the wire,
// so `[DONE]` is always the last line; the frames repeat the renderer's
// `id` / `model` / `created`; the path dispatches correctly through the E.36
// `DeliveryRegistry`; and the runtime `StreamControllerSseSink` transports
// frames as the UTF-8 response body and surfaces a client disconnect.

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// An in-memory [SseSink] that records every frame as a string and tracks
/// closure — so the suite can assert frame order / shape without a socket.
final class _CollectingSseSink implements SseSink {
  final List<String> frames = <String>[];
  bool _closed = false;

  /// Simulates a mid-stream client disconnect — the E.39 SSE path reads this
  /// before each write. Tests toggle it directly.
  bool disconnected = false;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => disconnected;

  @override
  void write(String frame) {
    if (_closed) {
      throw StateError('write after close');
    }
    frames.add(frame);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// A renderer with pinned `id` / `model` / `created` so frame assertions are
/// deterministic (E.13 already proves `forModel`'s ULID minting).
ChatCompletionSseRenderer _renderer({String model = 'tom-assistant'}) {
  return ChatCompletionSseRenderer(
    id: 'chatcmpl-test',
    model: model,
    created: 1717329600,
  );
}

SseDeliveryBinding _binding({
  required SseSink sink,
  String model = 'tom-assistant',
  String principalId = 'principal-1',
  String? conversationId = 'conv-1',
  String? messageId = 'msg-1',
}) {
  return SseDeliveryBinding(
    identity: ResolvedIdentity(principalId: principalId),
    envelope: InboundRequest(
      text: 'hello',
      conversationId: conversationId,
      messageId: messageId,
    ),
    sink: sink,
    renderer: _renderer(model: model),
  );
}

/// Decodes a `data: {json}\n\n` frame into its payload map. Throws if the
/// frame is the terminal `[DONE]` line (callers check that separately).
Map<String, Object?> _payloadOf(String frame) {
  expect(frame.startsWith('data: '), isTrue, reason: 'frame: $frame');
  expect(frame.endsWith('\n\n'), isTrue, reason: 'frame: $frame');
  final String json = frame.substring('data: '.length, frame.length - 2);
  return jsonDecode(json) as Map<String, Object?>;
}

Map<String, Object?> _choice(Map<String, Object?> payload) {
  return (payload['choices'] as List<Object?>).single as Map<String, Object?>;
}

void main() {
  group('E.37 SseChannelDelivery — contract', () {
    test('serves AccessChannel.openai', () {
      expect(const SseChannelDelivery().channel, AccessChannel.openai);
    });

    test('the binding channel is always openai', () {
      final SseDeliveryBinding binding = _binding(sink: _CollectingSseSink());
      expect(binding.channel, AccessChannel.openai);
    });
  });

  group('E.37 SseChannelDelivery — frame rendering', () {
    test('a non-final chunk writes exactly one content frame', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'Hello', index: 0));

      expect(sink.frames, hasLength(1));
      final Map<String, Object?> payload = _payloadOf(sink.frames.single);
      expect(payload['object'], 'chat.completion.chunk');
      expect(payload['id'], 'chatcmpl-test');
      expect(payload['model'], 'tom-assistant');
      expect(payload['created'], 1717329600);
      final Map<String, Object?> choice = _choice(payload);
      expect((choice['delta'] as Map<String, Object?>)['content'], 'Hello');
      expect(choice['finish_reason'], isNull);
      expect(sink.isClosed, isFalse);
    });

    test('every frame of one completion repeats id / model / created', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'a', index: 0));
      deliver(OutboundChunk(textDelta: 'b', index: 1));

      final Map<String, Object?> first = _payloadOf(sink.frames[0]);
      final Map<String, Object?> second = _payloadOf(sink.frames[1]);
      expect(first['id'], second['id']);
      expect(first['created'], second['created']);
      expect(first['model'], second['model']);
    });

    test('a notice-only chunk renders no frame (SSE ignores notices)', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      final back =
          deliver(OutboundChunk(textDelta: '', notice: '🔧 tool memory.read'));

      expect(sink.frames, isEmpty);
      expect(sink.isClosed, isFalse);
      // The chunk was accepted — no stall.
      expect(back, isA<Stream<OutboundChunk>>());
    });

    test('a notice riding a content chunk still renders the content', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'Hello', notice: 'ignored', index: 0));

      expect(sink.frames, hasLength(1));
      final Map<String, Object?> choice = _choice(_payloadOf(sink.frames.single));
      expect((choice['delta'] as Map<String, Object?>)['content'], 'Hello');
    });

    test('the final chunk writes its frame, then [DONE], then closes', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'Hello', index: 0));
      deliver(OutboundChunk(textDelta: '', isFinal: true, index: 1));

      // content frame, final frame, [DONE]
      expect(sink.frames, hasLength(3));
      final Map<String, Object?> finalChoice =
          _choice(_payloadOf(sink.frames[1]));
      expect(finalChoice['finish_reason'], 'stop');
      expect(sink.frames.last, ChatCompletionSseRenderer.doneFrame);
      expect(sink.frames.last, 'data: [DONE]\n\n');
      expect(sink.isClosed, isTrue);
    });

    test('[DONE] is the last line on the wire', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'one', index: 0));
      deliver(OutboundChunk(textDelta: 'two', index: 1));
      deliver(OutboundChunk(textDelta: '', isFinal: true, index: 2));

      expect(sink.frames.last, 'data: [DONE]\n\n');
      // No other frame is a [DONE] line.
      expect(
        sink.frames.where((String f) => f == 'data: [DONE]\n\n'),
        hasLength(1),
      );
    });

    test('a single consolidated final chunk emits its frame + [DONE]', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'whole answer', isFinal: true));

      expect(sink.frames, hasLength(2));
      expect(
        (_choice(_payloadOf(sink.frames.first))['delta']
            as Map<String, Object?>)['content'],
        'whole answer',
      );
      expect(sink.frames.last, 'data: [DONE]\n\n');
      expect(sink.isClosed, isTrue);
    });

    test('the produced callback returns an empty backpressure stream',
        () async {
      final DeliverCallback deliver = const SseChannelDelivery()
          .bindDeliver(_binding(sink: _CollectingSseSink()));

      final List<OutboundChunk> back =
          await deliver(OutboundChunk(textDelta: 'x', index: 0)).toList();
      expect(back, isEmpty);
    });

    test('a chunk after the final one throws StateError', () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_binding(sink: sink));

      deliver(OutboundChunk(textDelta: 'done', isFinal: true));
      expect(
        () => deliver(OutboundChunk(textDelta: 'stray')),
        throwsStateError,
      );
    });

    test('each Access binds an independent terminated flag', () {
      const SseChannelDelivery path = SseChannelDelivery();
      final _CollectingSseSink sinkA = _CollectingSseSink();
      final _CollectingSseSink sinkB = _CollectingSseSink();

      final DeliverCallback a = path.bindDeliver(_binding(sink: sinkA));
      final DeliverCallback b = path.bindDeliver(_binding(sink: sinkB));

      a(OutboundChunk(textDelta: 'a', isFinal: true));
      // b is a separate binding — not terminated by a's final chunk.
      b(OutboundChunk(textDelta: 'b', index: 0));

      expect(sinkA.isClosed, isTrue);
      expect(sinkB.isClosed, isFalse);
      expect(sinkB.frames, hasLength(1));
    });
  });

  group('E.37 StreamControllerSseSink — runtime wire', () {
    test('frames are UTF-8 encoded onto the body stream in order', () async {
      final StreamControllerSseSink sink = StreamControllerSseSink();
      final Future<List<List<int>>> collected = sink.body.toList();

      sink.write('data: {"a":1}\n\n');
      sink.write('data: [DONE]\n\n');
      await sink.close();

      final List<List<int>> bytes = await collected;
      final String wire = bytes.map(utf8.decode).join();
      expect(wire, 'data: {"a":1}\n\ndata: [DONE]\n\n');
    });

    test('close is idempotent', () async {
      final StreamControllerSseSink sink = StreamControllerSseSink();
      unawaited(sink.body.drain<void>());
      await sink.close();
      await sink.close(); // second close is a no-op, no throw
      expect(sink.isClosed, isTrue);
    });

    test('writing after close throws StateError', () async {
      final StreamControllerSseSink sink = StreamControllerSseSink();
      unawaited(sink.body.drain<void>());
      await sink.close();
      expect(() => sink.write('data: x\n\n'), throwsStateError);
    });

    test('a client disconnect fires onClientDisconnect', () async {
      int disconnects = 0;
      final StreamControllerSseSink sink =
          StreamControllerSseSink(onClientDisconnect: () => disconnects++);

      final StreamSubscription<List<int>> sub = sink.body.listen((_) {});
      sink.write('data: x\n\n');
      await sub.cancel();
      // onCancel is scheduled; let the microtask/event loop settle.
      await Future<void>.delayed(Duration.zero);

      expect(disconnects, 1);
      expect(sink.isClosed, isFalse);
    });

    test('a normal close does not fire onClientDisconnect', () async {
      int disconnects = 0;
      final StreamControllerSseSink sink =
          StreamControllerSseSink(onClientDisconnect: () => disconnects++);
      unawaited(sink.body.drain<void>());

      sink.write('data: x\n\n');
      await sink.close();
      await Future<void>.delayed(Duration.zero);

      expect(disconnects, 0);
    });
  });

  group('E.37 SseChannelDelivery — through the DeliveryRegistry (E.36)', () {
    test('the registry dispatches openai to the SSE path', () {
      final DeliveryRegistry registry = DeliveryRegistry()
        ..register(const SseChannelDelivery());
      final _CollectingSseSink sink = _CollectingSseSink();

      final DeliverCallback deliver =
          registry.deliverFor(_binding(sink: sink));
      deliver(OutboundChunk(textDelta: 'hi', isFinal: true));

      expect(sink.frames, hasLength(2));
      expect(sink.frames.last, 'data: [DONE]\n\n');
    });

    test('the final chunk emits a correlated AccessDelivered', () {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: events.add)
            ..register(const SseChannelDelivery());
      final _CollectingSseSink sink = _CollectingSseSink();

      final DeliverCallback deliver = registry.deliverFor(
        _binding(
          sink: sink,
          principalId: 'principal-9',
          conversationId: 'conv-9',
          messageId: 'msg-9',
        ),
      );
      deliver(OutboundChunk(textDelta: 'a', index: 0));
      deliver(OutboundChunk(textDelta: '', isFinal: true, index: 1));

      expect(events, hasLength(1));
      final AccessDelivered event = events.single;
      expect(event.chunkCount, 2);
      expect(event.principalId, 'principal-9');
      expect(event.conversationId, 'conv-9');
      expect(event.accessId, 'msg-9');
    });
  });
}
