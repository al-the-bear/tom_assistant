// B.30 — `DefaultWebFetch`: substrate's default `WebFetch`
// implementation. Streams a single GET through the shared
// `WebHttpClient` seam, enforces a byte budget, classifies the
// response by content-type, and produces a `WebFetchResult` with
// exactly one populated body field (text / json / binaryMeta) per
// spec § 8.2.
//
// Why "default": only one fetch strategy ships at B.30. The shape of
// the abstract `WebFetch` surface (`web_fetch.dart`) leaves room for
// future variants — cache layers, mirror fallback — without rewriting
// the dispatch logic here.
//
// Robots.txt enforcement (Q-B.30.3) IS owned here: every fetch is gated
// through a `RobotsGate` (`robots_policy.dart`) before any body is read,
// unless the caller passed `WebFetchOptions.obeyRobots: false` (the
// per-route override of spec § 8.2). A disallow — or an unreachable
// robots.txt (fail closed, RFC 9309 § 2.3.1.4) — raises
// `WebFetchRobotsDenied` and no request to the target URL is made.
//
// What this class deliberately does NOT own:
//
//   - Retry / circuit-breaker policy on transport failures. That lives
//     at B.31 (rewires `WebHttpClient` to `tom_core_kernel.HttpClient`)
//     and applies uniformly to all web tools via the shared seam.
//   - Substrate-event emission (`WebFetchCompleted`). The event is
//     emitted by the substrate facade (B.40+) wrapping `fetch`; this
//     class is silent on observability.
//   - Pre-flight `HEAD` to size-check before reading. The budget
//     enforcement at read time covers the same need without an extra
//     round-trip.

import 'dart:convert';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../api/web_results.dart';
import 'html_readable_extractor.dart';
import 'robots_policy.dart';
import 'web_fetch.dart';
import 'web_http_client.dart';

/// Default `WebFetch` implementation — one GET through the shared
/// `WebHttpClient` seam, with content-type dispatch.
///
/// Construction:
///
/// ```dart
/// final webFetch = DefaultWebFetch(
///   httpClient: webHttp,
///   defaultBudgetBytes: 256 * 1024,
///   userAgent: 'TomBrain/0.1 (+https://tom-brain.local)',
///   requestTimeout: const Duration(seconds: 20),
/// );
/// ```
///
/// **Content-type dispatch (spec § 8.2 table):**
///
///   - `text/html` → readable-text strip via [extractReadableHtml].
///     The result lands in [WebFetchResult.text].
///   - `application/json`, `*/*+json` → UTF-8 decode → `jsonDecode`.
///     The result lands in [WebFetchResult.json].
///   - `text/*` (other) → UTF-8 decode → passthrough into
///     [WebFetchResult.text].
///   - `application/pdf` → raises [WebFetchUnsupportedType] (spec § 12
///     row "Web fetch unsupported content type").
///   - everything else → [BinaryFetchMeta] only ([WebFetchResult.binaryMeta]
///     populated; [WebFetchResult.text] and [WebFetchResult.json] null).
///
/// **Budget enforcement:** the substrate streams up to
/// [WebFetchOptions.budgetBytes] (or [defaultBudgetBytes] when null)
/// and surfaces a partial body with `truncated: true`. A truncated
/// response is still classified by content-type — even an HTML strip
/// runs on the partial bytes, which produces clipped prose rather
/// than an exception. Callers that need a complete body re-fetch with
/// a larger budget.
///
/// **Header policy:** the `User-Agent` header is forced from
/// [userAgent] — caller-supplied `User-Agent` in
/// [WebFetchOptions.headers] is overridden. All other caller headers
/// pass through verbatim.
///
/// **Lifecycle:** [close] forwards to the underlying
/// [WebHttpClient] when this engine owns it (i.e. the caller did not
/// inject one). Idempotent.
class DefaultWebFetch with CloseGuard implements WebFetch {
  /// Substrate-wide budget when the caller does not pin one.
  /// Default 256 KiB per `substrate_specification.md` § 9
  /// (`webFetch.defaultBudgetBytes`).
  static const int defaultBudgetBytesDefault = 256 * 1024;

