// B.31 — `RetryingWebHttpClient`: retry + circuit-breaker decorator
// stacked *around* any `WebHttpClient`.
//
// Why this lives here (and not in `tom_core_kernel`):
//
//   `tom_core_kernel` ships `TomHttpClientFactory` (a thin
//   `package:http.Client` factory shared with the rest of the workspace)
//   plus the request lifecycle primitives (`TomServerCall`, `reset()`,
//   `TomServerCallError`) but it deliberately does NOT ship a retry
//   policy or a circuit breaker — the example file
//   `tom_core_kernel/example/http_connection/03_retry_policies_example.dart`
//   teaches the caller how to implement those patterns rather than
//   shipping the code. The substrate-specification.md § 8 web tools
//   need this behaviour for every outbound call, so the prototype
//   ships it here, behind the same narrow `WebHttpClient` seam every
//   other web-tool component already uses. The kernel-side adapter
//   that hands a `package:http.Client` to this decorator is
//   `tom_kernel_web_http_client.dart` (B.31 too); the two files
//   together replace `DefaultWebHttpClient` in production wiring.
//
//   See `prototype_implementation_questions.md` Q-B.31.1 for the open
//   question on whether retry / circuit-breaker should eventually live
//   in `tom_core_kernel` as a first-class `RetryPolicy` + `CircuitBreaker`
//   surface that every workspace HTTP consumer shares.
//
// What this class does:
//
//   - Retries `WebHttpTransportException` and retryable status responses
//     (default {408, 429, 500, 502, 503, 504}) up to `maxAttempts` with
//     exponential backoff + bounded jitter. Honours `Retry-After` on
//     `429` / `503` when set (seconds or HTTP-date format).
//   - Trips a per-host circuit breaker after `failureThreshold`
//     consecutive failures. While open the decorator short-circuits
//     with `CircuitBreakerOpen` (no inner call). After `cooldown`
//     elapses one half-open probe is allowed through; success closes
//     the breaker, failure re-opens it.
//   - Only `get` and `getBytes` are retried by default; `postForm` is
//     not retryable unless the caller opts in
//     (`retryPostForm: true`) — POST is non-idempotent and forwarding
//     a duplicate to a search provider can charge the caller twice on
//     a metered SerpAPI / Brave / Tavily account.
//
// What this class deliberately does NOT do:
//
//   - It does not introspect response bodies. The retry decision rests
//     entirely on the status code and the transport exception class.
//     A 200 response with an in-body error code (e.g. DDG anti-bot page)
//     is the caller's responsibility (the provider raises
//     `WebSearchProviderException` and that does NOT trigger a retry —
//     the breaker should not open on a content-classification miss).
//   - It does not measure latency for breaker decisions. Failure count
//     is the only signal; slow successful calls do not contribute.
//   - It does not authenticate. Auth headers ride through the
//     `headers:` argument verbatim.
//
// Test seams: `sleep`, `clock`, `random`, and `breakerKey` are
// injectable so the conformance suite at
// `test/b31_retrying_web_http_client_test.dart` can drive retry timing
// and breaker state deterministically without sleeping or binding a
// port.

import 'dart:async';
import 'dart:math';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'web_http_client.dart';

/// The closed set of HTTP status codes the retry decorator treats as
/// retryable by default. Mirrors the kernel example
/// (`tom_core_kernel/example/http_connection/03_retry_policies_example.dart`
/// § 5) and the upstream guidance most retry policies converge on.
///
///   - `408 Request Timeout` — client-side timeout, server alive.
///   - `429 Too Many Requests` — rate-limited; honour `Retry-After`.
///   - `500 Internal Server Error` — transient server fault.
///   - `502 Bad Gateway` — upstream proxy failure.
///   - `503 Service Unavailable` — load-shed or maintenance; honour
///     `Retry-After`.
///   - `504 Gateway Timeout` — upstream timeout.
const Set<int> defaultRetryableStatusCodes = <int>{
  408,
  429,
  500,
  502,
  503,
  504,
};

