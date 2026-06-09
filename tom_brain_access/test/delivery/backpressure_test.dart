// E.39 — delivery backpressure suite.
//
// Locks how the two delivery paths surface a `DeliveryStalled` through the
// `DeliverCallback`'s backpressure `Stream<OutboundChunk>` (proto spec § 10.1;
// AC-2):
//   * SSE (E.37) — per-chunk: while connected the path returns
//     `Backpressure.clear`; once the sink reports `isDisconnected` it stops
//     writing to the dead wire and returns a *terminal* `DeliveryStalled`
//     (`clientDisconnected`), so the engine cancels the run (no leak). The
//     runtime `StreamControllerSseSink` sets `isDisconnected` when its body
//     subscription is cancelled mid-stream, but not after a normal close.
//   * Telegram (E.38) — buffered: the per-chunk stream is always clear (a
//     buffered channel cannot stall mid-stream); a rate-limit stall is
//     *transient* and surfaces at flush through the binding's `delivered`
//     future.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// An in-memory [SseSink] whose disconnect state the test toggles directly.
final class _CollectingSseSink implements SseSink {
  final List<String> frames = <String>[];
  bool _closed = false;
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

ChatCompletionSseRenderer _renderer() => ChatCompletionSseRenderer(
      id: 'chatcmpl-test',
      model: 'tom-assistant',
      created: 1717329600,
    );

SseDeliveryBinding _sseBinding(SseSink sink) => SseDeliveryBinding(
      identity: ResolvedIdentity(principalId: 'principal-1'),
      envelope: InboundRequest(text: 'hello', messageId: 'msg-1'),
      sink: sink,
      renderer: _renderer(),
    );

/// A [TelegramSink] that throws a transient rate-limit [DeliveryStalled] on
/// send — the documented Telegram backpressure surface (E.39).
final class _RateLimitedTelegramSink implements TelegramSink {
  final List<String> attempted = <String>[];

  @override
  Future<void> send(String message) async {
    attempted.add(message);
    throw DeliveryStalled.transient(
      channel: 'telegram',
      reason: StallReason.rateLimited,
      retryAfter: const Duration(seconds: 30),
      detail: 'HTTP 429 from the Telegram backend',
    );
  }
}

/// An in-memory [TelegramSink] that records sends (the happy path).
final class _CollectingTelegramSink implements TelegramSink {
  final List<String> sent = <String>[];

  @override
  Future<void> send(String message) async {
    sent.add(message);
  }
}

TelegramDeliveryBinding _telegramBinding(TelegramSink sink) =>
    TelegramDeliveryBinding(
      identity: ResolvedIdentity(principalId: 'principal-1'),
      envelope: InboundRequest(text: 'hello', messageId: 'msg-1'),
      sink: sink,
    );

/// Collects the result of listening to a backpressure stream: whether it
/// stalled and with which signal.
Future<DeliveryStalled?> _stallOf(Stream<OutboundChunk> backpressure) async {
  try {
    await for (final OutboundChunk _ in backpressure) {
      // A backpressure stream never emits an element.
    }
    return null;
  } on DeliveryStalled catch (e) {
    return e;
  }
}

void main() {
  group('E.39 SSE backpressure — connected wire', () {
    test('a chunk on a connected wire returns Backpressure.clear', () async {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_sseBinding(sink));

      final DeliveryStalled? stall =
          await _stallOf(deliver(OutboundChunk(textDelta: 'hi', index: 0)));

      expect(stall, isNull);
      expect(sink.frames, hasLength(1));
    });
  });

  group('E.39 SSE backpressure — client disconnect', () {
    test('a chunk after disconnect returns a terminal DeliveryStalled',
        () async {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_sseBinding(sink));

      // First chunk lands fine; then the client disconnects.
      deliver(OutboundChunk(textDelta: 'partial', index: 0));
      sink.disconnected = true;

      final DeliveryStalled? stall =
          await _stallOf(deliver(OutboundChunk(textDelta: 'more', index: 1)));

      expect(stall, isNotNull);
      expect(stall!.isTerminal, isTrue);
      expect(stall.reason, StallReason.clientDisconnected);
      expect(stall.channel, AccessChannel.openai.wireName);
      expect(stall.retryAfter, isNull);
    });

    test('a stalled chunk is not rendered into the dead wire (no leak)',
        () async {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_sseBinding(sink));

      sink.disconnected = true;
      await _stallOf(deliver(OutboundChunk(textDelta: 'x', index: 0)));

      // Nothing was written — the path did not render into the cancelled wire.
      expect(sink.frames, isEmpty);
    });

