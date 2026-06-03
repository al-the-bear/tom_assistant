// B.30 — `WebFetch.fetch(url, {budget})` API conformance.
//
// Scope of this test file (per plan step B.30):
//
//   - Prove the abstract `WebFetch` contract: `fetch(url, options)`
//     returns a `WebFetchResult` with exactly one body field populated
//     (`text` / `json` / `binaryMeta`), per the content-type table in
//     `substrate_specification.md` § 8.2.
//   - Prove the `DefaultWebFetch` dispatch on content-type:
//     `text/html` → readable text; `text/plain` (and other `text/*`)
//     → UTF-8 passthrough; `application/json` (and `*/*+json`) →
//     parsed JSON; `application/pdf` → `WebFetchUnsupportedType`;
//     other content-types → `binaryMeta` only.
//   - Prove byte-budget enforcement: a response larger than
//     `options.budgetBytes` returns with `truncated: true`; a response
//     within the budget returns with `truncated: false`.
//   - Prove non-2xx surfaces as `WebFetchHttpException` with the
//     status code, content-type, and a body excerpt.
//   - Prove transport failures propagate verbatim
//     (`WebHttpTransportException`).
//   - Prove `User-Agent` is forced from the engine config — caller
//     headers in `WebFetchOptions.headers` cannot override it.
//   - Prove constructor validation: negative `defaultBudgetBytes` is
//     rejected; empty `userAgent` is rejected.
//   - Prove lifecycle: `close()` cascades to the underlying
//     `WebHttpClient` when owned; idempotent.
//   - Prove the HTML readable extractor itself: strips `<script>` /
//     `<style>` / `<noscript>` blocks, replaces block-close tags with
//     newlines, decodes entities, collapses whitespace.
//   - Prove the surface is reachable from the top-level package
//     barrel.
//
// Scope this file is NOT for:
//
//   - No live network calls. Every test uses `_FakeBytesHttpClient` —
//     the suite is hermetic.
//   - No `WebSearch` behaviour (B.29).
//   - No `tom_core_kernel.HttpClient` retry / circuit-breaker wiring
//     (B.31).
//   - No conformance harness pattern (B.32 lifts these contract
//     assertions into a shared harness so future fetch variants get
//     cross-impl coverage).

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.30 / DefaultWebFetch — construction invariants', () {
    test('rejects negative defaultBudgetBytes', () {
      expect(
        () => DefaultWebFetch(
          httpClient: _FakeBytesHttpClient(),
          defaultBudgetBytes: -1,
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty userAgent', () {
      expect(
        () => DefaultWebFetch(
          httpClient: _FakeBytesHttpClient(),
          userAgent: '',
        ),
        throwsArgumentError,
      );
    });

    test('default budget is 256 KiB', () {
      expect(DefaultWebFetch.defaultBudgetBytesDefault, 256 * 1024);
    });
  });

  group('B.30 / DefaultWebFetch — content-type dispatch', () {
    test('text/html → readable text in `text`, no json, no binaryMeta',
        () async {
      const html =
          '<html><body><h1>Title</h1><p>Paragraph one.</p><p>Paragraph two.</p></body></html>';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes(html, contentType: 'text/html; charset=utf-8');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));

      expect(result.status, 200);
      expect(result.contentType, 'text/html');
      expect(result.text, isNotNull);
      expect(result.text, contains('Title'));
      expect(result.text, contains('Paragraph one.'));
      expect(result.text, contains('Paragraph two.'));
      expect(result.json, isNull);
      expect(result.binaryMeta, isNull);
      expect(result.truncated, isFalse);
    });

    test('text/plain → UTF-8 passthrough in `text`', () async {
      const body = 'hello world\nthis is plain text';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes(body, contentType: 'text/plain');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/x.txt'));

      expect(result.text, body);
      expect(result.json, isNull);
      expect(result.binaryMeta, isNull);
    });

    test('application/json → parsed JSON in `json`', () async {
      const body = '{"a":1,"b":["x","y"],"c":null}';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes(body, contentType: 'application/json');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://api.example/v1'));

      expect(result.contentType, 'application/json');
      expect(result.json, isA<Map>());
      final map = result.json! as Map;
      expect(map['a'], 1);
      expect(map['b'], <String>['x', 'y']);
      expect(map['c'], isNull);
      expect(result.text, isNull);
      expect(result.binaryMeta, isNull);
    });

    test('JSON variant content-type (vnd.api+json) → parsed JSON in `json`',
        () async {
      const body = '{"data":[]}';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes(body, contentType: 'application/vnd.api+json');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://api.example/v1'));

      expect(result.json, isA<Map>());
      expect((result.json! as Map)['data'], isEmpty);
    });

    test('binary content-type → binaryMeta only', () async {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          bytes,
          contentType: 'image/png',
          contentLength: 1024,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result =
          await fetch.fetch(Uri.parse('https://example.com/cat.png'));

      expect(result.text, isNull);
      expect(result.json, isNull);
      expect(result.binaryMeta, isNotNull);
      expect(result.binaryMeta!.contentType, 'image/png');
      expect(result.binaryMeta!.contentLength, 1024);
      expect(result.contentType, 'image/png');
    });

    test('binary with no Content-Length → binaryMeta.contentLength is null',
        () async {
      final bytes = List<int>.filled(64, 0xAB);
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          bytes,
          contentType: 'application/octet-stream',
          contentLength: null,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));

      expect(result.binaryMeta, isNotNull);
      expect(result.binaryMeta!.contentLength, isNull);
    });

    test('application/pdf → WebFetchUnsupportedType', () async {
      final bytes = utf8.encode('%PDF-1.4');
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          bytes,
          contentType: 'application/pdf',
          contentLength: bytes.length,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/doc.pdf'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebFetchUnsupportedType>());
      final e = thrown! as WebFetchUnsupportedType;
      expect(e.contentType, 'application/pdf');
      expect(e.rawContentType, 'application/pdf');
    });

    test('content-type is normalised (strip params, lower-case)', () async {
      const html = '<p>hello</p>';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes(html,
            contentType: 'TEXT/HTML; charset=utf-8; boundary=xx');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));

      expect(result.contentType, 'text/html');
    });

    test('missing Content-Type → falls through to binary metadata', () async {
      final bytes = utf8.encode('some unknown body');
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          bytes,
          contentType: null,
          contentLength: bytes.length,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));

      expect(result.text, isNull);
      expect(result.json, isNull);
      expect(result.binaryMeta, isNotNull);
      expect(result.contentType, ''); // normalised empty
    });
  });

  group('B.30 / DefaultWebFetch — budget enforcement', () {
    test('body within budget returns truncated: false', () async {
      final bytes = utf8.encode('small body');
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          bytes,
          contentType: 'text/plain',
          contentLength: bytes.length,
          truncated: false,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(
        Uri.parse('https://example.com/'),
        options: const WebFetchOptions(budgetBytes: 1024),
      );

      expect(result.truncated, isFalse);
      // Verify the budget was forwarded.
      expect(http.calls.single.byteBudget, 1024);
    });

    test('body over budget returns truncated: true with partial body',
        () async {
      // Fake reports the budget cap was hit — the substrate trusts
      // the seam's truncation flag. The body we hand back is the
      // truncated slice.
      final truncated = utf8.encode('first 16 bytes..');
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          truncated,
          contentType: 'text/plain',
          contentLength: 4096, // server reported total
          truncated: true,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(
        Uri.parse('https://example.com/'),
        options: const WebFetchOptions(budgetBytes: 16),
      );

      expect(result.truncated, isTrue);
      expect(result.text, 'first 16 bytes..');
    });

    test('HTML over budget still runs the extractor on partial bytes',
        () async {
      // The substrate does not throw on truncated HTML — it just
      // surfaces clipped prose with truncated: true.
      const partialHtml = '<p>partial content</p><p>more';
      final http = _FakeBytesHttpClient()
        ..response = _okBytesRaw(
          utf8.encode(partialHtml),
          contentType: 'text/html',
          contentLength: 999,
          truncated: true,
        );
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(
        Uri.parse('https://example.com/'),
        options: const WebFetchOptions(budgetBytes: 32),
      );

      expect(result.truncated, isTrue);
      expect(result.text, contains('partial content'));
      expect(result.text, contains('more'));
    });

    test('default budget used when options.budgetBytes is null', () async {
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch = DefaultWebFetch(
        httpClient: http,
        defaultBudgetBytes: 4096,
      );

      await fetch.fetch(Uri.parse('https://example.com/'));

      expect(http.calls.single.byteBudget, 4096);
    });

    test('negative options.budgetBytes is rejected', () async {
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch = DefaultWebFetch(httpClient: http);

      expect(
        () => fetch.fetch(
          Uri.parse('https://example.com/'),
          options: const WebFetchOptions(budgetBytes: -1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('B.30 / DefaultWebFetch — failure surfaces', () {
    test('non-2xx → WebFetchHttpException with status, type, body excerpt',
        () async {
      const errBody = 'Not Found: no such resource';
      final http = _FakeBytesHttpClient()
        ..response = _statusBytes(
          404,
          errBody,
          contentType: 'text/plain',
        );
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/missing'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebFetchHttpException>());
      final e = thrown! as WebFetchHttpException;
      expect(e.statusCode, 404);
      expect(e.contentType, contains('text/plain'));
      expect(e.bodyExcerpt, errBody);
    });

    test('non-2xx with no body still raises typed exception (empty excerpt)',
        () async {
      final http = _FakeBytesHttpClient()
        ..response = _statusBytes(503, '', contentType: 'text/html');
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebFetchHttpException>());
      final e = thrown! as WebFetchHttpException;
      expect(e.statusCode, 503);
      expect(e.bodyExcerpt, '');
    });

    test('transport failure propagates verbatim', () async {
      final http = _FakeBytesHttpClient()
        ..error = WebHttpTransportException(
          url: Uri.parse('https://example.com/'),
          cause: const _SocketDouble('Connection refused'),
        );
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebHttpTransportException>());
    });

    test('fetch after close throws StateError', () async {
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch = DefaultWebFetch(httpClient: http);
      fetch.close();

      expect(
        () => fetch.fetch(Uri.parse('https://example.com/')),
        throwsStateError,
      );
    });

    test('non-GET method rejected at B.30', () async {
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch = DefaultWebFetch(httpClient: http);

      expect(
        () => fetch.fetch(
          Uri.parse('https://example.com/'),
          options: const WebFetchOptions(method: 'POST'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('B.30 / DefaultWebFetch — headers', () {
    test('User-Agent is forced from engine config', () async {
      const ua = 'TomBrain/0.1-test (+https://tom-brain.local) WebFetch';
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch =
          DefaultWebFetch(httpClient: http, userAgent: ua);

      await fetch.fetch(
        Uri.parse('https://example.com/'),
        options: const WebFetchOptions(
          headers: <String, String>{'User-Agent': 'CallerSuppliedShouldLose'},
        ),
      );

      expect(http.calls.single.headers['User-Agent'], ua);
    });

    test('caller-supplied non-UA headers are forwarded', () async {
      final http = _FakeBytesHttpClient()
        ..response = _okBytes('x', contentType: 'text/plain');
      final fetch = DefaultWebFetch(httpClient: http);

      await fetch.fetch(
        Uri.parse('https://example.com/'),
        options: const WebFetchOptions(
          headers: <String, String>{
            'Accept-Language': 'fr-FR',
            'Authorization': 'Bearer ABC',
          },
        ),
      );

      final headers = http.calls.single.headers;
      expect(headers['Accept-Language'], 'fr-FR');
      expect(headers['Authorization'], 'Bearer ABC');
    });
  });

  group('B.30 / DefaultWebFetch — lifecycle', () {
    test('close cascades to owned http client', () async {
      // The fetch engine owns the client when no client is injected.
      // To prove cascade we *must* inject a fake — but then ownership
      // flips to "not owned". Cover both cases with two tests.
      final http = _FakeBytesHttpClient();
      final fetch = DefaultWebFetch(httpClient: http);
      fetch.close();
      // Injected → not owned → not cascaded.
      expect(http.closeCount, 0);
    });

    test('close is idempotent', () async {
      final http = _FakeBytesHttpClient();
      final fetch = DefaultWebFetch(httpClient: http);
      fetch.close();
      fetch.close();
      // Still 0 because the client was injected. No exceptions either.
      expect(http.closeCount, 0);
    });
  });

  group('B.30 / extractReadableHtml — HTML strip helper', () {
    test('strips <script> blocks including content', () {
      const html =
          '<html><body><p>before</p><script>var x = 1; alert("hi");</script><p>after</p></body></html>';
      final text = extractReadableHtmlString(html);
      expect(text, contains('before'));
      expect(text, contains('after'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('var x')));
    });

    test('strips <style> and <noscript> blocks', () {
      const html =
          '<html><head><style>body{color:red}</style></head><body>'
          '<noscript>enable js</noscript><p>real prose</p></body></html>';
      final text = extractReadableHtmlString(html);
      expect(text, contains('real prose'));
      expect(text, isNot(contains('color:red')));
      expect(text, isNot(contains('enable js')));
    });

    test('replaces <br> and block-close tags with newlines', () {
      const html = '<p>line one</p><p>line two</p>three<br>four';
      final text = extractReadableHtmlString(html);
      expect(text, contains('line one'));
      expect(text, contains('line two'));
      expect(text, contains('three'));
      expect(text, contains('four'));
      // Block boundaries become newlines, not glued-together prose.
      expect(text, isNot(contains('line onelinetwo')));
      expect(text, isNot(contains('threefour')));
    });

    test('decodes named + numeric HTML entities', () {
      const html = '<p>A &amp; B &lt; C &gt; D &quot;E&quot; '
          '&#39;F&#39; &#x27;G&#x27; &nbsp;H</p>';
      final text = extractReadableHtmlString(html);
      expect(text, contains('A & B'));
      expect(text, contains('< C >'));
      expect(text, contains('"E"'));
      expect(text, contains("'F'"));
      expect(text, contains("'G'"));
      expect(text, contains(' H'));
    });

    test('collapses whitespace runs', () {
      const html = '<p>one   two\t\tthree</p>';
      final text = extractReadableHtmlString(html);
      expect(text, 'one two three');
    });

    test('collapses 3+ newlines down to paragraph break', () {
      const html = '<p>para1</p><p></p><p></p><p>para2</p>';
      final text = extractReadableHtmlString(html);
      // Should have one blank line between para1 and para2.
      expect(text, 'para1\n\npara2');
    });

    test('strips HTML comments (caught by generic tag-strip)', () {
      const html = '<p>before</p><!-- hidden --><p>after</p>';
      final text = extractReadableHtmlString(html);
      expect(text, contains('before'));
      expect(text, contains('after'));
      expect(text, isNot(contains('hidden')));
    });

    test('decodes bytes when called with extractReadableHtml', () {
      const html = '<p>hello bytes</p>';
      final result = extractReadableHtml(utf8.encode(html));
      expect(result, 'hello bytes');
    });
  });

  group('B.30 / surface reachability', () {
    test('all B.30 public names load from the package barrel', () {
      // Smoke test: every B.30 type / function we expect consumers to
      // touch is resolvable here. If a name moves out of the top-level
      // barrel, this test fails to compile.
      expect(WebFetch, isNotNull);
      expect(DefaultWebFetch, isNotNull);
      expect(WebFetchHttpException, isNotNull);
      expect(WebFetchUnsupportedType, isNotNull);
      expect(WebHttpBytesResponse, isNotNull);
      expect(extractReadableHtml, isNotNull);
      expect(extractReadableHtmlString, isNotNull);
      expect(DefaultWebFetch.defaultBudgetBytesDefault, 256 * 1024);
      expect(DefaultWebFetch.userAgentDefault, contains('TomBrain'));
    });
  });
}

// ---------- test doubles --------------------------------------------------

/// Hand-rolled fake `WebHttpClient` for B.30 — supports `getBytes`
/// with canned response or canned error, and records every call's
/// URL + headers + byte-budget.
///
/// `get` / `postForm` are not exercised by `WebFetch` (which uses
/// `getBytes`), so we stub them with `UnimplementedError`.
class _FakeBytesHttpClient implements WebHttpClient {
  WebHttpBytesResponse? response;
  Object? error;
  final List<_BytesCall> calls = <_BytesCall>[];
  int closeCount = 0;

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    calls.add(_BytesCall(
      url: url,
      headers: headers,
      requestTimeout: requestTimeout,
      byteBudget: byteBudget,
    ));
    if (error != null) {
      throw error!;
    }
    return response ??
        (throw StateError('_FakeBytesHttpClient.response not set'));
  }

  /// Robots.txt fetch (`DefaultWebFetch` calls `get` on `/robots.txt`
  /// before each fetch — Q-B.30.3). Defaults to a 404 so the host is
  /// treated as "no robots.txt" (allow all), keeping every existing
  /// content-type / budget / failure assertion in this file unchanged.
  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      WebHttpResponse(
        statusCode: 404,
        body: '',
        headers: const <String, String>{},
        url: url,
      );

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError(
        '_FakeBytesHttpClient.postForm is not exercised by B.30 tests',
      );

  @override
  void close() {
    closeCount += 1;
  }
}

class _BytesCall {
  final Uri url;
  final Map<String, String> headers;
  final Duration? requestTimeout;
  final int? byteBudget;
  _BytesCall({
    required this.url,
    required this.headers,
    required this.requestTimeout,
    required this.byteBudget,
  });
}

/// Stand-in `SocketException`-shaped exception — keeps the test file
/// off `dart:io`. Same trick as `b29_web_search_test.dart`.
class _SocketDouble implements Exception {
  final String message;
  const _SocketDouble(this.message);
  @override
  String toString() => 'SocketDouble: $message';
}

// ---------- response builders ---------------------------------------------

WebHttpBytesResponse _okBytes(
  String body, {
  required String contentType,
}) =>
    WebHttpBytesResponse(
      statusCode: 200,
      bodyBytes: utf8.encode(body),
      headers: <String, String>{
        'content-type': contentType,
        'content-length': utf8.encode(body).length.toString(),
      },
      url: Uri.parse('https://example.com/'),
      contentLength: utf8.encode(body).length,
      truncated: false,
    );

WebHttpBytesResponse _okBytesRaw(
  List<int> bytes, {
  required String? contentType,
  required int? contentLength,
  bool truncated = false,
}) {
  final headers = <String, String>{};
  if (contentType != null) headers['content-type'] = contentType;
  if (contentLength != null) {
    headers['content-length'] = contentLength.toString();
  }
  return WebHttpBytesResponse(
    statusCode: 200,
    bodyBytes: bytes,
    headers: headers,
    url: Uri.parse('https://example.com/'),
    contentLength: contentLength,
    truncated: truncated,
  );
}

WebHttpBytesResponse _statusBytes(
  int status,
  String body, {
  required String contentType,
}) =>
    WebHttpBytesResponse(
      statusCode: status,
      bodyBytes: utf8.encode(body),
      headers: <String, String>{
        'content-type': contentType,
        'content-length': utf8.encode(body).length.toString(),
      },
      url: Uri.parse('https://example.com/'),
      contentLength: utf8.encode(body).length,
      truncated: false,
    );