/// Immutable retry-policy configuration. Held by
/// [RetryingWebHttpClient] and consulted on every call.
///
/// Default values match the kernel example § 4 (initial 100 ms,
/// multiplier 2.0, max 5 s) rounded to the values
/// `substrate_specification.md` § 8 calls out. Jitter is added on top
/// to avoid synchronised retry storms across concurrent calls.
final class WebRetryPolicy {
  /// Total attempts including the first one. `maxAttempts: 1` ⇒ no
  /// retry. Must be `>= 1`.
  final int maxAttempts;

  /// Delay before the first retry. Subsequent retries multiply by
  /// [backoffMultiplier], capped at [maxDelay].
  final Duration initialDelay;

  /// Upper bound on the per-retry delay, before jitter.
  final Duration maxDelay;

  /// Multiplier applied to the previous delay to produce the next.
  /// Must be `>= 1.0` (a multiplier `< 1.0` would make backoff shrink).
  final double backoffMultiplier;

  /// Fraction of the computed delay to add as ± random jitter. `0.2`
  /// means each retry waits between `0.8 * delay` and `1.2 * delay`.
  /// Must be in `[0.0, 1.0]`.
  final double jitterFraction;

  /// Status codes that should trigger a retry. Anything not in the
  /// set is returned verbatim from the inner client (or, for a 2xx
  /// success, completes the call).
  final Set<int> retryableStatusCodes;

  /// When `true`, `postForm` retries follow the same policy as
  /// `get` / `getBytes`. Default `false` because POST is not safe to
  /// duplicate — most search providers either charge per call or
  /// rate-limit aggressively on duplicates. Callers that know their
  /// POST target is idempotent (e.g. DuckDuckGo HTML, which accepts
  /// either GET or POST and is free) can opt in.
  final bool retryPostForm;

  /// When `true`, the decorator parses `Retry-After` on 429 / 503
  /// responses and uses the larger of (computed backoff,
  /// Retry-After value) as the next delay. The header may be either
  /// an integer number of seconds or an HTTP-date.
  final bool honourRetryAfterHeader;

  const WebRetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 5),
    this.backoffMultiplier = 2.0,
    this.jitterFraction = 0.2,
    this.retryableStatusCodes = defaultRetryableStatusCodes,
    this.retryPostForm = false,
    this.honourRetryAfterHeader = true,
  });

  /// A policy with [maxAttempts] of `1` — i.e. no retry. Useful in
  /// tests that want to exercise the circuit breaker in isolation, and
  /// in production wiring where the caller already retries upstream.
  static const WebRetryPolicy noRetry = WebRetryPolicy(maxAttempts: 1);

  /// Whether a status code should trigger a retry per this policy.
  bool isRetryableStatus(int statusCode) =>
      retryableStatusCodes.contains(statusCode);
}

/// Immutable circuit-breaker configuration. Held by
/// [RetryingWebHttpClient] and applied per-host (or per-key when the
/// caller pins [RetryingWebHttpClient.breakerKey]).
///
/// Defaults are conservative for a single-user prototype: 5 failures
/// open the breaker, 30 s cooldown, one half-open probe allowed.
final class WebCircuitBreakerPolicy {
  /// Consecutive failures (post-retry) that open the breaker. Must
  /// be `>= 1`. A failure resets the counter back to zero on the next
  /// successful call.
  final int failureThreshold;

  /// Time the breaker stays open before allowing a half-open probe.
  final Duration cooldown;

  /// Number of probes allowed concurrently while half-open. Default
  /// 1 — only one request at a time may test whether the upstream has
  /// recovered. Excess concurrent calls during half-open short-circuit
  /// with [CircuitBreakerOpen].
  final int halfOpenMaxProbes;

  const WebCircuitBreakerPolicy({
    this.failureThreshold = 5,
    this.cooldown = const Duration(seconds: 30),
    this.halfOpenMaxProbes = 1,
  });