  /// Stable User-Agent string. Spec § 9 attributes the substrate-wide
  /// UA to `SubstrateConfig.webFetch.userAgent`; until the loader
  /// lands (B.36) this class accepts the UA as a constructor
  /// parameter with a stable default.
  static const String userAgentDefault =
      'TomBrain/0.1 (+https://tom-brain.local) WebFetch';

  /// Default per-request timeout. `null` ⇒ no cap (the transport's
  /// own socket timeout still applies). 30 s is generous for a single
  /// page download under the default 256 KiB budget; consumers that
  /// need tighter bounds inject a shorter value or wrap the call in
  /// `Future.timeout` themselves.
  static const Duration requestTimeoutDefault = Duration(seconds: 30);

  /// Maximum bytes the substrate reads when the caller did not pin a
  /// per-call budget. Used as `budgetBytes` when
  /// [WebFetchOptions.budgetBytes] is null.
  final int defaultBudgetBytes;

  /// User-Agent string the substrate forces on every fetch.
  final String userAgent;

  /// Per-request timeout passed through to the underlying
  /// [WebHttpClient.getBytes] call.
  final Duration? requestTimeout;

  final WebHttpClient _http;
  final bool _ownsClient;
  final RobotsGate _robots;

  DefaultWebFetch({
    WebHttpClient? httpClient,
    int defaultBudgetBytes = defaultBudgetBytesDefault,
    String userAgent = userAgentDefault,
    Duration? requestTimeout = requestTimeoutDefault,
    RobotsGate? robotsGate,
  }) : this._(
          httpClient ?? DefaultWebHttpClient(),
          ownsClient: httpClient == null,
          defaultBudgetBytes: defaultBudgetBytes,
          userAgent: userAgent,
          requestTimeout: requestTimeout,
          robotsGate: robotsGate,
        );

  // Private constructor with the resolved [WebHttpClient] in scope, so
  // the default [RobotsGate] shares the *same* client as the fetch path
  // (one client, not two) and the validation runs once.
  DefaultWebFetch._(
    this._http, {
    required bool ownsClient,
    required this.defaultBudgetBytes,
    required this.userAgent,
    required this.requestTimeout,
    RobotsGate? robotsGate,
  })  : _ownsClient = ownsClient,
        _robots = robotsGate ??
            RobotsGate(
              httpClient: _http,
              userAgent: userAgent,
              requestTimeout: requestTimeout,
            ) {
    if (defaultBudgetBytes < 0) {
      throw ArgumentError.value(
        defaultBudgetBytes,
        'defaultBudgetBytes',
        'defaultBudgetBytes must be >= 0',
      );
    }
    if (userAgent.isEmpty) {
      throw ArgumentError.value(
        userAgent,
        'userAgent',
        'userAgent must be non-empty (substrate forces a UA on every fetch)',
      );
    }
  }

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    ensureOpen('DefaultWebFetch.fetch');
    if (options.method != 'GET') {
      throw ArgumentError.value(
        options.method,
        'options.method',
        'DefaultWebFetch supports only GET at B.30 (spec § 8.2)',
      );
    }
    final budget = options.budgetBytes ?? defaultBudgetBytes;
    if (budget < 0) {
      throw ArgumentError.value(
        budget,
        'options.budgetBytes',
        'budgetBytes must be >= 0',
      );
    }

    // Robots.txt gate (spec § 8.2; Q-B.30.3). Skipped only when the
    // caller explicitly opts out (`obeyRobots: false`). Refusal happens
    // before any request to `url` is made.
    if (options.obeyRobots) {
      final denial = await _robots.evaluate(url);
      if (denial != null) {
        throw WebFetchRobotsDenied(url: url, reason: denial);
      }
    }

