// B.31 — `RetryingWebHttpClient` API conformance.
//
// Scope of this test file (per plan step B.31):
//
//   - Prove retry on retryable status codes (default {408, 429, 500,
//     502, 503, 504}). A 503-then-200 sequence returns the 200 on the
//     second attempt; a 200 on the first attempt is returned verbatim
//     with no retries.
//   - Prove retry on transport exceptions (`WebHttpTransportException`).
//   - Prove `maxAttempts` caps the retry loop: 503 returned by every
//     attempt surfaces the last 503 response after `maxAttempts`
//     attempts, not after `maxAttempts + 1`.
//   - Prove exponential backoff with the injectable `sleep` seam: the
//     delays observed by the fake clock follow the
//     `initialDelay * multiplier^n` ladder (with `jitterFraction: 0.0`
//     so the test is deterministic).
//   - Prove `Retry-After` honouring: a 429 / 503 with a numeric
//     `Retry-After: 7` header forces the next delay to be at least 7
//     seconds, even when computed backoff is smaller.
//   - Prove circuit-breaker opens after `failureThreshold` consecutive
//     failures, short-circuits subsequent calls with
//     [CircuitBreakerOpen], transitions to half-open after the cooldown
//     elapses, and closes on a successful half-open probe.
//   - Prove half-open probe failure re-opens the breaker and resets
//     the cooldown.
//   - Prove `postForm` is not retried by default (POST is not
//     idempotent); opt-in via `retryPostForm: true` flips the
//     behaviour.
//   - Prove construction validation: `maxAttempts < 1`,
//     `backoffMultiplier < 1.0`, `jitterFraction` out of `[0,1]`,
//     `failureThreshold < 1`, `halfOpenMaxProbes < 1` all throw at
//     construction.
//   - Prove `close()` cascades to the inner client when owned;
//     subsequent calls throw `StateError`.
//   - Prove the surface is reachable from the top-level package
//     barrel.
//
// Scope this file is NOT for:
//
//   - No live network. The fake `_FakeHttpClient` returns scripted
//     responses; the fake clock + sleep seam keep the suite
//     deterministic.
//   - No `tom_core_kernel.TomHttpClientFactory` wiring — that lives
//     in `b31_tom_kernel_web_http_client_test.dart`.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.31 / RetryingWebHttpClient — construction invariants', () {
    test('rejects maxAttempts < 1', () {
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          retryPolicy: const WebRetryPolicy(maxAttempts: 0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects backoffMultiplier < 1.0', () {
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          retryPolicy: const WebRetryPolicy(backoffMultiplier: 0.5),
        ),
        throwsArgumentError,
      );
    });

    test('rejects jitterFraction outside [0,1]', () {
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          retryPolicy: const WebRetryPolicy(jitterFraction: -0.1),
        ),
        throwsArgumentError,
      );
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          retryPolicy: const WebRetryPolicy(jitterFraction: 1.5),
        ),
        throwsArgumentError,
      );
    });

    test('rejects breaker failureThreshold < 1', () {
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          breakerPolicy: const WebCircuitBreakerPolicy(failureThreshold: 0),
        ),
        throwsArgumentError,
      );
    });

    test('rejects halfOpenMaxProbes < 1', () {
      expect(
        () => RetryingWebHttpClient(
          inner: _FakeHttpClient(),
          breakerPolicy: const WebCircuitBreakerPolicy(halfOpenMaxProbes: 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('B.31 / RetryingWebHttpClient — retry on retryable status', () {
    test('503 → 200 returns the 200 on the second attempt', () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(200, body: 'hi'));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 100),
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      final response = await http.get(Uri.parse('https://example.com/a'));

      expect(response.statusCode, 200);
      expect(response.body, 'hi');
      expect(inner.getCalls, hasLength(2));
      expect(sleeps, hasLength(1));
      expect(sleeps.single, const Duration(milliseconds: 100));

      http.close();
    });

    test('200 on first attempt: no retries, no sleeps', () async {
      final inner = _FakeHttpClient()..enqueueGet(_resp(200, body: 'ok'));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      final response = await http.get(Uri.parse('https://example.com/a'));

      expect(response.statusCode, 200);
      expect(inner.getCalls, hasLength(1));
      expect(sleeps, isEmpty);
      http.close();
    });

    test(
        'maxAttempts caps the loop: 3 attempts then surfaces the last response',
        () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          maxAttempts: 3,
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 50),
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      final response = await http.get(Uri.parse('https://example.com/a'));

      expect(response.statusCode, 503);
      expect(inner.getCalls, hasLength(3));
      expect(sleeps, hasLength(2)); // one sleep between each pair of attempts
      http.close();
    });

    test('non-retryable status (404) is returned on first attempt', () async {
      final inner = _FakeHttpClient()..enqueueGet(_resp(404));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      final response = await http.get(Uri.parse('https://example.com/a'));

      expect(response.statusCode, 404);
      expect(inner.getCalls, hasLength(1));
      expect(sleeps, isEmpty);
      http.close();
    });

    test(
        'exponential backoff ladder follows initialDelay * multiplier^n, '
        'capped at maxDelay', () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503))
        ..enqueueGet(_resp(503));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          maxAttempts: 5,
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 100),
          backoffMultiplier: 2.0,
          maxDelay: Duration(milliseconds: 500),
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      await http.get(Uri.parse('https://example.com/a'));

      // 5 attempts → 4 sleeps. Ladder: 100, 200, 400, 500 (capped).
      expect(sleeps, hasLength(4));
      expect(sleeps[0], const Duration(milliseconds: 100));
      expect(sleeps[1], const Duration(milliseconds: 200));
      expect(sleeps[2], const Duration(milliseconds: 400));
      expect(sleeps[3], const Duration(milliseconds: 500));
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — retry on transport exceptions', () {
    test('transport exception then 200 returns the 200', () async {
      final inner = _FakeHttpClient()
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('dns lookup failed'),
        ))
        ..enqueueGet(_resp(200, body: 'recovered'));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(jitterFraction: 0.0),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );

      final response = await http.get(Uri.parse('https://example.com/a'));
      expect(response.statusCode, 200);
      expect(inner.getCalls, hasLength(2));
      http.close();
    });

    test('transport exception every attempt: surfaces the last exception',
        () async {
      final inner = _FakeHttpClient();
      for (var i = 0; i < 3; i++) {
        inner.enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: FormatException('attempt $i failed'),
        ));
      }
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(maxAttempts: 3, jitterFraction: 0.0),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );

      Object? thrown;
      try {
        await http.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebHttpTransportException>());
      expect(inner.getCalls, hasLength(3));
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — Retry-After header honouring', () {
    test('numeric Retry-After on 429 dominates computed backoff', () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(429, headers: {'retry-after': '7'}))
        ..enqueueGet(_resp(200));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 50),
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      await http.get(Uri.parse('https://example.com/a'));

      expect(sleeps, hasLength(1));
      // 7s > 50ms → Retry-After wins.
      expect(sleeps.single, const Duration(seconds: 7));
      http.close();
    });

    test('numeric Retry-After smaller than backoff: backoff wins', () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(503, headers: {'retry-after': '0'}))
        ..enqueueGet(_resp(200));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 200),
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      await http.get(Uri.parse('https://example.com/a'));
      expect(sleeps.single, const Duration(milliseconds: 200));
      http.close();
    });

    test('honourRetryAfterHeader: false ignores header', () async {
      final inner = _FakeHttpClient()
        ..enqueueGet(_resp(429, headers: {'retry-after': '60'}))
        ..enqueueGet(_resp(200));
      final sleeps = <Duration>[];
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(
          jitterFraction: 0.0,
          initialDelay: Duration(milliseconds: 25),
          honourRetryAfterHeader: false,
        ),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (d) async => sleeps.add(d),
      );

      await http.get(Uri.parse('https://example.com/a'));
      expect(sleeps.single, const Duration(milliseconds: 25));
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — circuit breaker', () {
    test('opens after failureThreshold consecutive failures', () async {
      final inner = _FakeHttpClient();
      // 6 transport failures: 3 × 2 attempts each (retryPolicy maxAttempts=2)
      for (var i = 0; i < 6; i++) {
        inner.enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: FormatException('boom $i'),
        ));
      }
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(maxAttempts: 2, jitterFraction: 0.0),
        breakerPolicy: const WebCircuitBreakerPolicy(
          failureThreshold: 3,
          cooldown: Duration(seconds: 30),
        ),
        sleep: (_) async {},
        clock: clock.now,
      );

      // Three top-level GETs, each retries once → 6 inner attempts total,
      // 3 logical failures, breaker opens on the third.
      for (var i = 0; i < 3; i++) {
        try {
          await http.get(Uri.parse('https://example.com/a'));
        } on WebHttpTransportException {
          // expected
        }
      }

      final snapshot = http.debugBreakerState('example.com');
      expect(snapshot.state, BreakerState.open);
      expect(snapshot.consecutiveFailures, 3);

      // A subsequent GET short-circuits.
      Object? thrown;
      try {
        await http.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<CircuitBreakerOpen>());
      final e = thrown! as CircuitBreakerOpen;
      expect(e.bucket, 'example.com');
      // Inner client was not called again: still 6 attempts total.
      expect(inner.getCalls, hasLength(6));
      http.close();
    });

    test('half-open after cooldown lets one probe through; success closes',
        () async {
      final inner = _FakeHttpClient()
        // First 2 calls fail (threshold=2)
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('boom1'),
        ))
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('boom2'),
        ))
        // After cooldown: half-open probe succeeds.
        ..enqueueGet(_resp(200, body: 'recovered'));
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: WebRetryPolicy.noRetry,
        breakerPolicy: const WebCircuitBreakerPolicy(
          failureThreshold: 2,
          cooldown: Duration(seconds: 30),
        ),
        sleep: (_) async {},
        clock: clock.now,
      );

      // Drive two failures to open the breaker.
      for (var i = 0; i < 2; i++) {
        try {
          await http.get(Uri.parse('https://example.com/a'));
        } on WebHttpTransportException {
          // expected
        }
      }
      expect(http.debugBreakerState('example.com').state, BreakerState.open);

      // While still inside cooldown: short-circuits.
      clock.advance(const Duration(seconds: 10));
      Object? duringCooldown;
      try {
        await http.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        duringCooldown = e;
      }
      expect(duringCooldown, isA<CircuitBreakerOpen>());

      // After cooldown: probe succeeds, breaker closes.
      clock.advance(const Duration(seconds: 25));
      final response = await http.get(Uri.parse('https://example.com/a'));
      expect(response.statusCode, 200);
      expect(http.debugBreakerState('example.com').state, BreakerState.closed);
      expect(http.debugBreakerState('example.com').consecutiveFailures, 0);
      http.close();
    });

    test('half-open probe failure re-opens the breaker and resets cooldown',
        () async {
      final inner = _FakeHttpClient()
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('boom1'),
        ))
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('boom2'),
        ))
        // Half-open probe fails.
        ..enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://example.com/a'),
          cause: const FormatException('boom3'),
        ));
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: WebRetryPolicy.noRetry,
        breakerPolicy: const WebCircuitBreakerPolicy(
          failureThreshold: 2,
          cooldown: Duration(seconds: 30),
        ),
        sleep: (_) async {},
        clock: clock.now,
      );

      for (var i = 0; i < 2; i++) {
        try {
          await http.get(Uri.parse('https://example.com/a'));
        } on WebHttpTransportException {/* expected */}
      }
      expect(http.debugBreakerState('example.com').state, BreakerState.open);
      final firstOpenedAt = http.debugBreakerState('example.com').openedAt;

      clock.advance(const Duration(seconds: 35));
      try {
        await http.get(Uri.parse('https://example.com/a'));
      } on WebHttpTransportException {/* expected */}
      final snapshot = http.debugBreakerState('example.com');
      expect(snapshot.state, BreakerState.open);
      // openedAt advanced to the probe's failure time.
      expect(snapshot.openedAt, isNot(equals(firstOpenedAt)));

      http.close();
    });

    test('breaker is per-host: failures on A do not open B', () async {
      final inner = _FakeHttpClient();
      for (var i = 0; i < 3; i++) {
        inner.enqueueGetException(WebHttpTransportException(
          url: Uri.parse('https://a.example.com/'),
          cause: const FormatException('a-boom'),
        ));
      }
      inner.enqueueGet(_resp(200, body: 'b-ok'));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: WebRetryPolicy.noRetry,
        breakerPolicy: const WebCircuitBreakerPolicy(failureThreshold: 3),
        sleep: (_) async {},
      );

      for (var i = 0; i < 3; i++) {
        try {
          await http.get(Uri.parse('https://a.example.com/'));
        } on WebHttpTransportException {/* expected */}
      }
      expect(http.debugBreakerState('a.example.com').state, BreakerState.open);
      expect(http.debugBreakerState('b.example.com').state, BreakerState.closed);

      // B still works.
      final response = await http.get(Uri.parse('https://b.example.com/'));
      expect(response.statusCode, 200);
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — POST idempotency', () {
    test('postForm not retried by default', () async {
      final inner = _FakeHttpClient()..enqueueGet(_resp(503));
      final http = RetryingWebHttpClient(
        inner: inner,
        // GET-style retry policy is irrelevant here because retryPostForm
        // is the gate; default is false.
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );

      // _FakeHttpClient.enqueueGet feeds the get queue; use postQueue:
      inner
        ..clear()
        ..enqueuePost(_resp(503));
      final response = await http.postForm(
        Uri.parse('https://example.com/a'),
        form: const <String, String>{'q': 'x'},
      );
      expect(response.statusCode, 503);
      expect(inner.postCalls, hasLength(1));
      http.close();
    });

    test('postForm retried when retryPostForm: true', () async {
      final inner = _FakeHttpClient()
        ..enqueuePost(_resp(503))
        ..enqueuePost(_resp(200));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy:
            const WebRetryPolicy(jitterFraction: 0.0, retryPostForm: true),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );

      final response = await http.postForm(
        Uri.parse('https://example.com/a'),
        form: const <String, String>{'q': 'x'},
      );
      expect(response.statusCode, 200);
      expect(inner.postCalls, hasLength(2));
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — getBytes', () {
    test('retries getBytes on 503 then returns 200 bytes', () async {
      final inner = _FakeHttpClient()
        ..enqueueGetBytes(_bytesResp(503))
        ..enqueueGetBytes(_bytesResp(200, body: [1, 2, 3]));
      final http = RetryingWebHttpClient(
        inner: inner,
        retryPolicy: const WebRetryPolicy(jitterFraction: 0.0),
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );

      final response =
          await http.getBytes(Uri.parse('https://example.com/a'));
      expect(response.statusCode, 200);
      expect(response.bodyBytes, [1, 2, 3]);
      expect(inner.getBytesCalls, hasLength(2));
      http.close();
    });
  });

  group('B.31 / RetryingWebHttpClient — lifecycle', () {
    test('close cascades to inner when owned', () {
      final inner = _FakeHttpClient();
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );
      http.close();
      expect(inner.closed, isTrue);
    });

    test('close does NOT cascade when ownsInner: false', () {
      final inner = _FakeHttpClient();
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        ownsInner: false,
        sleep: (_) async {},
      );
      http.close();
      expect(inner.closed, isFalse);
    });

    test('subsequent calls after close throw StateError', () async {
      final inner = _FakeHttpClient()..enqueueGet(_resp(200));
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );
      http.close();
      Object? thrown;
      try {
        await http.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<StateError>());
    });

    test('close is idempotent', () {
      final inner = _FakeHttpClient();
      final http = RetryingWebHttpClient(
        inner: inner,
        breakerPolicy: WebCircuitBreakerPolicy.disabled,
        sleep: (_) async {},
      );
      http
        ..close()
        ..close();
      expect(inner.closeCalls, 1);
    });
  });

  group('B.31 / RetryingWebHttpClient — barrel reachability', () {
    test('symbols reachable through top-level package barrel', () {
      // The act of compiling against
      // `package:tom_brain_substrate/tom_brain_substrate.dart` and
      // referencing the public symbols here proves the barrel export.
      expect(RetryingWebHttpClient, isNotNull);
      expect(WebRetryPolicy, isNotNull);
      expect(WebCircuitBreakerPolicy, isNotNull);
      expect(CircuitBreakerOpen, isNotNull);
      expect(BreakerState.values, hasLength(3));
      expect(defaultRetryableStatusCodes, contains(503));
    });
  });
}