  /// A policy that never opens the breaker (`failureThreshold` set to
  /// the JS-`Number.MAX_SAFE_INTEGER` equivalent). Useful in tests
  /// that want to exercise retry in isolation.
  static const WebCircuitBreakerPolicy disabled = WebCircuitBreakerPolicy(
    failureThreshold: 1 << 31,
  );
}

/// Thrown by [RetryingWebHttpClient] when the circuit breaker for the
/// target's bucket is open. No inner HTTP call is made — the breaker
/// short-circuits to surface fast so callers can fall back to a
/// different provider or fail visibly rather than queuing up against a
/// downstream that has already failed `failureThreshold` times in a
/// row.
///
/// The [retryAfter] field carries the wall-clock duration until the
/// breaker is next eligible for a half-open probe (computed from the
/// configured [WebCircuitBreakerPolicy.cooldown] minus elapsed time).
class CircuitBreakerOpen implements Exception {
  /// The URL whose host bucket is currently open.
  final Uri url;

  /// The breaker-key bucket that is open (typically the host of [url],
  /// but the caller can pin a different key via
  /// [RetryingWebHttpClient.breakerKey]).
  final String bucket;

  /// Time until the breaker is eligible for a half-open probe. `null`
  /// when the policy is not time-bounded (should not happen with the
  /// shipped policy shape).
  final Duration retryAfter;

  CircuitBreakerOpen({
    required this.url,
    required this.bucket,
    required this.retryAfter,
  });

  @override
  String toString() =>
      'CircuitBreakerOpen(bucket="$bucket", url=$url, retryAfter=${retryAfter.inMilliseconds}ms)';
}

/// The trio of breaker states. Held privately by the decorator;
/// surfaced through [RetryingWebHttpClient.debugBreakerState] only for
/// tests.
enum BreakerState {
  /// Calls pass through. Failures increment the consecutive-failure
  /// counter.
  closed,

  /// Breaker is open. Calls short-circuit with [CircuitBreakerOpen].
  /// Transitions to [halfOpen] once the cooldown has elapsed.
  open,

  /// Breaker is testing recovery. At most
  /// [WebCircuitBreakerPolicy.halfOpenMaxProbes] calls may be in
  /// flight. A success transitions back to [closed]; a failure
  /// transitions back to [open] (resets the cooldown).
  halfOpen,
}

/// Per-bucket breaker state record. Not exported; held internally and
/// surfaced through [RetryingWebHttpClient.debugBreakerState] as a
/// read-only snapshot for tests.
class _BreakerEntry {
  BreakerState state = BreakerState.closed;
  int consecutiveFailures = 0;
  DateTime? openedAt;
  int inFlightProbes = 0;
}

/// Read-only snapshot of one bucket's breaker state. Returned by
/// [RetryingWebHttpClient.debugBreakerState].
final class BreakerSnapshot {
  final String bucket;
  final BreakerState state;
  final int consecutiveFailures;
  final DateTime? openedAt;
  final int inFlightProbes;

  const BreakerSnapshot({
    required this.bucket,
    required this.state,
    required this.consecutiveFailures,
    required this.openedAt,
    required this.inFlightProbes,
  });
}

/// `WebHttpClient` decorator that adds retry + circuit-breaker policy
/// around any inner `WebHttpClient` (production: a
/// `TomKernelWebHttpClient`; tests: a fake).
///
/// **Composition pattern**:
///
/// ```dart
/// final inner = TomKernelWebHttpClient(); // package:http via kernel factory
/// final http = RetryingWebHttpClient(
///   inner: inner,
///   retryPolicy: const WebRetryPolicy(),
///   breakerPolicy: const WebCircuitBreakerPolicy(),
/// );
///
/// final webSearch = DefaultWebSearch(
///   defaultProviderId: 'duckduckgo',
///   providers: [DuckDuckGoHtmlSearchProvider(httpClient: http)],
/// );
/// final webFetch = DefaultWebFetch(httpClient: http);
/// ```
///
/// The provider / fetch code does not change; the retry / breaker
/// layer is invisible to them.
class RetryingWebHttpClient implements WebHttpClient {
  final WebHttpClient _inner;
  final WebRetryPolicy retryPolicy;
  final WebCircuitBreakerPolicy breakerPolicy;