    final mergedHeaders = <String, String>{
      ...options.headers,
      // Force the UA last so caller-supplied UA is overridden.
      'User-Agent': userAgent,
    };

    final response = await _http.getBytes(
      url,
      headers: mergedHeaders,
      requestTimeout: requestTimeout,
      byteBudget: budget,
    );

    final rawContentType = response.headers['content-type'] ?? '';
    final normalised = _normaliseContentType(rawContentType);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebFetchHttpException(
        url: response.url,
        statusCode: response.statusCode,
        contentType: rawContentType.isEmpty ? null : rawContentType,
        bodyExcerpt: _bodyExcerpt(response.bodyBytes),
      );
    }

    // Content-type dispatch.
    if (normalised == 'application/pdf') {
      throw WebFetchUnsupportedType(
        url: response.url,
        contentType: normalised,
        rawContentType: rawContentType,
      );
    }

    if (normalised == 'application/json' || normalised.endsWith('+json')) {
      return _buildJsonResult(response, normalised);
    }

    if (normalised == 'text/html') {
      return _buildHtmlResult(response, normalised);
    }

    if (normalised.startsWith('text/')) {
      return _buildPlainTextResult(response, normalised);
    }

    // Everything else → binary metadata only.
    return WebFetchResult(
      url: response.url,
      status: response.statusCode,
      contentType: normalised,
      binaryMeta: BinaryFetchMeta(
        contentType: rawContentType.isEmpty ? normalised : rawContentType,
        contentLength: response.contentLength,
      ),
      truncated: response.truncated,
      contentBytes: response.bodyBytes.length,
    );
  }

  WebFetchResult _buildHtmlResult(
    WebHttpBytesResponse response,
    String normalised,
  ) {
    final text = extractReadableHtml(response.bodyBytes);
    return WebFetchResult(
      url: response.url,
      status: response.statusCode,
      contentType: normalised,
      text: text,
      truncated: response.truncated,
      contentBytes: response.bodyBytes.length,
    );
  }

  WebFetchResult _buildPlainTextResult(
    WebHttpBytesResponse response,
    String normalised,
  ) {
    // Plain text: decode UTF-8 (allowMalformed: true so a stray byte
    // does not throw — for text/* the substrate's contract is that
    // partial / lossy decode is better than failing the fetch).
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    return WebFetchResult(
      url: response.url,
      status: response.statusCode,
      contentType: normalised,
      text: text,
      truncated: response.truncated,
      contentBytes: response.bodyBytes.length,
    );
  }

  WebFetchResult _buildJsonResult(
    WebHttpBytesResponse response,
    String normalised,
  ) {
    // Truncated JSON is almost always invalid. We surface the
    // truncation via `WebFetchResult.truncated` and let `jsonDecode`
    // throw a verbatim `FormatException` when the body is invalid —
    // a server claiming JSON that sends invalid JSON is a server bug,
    // not something the substrate should mask. The caller's trail
    // (B.40+ facade) will capture both the truncation flag and the
    // parse failure.
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    final parsed = jsonDecode(body);
    return WebFetchResult(
      url: response.url,
      status: response.statusCode,
      contentType: normalised,
      json: parsed,
      truncated: response.truncated,
      contentBytes: response.bodyBytes.length,
    );
  }

  @override
  void close() {
    if (!markClosed()) return;
    if (_ownsClient) {
      _http.close();
    }
  }
}

/// Strips parameters from a `Content-Type` header and lower-cases the
/// `type/subtype` form. `'TEXT/HTML; charset=utf-8'` → `'text/html'`;
/// `''` → `''`.
String _normaliseContentType(String raw) {
  if (raw.isEmpty) return '';
  final semi = raw.indexOf(';');
  final core = semi == -1 ? raw : raw.substring(0, semi);
  return core.trim().toLowerCase();
}

/// First ~512 bytes decoded as UTF-8 (lossy) for the trail-side body
/// excerpt on error responses.
String _bodyExcerpt(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final slice = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
  return utf8.decode(slice, allowMalformed: true);
}