WebHttpResponse _resp(
  int statusCode, {
  String body = '',
  Map<String, String>? headers,
}) =>
    WebHttpResponse(
      statusCode: statusCode,
      body: body,
      headers: headers ?? const <String, String>{},
      url: Uri.parse('https://example.com/a'),
    );

WebHttpBytesResponse _bytesResp(
  int statusCode, {
  List<int> body = const <int>[],
  Map<String, String>? headers,
}) =>
    WebHttpBytesResponse(
      statusCode: statusCode,
      bodyBytes: body,
      headers: headers ?? const <String, String>{},
      url: Uri.parse('https://example.com/a'),
      contentLength: null,
      truncated: false,
    );

class _MutableClock {
  DateTime _now;
  _MutableClock(this._now);
  DateTime now() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }
}

/// In-test fake of [WebHttpClient]: returns scripted responses /
/// throws scripted exceptions in FIFO order per method. Records every
/// call so the test can assert call counts. Method queues are
/// independent — `enqueueGet` does not feed `postForm`.
class _FakeHttpClient implements WebHttpClient {
  final List<Object> _getQueue = <Object>[];
  final List<Object> _postQueue = <Object>[];
  final List<Object> _getBytesQueue = <Object>[];
  final List<Uri> getCalls = <Uri>[];
  final List<Uri> postCalls = <Uri>[];
  final List<Uri> getBytesCalls = <Uri>[];
  bool closed = false;
  int closeCalls = 0;