    test('after a disconnect stall the run is terminated (a later chunk throws)',
        () {
      final _CollectingSseSink sink = _CollectingSseSink();
      final DeliverCallback deliver =
          const SseChannelDelivery().bindDeliver(_sseBinding(sink));

      sink.disconnected = true;
      deliver(OutboundChunk(textDelta: 'x', index: 0)); // stalled
      expect(
        () => deliver(OutboundChunk(textDelta: 'y', index: 1)),
        throwsStateError,
      );
    });

    test('a disconnect-stall chunk through the registry emits no AccessDelivered',
        () async {
      final List<AccessDelivered> delivered = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: delivered.add)
            ..register(const SseChannelDelivery());
      final _CollectingSseSink sink = _CollectingSseSink()..disconnected = true;

      final DeliverCallback deliver = registry.deliverFor(_sseBinding(sink));
      await _stallOf(deliver(OutboundChunk(textDelta: 'x', index: 0)));

      // The chunk was not final and was not delivered — no terminal-success
      // event for an answer that never reached the client.
      expect(delivered, isEmpty);
    });
  });

  group('E.39 SSE backpressure — runtime sink disconnect signal', () {
    test('a mid-stream cancel sets isDisconnected', () async {
      final StreamControllerSseSink sink = StreamControllerSseSink();
      final StreamSubscription<List<int>> sub = sink.body.listen((_) {});

      sink.write('data: x\n\n');
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(sink.isDisconnected, isTrue);
      expect(sink.isClosed, isFalse);
    });

    test('a normal close does not set isDisconnected', () async {
      final StreamControllerSseSink sink = StreamControllerSseSink();
      unawaited(sink.body.drain<void>());

      sink.write('data: x\n\n');
      await sink.close();
      await Future<void>.delayed(Duration.zero);

      expect(sink.isDisconnected, isFalse);
      expect(sink.isClosed, isTrue);
    });
  });

  group('E.39 Telegram backpressure — buffered, surfaces at flush', () {
    test('a non-final chunk returns Backpressure.clear (cannot stall)',
        () async {
      final DeliverCallback deliver = const TelegramChannelDelivery()
          .bindDeliver(_telegramBinding(_RateLimitedTelegramSink()));

      final DeliveryStalled? stall = await _stallOf(
        deliver(OutboundChunk(textDelta: 'buffering', index: 0)),
      );

      // Buffering never stalls; the rate-limited sink is only hit at flush.
      expect(stall, isNull);
    });

    test('a rate limit surfaces a transient DeliveryStalled via delivered',
        () async {
      final _RateLimitedTelegramSink sink = _RateLimitedTelegramSink();
      final TelegramDeliveryBinding binding = _telegramBinding(sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      deliver(OutboundChunk(textDelta: 'the whole answer', isFinal: true));

      Object? caught;
      try {
        await binding.delivered;
      } on Object catch (e) {
        caught = e;
      }

      expect(caught, isA<DeliveryStalled>());
      final DeliveryStalled stall = caught! as DeliveryStalled;
      expect(stall.isTerminal, isFalse);
      expect(stall.reason, StallReason.rateLimited);
      expect(stall.retryAfter, const Duration(seconds: 30));
    });

    test('the normal path returns clear and delivered completes', () async {
      final _CollectingTelegramSink sink = _CollectingTelegramSink();
      final TelegramDeliveryBinding binding = _telegramBinding(sink);
      final DeliverCallback deliver =
          const TelegramChannelDelivery().bindDeliver(binding);

      final DeliveryStalled? stall = await _stallOf(
        deliver(OutboundChunk(textDelta: 'done', isFinal: true)),
      );
      await binding.delivered;

      expect(stall, isNull);
      expect(sink.sent, <String>['done']);
    });
  });
}