  /// `true` when [close] should cascade to the wrapped client.
  final bool _ownsInner;

  /// Test-seams: sleep / clock / random / breaker-key. Production
  /// wiring leaves these at their defaults.
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final Random _random;
  final String Function(Uri)? _breakerKey;

  final Map<String, _BreakerEntry> _breakers = <String, _BreakerEntry>{};
  bool _closed = false;

  RetryingWebHttpClient({
    required WebHttpClient inner,
    this.retryPolicy = const WebRetryPolicy(),
    this.breakerPolicy = const WebCircuitBreakerPolicy(),
    bool ownsInner = true,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    Random? random,
    String Function(Uri)? breakerKey,
  })  : _inner = inner,
        _ownsInner = ownsInner,
        _sleep = sleep ?? Future<void>.delayed,
        _now = clock ?? DateTime.now,
        _random = random ?? Random(),
        _breakerKey = breakerKey {
    if (retryPolicy.maxAttempts < 1) {
      throw ArgumentError.value(
        retryPolicy.maxAttempts,
        'retryPolicy.maxAttempts',
        'maxAttempts must be >= 1',
      );
    }
    if (retryPolicy.backoffMultiplier < 1.0) {
      throw ArgumentError.value(
        retryPolicy.backoffMultiplier,
        'retryPolicy.backoffMultiplier',
        'backoffMultiplier must be >= 1.0',
      );
    }
    if (retryPolicy.jitterFraction < 0.0 || retryPolicy.jitterFraction > 1.0) {
      throw ArgumentError.value(
        retryPolicy.jitterFraction,
        'retryPolicy.jitterFraction',
        'jitterFraction must be in [0.0, 1.0]',
      );
    }
    if (breakerPolicy.failureThreshold < 1) {
      throw ArgumentError.value(
        breakerPolicy.failureThreshold,
        'breakerPolicy.failureThreshold',
        'failureThreshold must be >= 1',
      );
    }
    if (breakerPolicy.halfOpenMaxProbes < 1) {
      throw ArgumentError.value(
        breakerPolicy.halfOpenMaxProbes,
        'breakerPolicy.halfOpenMaxProbes',
        'halfOpenMaxProbes must be >= 1',
      );
    }
  }

  /// Read-only snapshot of one bucket's breaker state. Returns the
  /// "closed, no failures" default for buckets that have never failed.
  /// Test-only surface; production code should not depend on this.
  BreakerSnapshot debugBreakerState(String bucket) {
    final entry = _breakers[bucket];
    if (entry == null) {
      return BreakerSnapshot(
        bucket: bucket,
        state: BreakerState.closed,
        consecutiveFailures: 0,
        openedAt: null,
        inFlightProbes: 0,
      );
    }
    return BreakerSnapshot(
      bucket: bucket,
      state: entry.state,
      consecutiveFailures: entry.consecutiveFailures,
      openedAt: entry.openedAt,
      inFlightProbes: entry.inFlightProbes,
    );
  }