  void enqueueGet(WebHttpResponse response) => _getQueue.add(response);
  void enqueueGetException(WebHttpTransportException e) => _getQueue.add(e);
  void enqueuePost(WebHttpResponse response) => _postQueue.add(response);
  void enqueueGetBytes(WebHttpBytesResponse response) =>
      _getBytesQueue.add(response);

  void clear() {
    _getQueue.clear();
    _postQueue.clear();
    _getBytesQueue.clear();
    getCalls.clear();
    postCalls.clear();
    getBytesCalls.clear();
  }

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    getCalls.add(url);
    if (_getQueue.isEmpty) {
      throw StateError('No more queued GET responses for $url');
    }
    final next = _getQueue.removeAt(0);
    if (next is WebHttpTransportException) throw next;
    return next as WebHttpResponse;
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    postCalls.add(url);
    if (_postQueue.isEmpty) {
      throw StateError('No more queued POST responses for $url');
    }
    final next = _postQueue.removeAt(0);
    if (next is WebHttpTransportException) throw next;
    return next as WebHttpResponse;
  }

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    getBytesCalls.add(url);
    if (_getBytesQueue.isEmpty) {
      throw StateError('No more queued GETBYTES responses for $url');
    }
    final next = _getBytesQueue.removeAt(0);
    if (next is WebHttpTransportException) throw next;
    return next as WebHttpBytesResponse;
  }

  @override
  void close() {
    closed = true;
    closeCalls += 1;
  }
}

// Tame `unused_import` analyzer warning — these are referenced in
// some scripted scenarios above.
// ignore: unused_element
final _suppressDeadCode = <Object>[Random(), Uint8List(0), Completer<void>()];