  String _keyFor(Uri url) {
    final keyFn = _breakerKey;
    if (keyFn != null) return keyFn(url);
    return url.host;
  }

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) {
    _checkOpen();
    return _runWithPolicy<WebHttpResponse>(
      url: url,
      idempotent: true,
      attempt: () => _inner.get(
        url,
        headers: headers,
        requestTimeout: requestTimeout,
      ),
      statusOf: (r) => r.statusCode,
      headersOf: (r) => r.headers,
    );
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) {
    _checkOpen();
    return _runWithPolicy<WebHttpResponse>(
      url: url,
      idempotent: retryPolicy.retryPostForm,
      attempt: () => _inner.postForm(
        url,
        form: form,
        headers: headers,
        requestTimeout: requestTimeout,
      ),
      statusOf: (r) => r.statusCode,
      headersOf: (r) => r.headers,
    );
  }

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) {
    _checkOpen();
    return _runWithPolicy<WebHttpBytesResponse>(
      url: url,
      idempotent: true,
      attempt: () => _inner.getBytes(
        url,
        headers: headers,
        requestTimeout: requestTimeout,
        byteBudget: byteBudget,
      ),
      statusOf: (r) => r.statusCode,
      headersOf: (r) => r.headers,
    );
  }

  /// The core retry + breaker engine. Generic over the response shape
  /// so `get` / `postForm` / `getBytes` share one implementation.
  Future<R> _runWithPolicy<R>({
    required Uri url,
    required bool idempotent,
    required Future<R> Function() attempt,
    required int Function(R) statusOf,
    required Map<String, String> Function(R) headersOf,
  }) async {
    final bucket = _keyFor(url);
    _gateBreaker(bucket: bucket, url: url);
    final entry = _breakers.putIfAbsent(bucket, _BreakerEntry.new);
    final wasHalfOpen = entry.state == BreakerState.halfOpen;
    if (wasHalfOpen) entry.inFlightProbes += 1;

    var attemptNo = 0;
    final maxAttempts = idempotent ? retryPolicy.maxAttempts : 1;

    Duration nextDelay = retryPolicy.initialDelay;

    try {
      while (true) {
        attemptNo += 1;
        R? response;
        Object? caught;
        try {
          response = await attempt();
        } on WebHttpTransportException catch (e) {
          caught = e;
        }

        // Successful response or non-retryable response: commit.
        if (caught == null) {
          final status = statusOf(response as R);
          final retryable = retryPolicy.isRetryableStatus(status);
          if (!retryable || attemptNo >= maxAttempts) {
            // Success-or-non-retryable terminal outcome.
            // 2xx counts as success; non-2xx + non-retryable counts
            // as success-from-breaker's-point-of-view (the upstream
            // answered; the *content* is a client / not-found / etc.
            // failure that the caller will surface).
            if (status >= 500 && !retryable) {
              // 5xx that we elected not to retry (e.g. policy
              // excluded a code) still trips the breaker on the
              // way out.
              _recordFailure(entry);
            } else if (retryable) {
              // Retryable status that exhausted attempts is a failure.
              _recordFailure(entry);
            } else {
              _recordSuccess(entry);
            }
            return response;
          }
          // Retryable + budget remaining → schedule a retry.
          final retryAfter =
              retryPolicy.honourRetryAfterHeader && (status == 429 || status == 503)
                  ? _parseRetryAfter(headersOf(response), _now())
                  : null;
          final delay = _pickDelay(nextDelay, retryAfter);
          nextDelay = _advanceDelay(nextDelay);
          await _sleep(delay);
          continue;
        }

        // Transport exception path.
        if (attemptNo >= maxAttempts) {
          _recordFailure(entry);
          throw caught;
        }
        final delay = _pickDelay(nextDelay, null);
        nextDelay = _advanceDelay(nextDelay);
        await _sleep(delay);
      }
    } finally {
      if (wasHalfOpen) {
        entry.inFlightProbes =
            entry.inFlightProbes > 0 ? entry.inFlightProbes - 1 : 0;
      }
    }
  }

  /// Inspects the breaker for [bucket] and either:
  ///   - returns silently (state is `closed` or eligible `halfOpen`),
  ///   - transitions an expired `open` to `halfOpen` and returns,
  ///   - throws [CircuitBreakerOpen] otherwise.
  void _gateBreaker({required String bucket, required Uri url}) {
    final entry = _breakers[bucket];
    if (entry == null || entry.state == BreakerState.closed) return;

    if (entry.state == BreakerState.open) {
      final openedAt = entry.openedAt;
      final now = _now();
      if (openedAt != null && now.difference(openedAt) >= breakerPolicy.cooldown) {
        entry.state = BreakerState.halfOpen;
        entry.inFlightProbes = 0;
        return;
      }
      final elapsed = openedAt == null
          ? Duration.zero
          : now.difference(openedAt);
      final remaining = breakerPolicy.cooldown - elapsed;
      throw CircuitBreakerOpen(
        url: url,
        bucket: bucket,
        retryAfter: remaining.isNegative ? Duration.zero : remaining,
      );
    }

    // halfOpen — allow up to halfOpenMaxProbes concurrent.
    if (entry.inFlightProbes >= breakerPolicy.halfOpenMaxProbes) {
      final openedAt = entry.openedAt;
      final elapsed = openedAt == null
          ? Duration.zero
          : _now().difference(openedAt);
      final remaining = breakerPolicy.cooldown - elapsed;
      throw CircuitBreakerOpen(
        url: url,
        bucket: bucket,
        retryAfter: remaining.isNegative ? Duration.zero : remaining,
      );
    }
  }

  /// Records a successful (or terminal non-failure) outcome: clears
  /// the consecutive-failure counter and closes a half-open breaker.
  void _recordSuccess(_BreakerEntry entry) {
    entry.consecutiveFailures = 0;
    if (entry.state != BreakerState.closed) {
      entry.state = BreakerState.closed;
      entry.openedAt = null;
      entry.inFlightProbes = 0;
    }
  }

  /// Records a failure (transport exception or retry-exhausted
  /// retryable status). Opens the breaker when the threshold is
  /// crossed.
  void _recordFailure(_BreakerEntry entry) {
    if (entry.state == BreakerState.halfOpen) {
      // Half-open probe failed → re-open immediately, reset cooldown.
      entry.state = BreakerState.open;
      entry.openedAt = _now();
      entry.consecutiveFailures = breakerPolicy.failureThreshold;
      return;
    }
    entry.consecutiveFailures += 1;
    if (entry.consecutiveFailures >= breakerPolicy.failureThreshold) {
      entry.state = BreakerState.open;
      entry.openedAt = _now();
    }
  }

  /// Computes the next pre-jitter delay from the current delay by
  /// multiplying and clamping to [WebRetryPolicy.maxDelay].
  Duration _advanceDelay(Duration current) {
    final nextMs = (current.inMilliseconds * retryPolicy.backoffMultiplier).round();
    final capped = nextMs > retryPolicy.maxDelay.inMilliseconds
        ? retryPolicy.maxDelay.inMilliseconds
        : nextMs;
    return Duration(milliseconds: capped);
  }

  /// Returns the delay to actually sleep: `max(base + jitter,
  /// Retry-After)` when the header was honoured, else `base + jitter`.
  /// Jitter is uniform ±[WebRetryPolicy.jitterFraction] of `base`.
  Duration _pickDelay(Duration base, Duration? retryAfter) {
    final jitter = retryPolicy.jitterFraction == 0.0
        ? 0
        : ((2 * _random.nextDouble() - 1) *
                retryPolicy.jitterFraction *
                base.inMilliseconds)
            .round();
    final withJitter = Duration(
      milliseconds: max(0, base.inMilliseconds + jitter),
    );
    if (retryAfter == null) return withJitter;
    return retryAfter > withJitter ? retryAfter : withJitter;
  }

  /// Parses `Retry-After` per RFC 7231 § 7.1.3: either delta-seconds
  /// (`120`) or an HTTP-date (`Wed, 21 Oct 2026 07:28:00 GMT`).
  /// Returns `null` on missing / unparseable header.
  Duration? _parseRetryAfter(Map<String, String> headers, DateTime now) {
    final raw = headers['retry-after']?.trim();
    if (raw == null || raw.isEmpty) return null;
    final asSeconds = int.tryParse(raw);
    if (asSeconds != null) {
      return Duration(seconds: asSeconds < 0 ? 0 : asSeconds);
    }
    try {
      final when = HttpDate.parse(raw);
      final delta = when.difference(now);
      return delta.isNegative ? Duration.zero : delta;
    } on Exception {
      return null;
    }
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('RetryingWebHttpClient called after close()');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsInner) {
      _inner.close();
    }
  }
}

// `HttpDate` (RFC 7231 parser, web-safe — no `dart:io`) now lives in
// `tom_core_agentic` and is imported above. It is used by
// `_parseRetryAfter` to honour an absolute `Retry-After` header date.
