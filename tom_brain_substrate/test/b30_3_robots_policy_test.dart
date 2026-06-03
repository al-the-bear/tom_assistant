// Q-B.30.3 — robots.txt enforcement for `WebFetch`.
//
// substrate_specification.md § 8.2: "Robots.txt is honoured per host
// with a configurable opt-out per route." These tests pin the three
// layers that implement it:
//
//   1. `parseRobotsTxt` / `RobotsRules` — RFC 9309 group selection and
//      Allow/Disallow precedence (longest-match wins, Allow beats
//      Disallow on a tie, `*` / `$` wildcards, query-string matching).
//   2. `RobotsGate` — per-host fetch + cache of `/robots.txt`, with the
//      RFC 9309 § 2.3.1 fetch-outcome mapping (2xx parse, 4xx allow,
//      5xx / transport-unreachable fail closed).
//   3. `DefaultWebFetch` integration — a disallow (or unreachable
//      robots) refuses the fetch with `WebFetchRobotsDenied` *before*
//      the body request; `obeyRobots: false` bypasses the gate.
//
// No live network: every test drives a hand-rolled `WebHttpClient` fake.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('Q-B.30.3 / robotsProductToken', () {
    test('takes the token before the first slash', () {
      expect(robotsProductToken('TomBrain/0.1 (+https://x) WebFetch'),
          'tombrain');
    });

    test('takes the token before the first space when no slash', () {
      expect(robotsProductToken('SomeBot crawler'), 'somebot');
    });

    test('lower-cases and trims', () {
      expect(robotsProductToken('  GoogleBot  '), 'googlebot');
    });
  });

  group('Q-B.30.3 / robotsMatchPath', () {
    test('empty path becomes "/"', () {
      expect(robotsMatchPath(Uri.parse('https://example.com')), '/');
    });

    test('query string is appended', () {
      expect(robotsMatchPath(Uri.parse('https://example.com/s?q=1&p=2')),
          '/s?q=1&p=2');
    });

    test('path without query is left as-is', () {
      expect(robotsMatchPath(Uri.parse('https://example.com/a/b')), '/a/b');
    });
  });

  group('Q-B.30.3 / parseRobotsTxt + RobotsRules', () {
    test('empty robots.txt allows everything', () {
      final rules = parseRobotsTxt('', 'tombrain');
      expect(rules.isAllowed('/anything'), isTrue);
    });

    test('Disallow blocks the matching prefix, allows the rest', () {
      const txt = 'User-agent: *\nDisallow: /private';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/private/page'), isFalse);
      expect(rules.isAllowed('/public'), isTrue);
    });

    test('empty Disallow value is a no-op (allow all)', () {
      const txt = 'User-agent: *\nDisallow:';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/anything'), isTrue);
    });

    test('Allow overrides a Disallow of equal specificity (tie → allow)', () {
      const txt = 'User-agent: *\nDisallow: /a\nAllow: /a';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/a'), isTrue);
    });

    test('longest matching pattern wins (Allow longer than Disallow)', () {
      const txt =
          'User-agent: *\nDisallow: /folder\nAllow: /folder/public';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/folder/secret'), isFalse);
      expect(rules.isAllowed('/folder/public/x'), isTrue);
    });

    test('longest matching pattern wins (Disallow longer than Allow)', () {
      const txt = 'User-agent: *\nAllow: /a\nDisallow: /a/secret';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/a/open'), isTrue);
      expect(rules.isAllowed('/a/secret/x'), isFalse);
    });

    test('"*" wildcard matches any run of characters', () {
      const txt = 'User-agent: *\nDisallow: /*/admin';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/team/admin'), isFalse);
      expect(rules.isAllowed('/team/members'), isTrue);
    });

    test('"\$" anchors the pattern to end of path', () {
      const txt = 'User-agent: *\nDisallow: /*.pdf\$';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/doc.pdf'), isFalse);
      // Not anchored at end → allowed.
      expect(rules.isAllowed('/doc.pdf?download=1'), isTrue);
    });

    test('matching is against path + query string', () {
      const txt = 'User-agent: *\nDisallow: /search?';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/search?q=x'), isFalse);
      expect(rules.isAllowed('/search'), isTrue);
    });

    test('comments are stripped', () {
      const txt = 'User-agent: * # everyone\nDisallow: /x # secret area';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/x/y'), isFalse);
    });

    test('a specific agent group overrides the "*" group', () {
      const txt = 'User-agent: *\nDisallow: /\n\n'
          'User-agent: TomBrain\nDisallow: /private';
      final rules = parseRobotsTxt(txt, 'tombrain');
      // The TomBrain group (specific) applies, not the "*" deny-all.
      expect(rules.isAllowed('/public'), isTrue);
      expect(rules.isAllowed('/private/x'), isFalse);
    });

    test('falls back to the "*" group when no specific agent matches', () {
      const txt = 'User-agent: OtherBot\nDisallow: /\n\n'
          'User-agent: *\nDisallow: /blocked';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/blocked/x'), isFalse);
      expect(rules.isAllowed('/elsewhere'), isTrue);
    });

    test('no matching group at all → allow everything', () {
      const txt = 'User-agent: OtherBot\nDisallow: /';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/anything'), isTrue);
    });

    test('rules appearing before any User-agent line are ignored', () {
      const txt = 'Disallow: /orphan\nUser-agent: *\nDisallow: /real';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/orphan'), isTrue);
      expect(rules.isAllowed('/real/x'), isFalse);
    });

    test('agent matching is case-insensitive', () {
      const txt = 'User-agent: TOMBRAIN\nDisallow: /x';
      final rules = parseRobotsTxt(txt, 'tombrain');
      expect(rules.isAllowed('/x/y'), isFalse);
    });
  });

  group('Q-B.30.3 / RobotsGate fetch-outcome mapping', () {
    test('200 + Disallow → robotsDisallow', () async {
      final http = _RobotsFakeHttp()
        ..robotsBody = 'User-agent: *\nDisallow: /private'
        ..robotsStatus = 200;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);

      expect(await gate.evaluate(Uri.parse('https://example.com/private/x')),
          RobotsDenialReason.robotsDisallow);
      expect(await gate.evaluate(Uri.parse('https://example.com/public')),
          isNull);
    });

    test('404 → allow all (null)', () async {
      final http = _RobotsFakeHttp()..robotsStatus = 404;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);
      expect(await gate.evaluate(Uri.parse('https://example.com/anything')),
          isNull);
    });

    test('500 → robotsUnreachable (fail closed)', () async {
      final http = _RobotsFakeHttp()..robotsStatus = 500;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);
      expect(await gate.evaluate(Uri.parse('https://example.com/x')),
          RobotsDenialReason.robotsUnreachable);
    });

    test('transport failure → robotsUnreachable (fail closed)', () async {
      final http = _RobotsFakeHttp()
        ..robotsError = WebHttpTransportException(
          url: Uri.parse('https://example.com/robots.txt'),
          cause: const _Boom(),
        );
      final gate = RobotsGate(httpClient: http, userAgent: _ua);
      expect(await gate.evaluate(Uri.parse('https://example.com/x')),
          RobotsDenialReason.robotsUnreachable);
    });

    test('fetches /robots.txt with the substrate UA', () async {
      final http = _RobotsFakeHttp()..robotsStatus = 404;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);
      await gate.evaluate(Uri.parse('https://example.com/deep/path?x=1'));

      expect(http.robotsCalls, hasLength(1));
      expect(http.robotsCalls.single.url.path, '/robots.txt');
      expect(http.robotsCalls.single.url.query, isEmpty);
      expect(http.robotsCalls.single.headers['User-Agent'], _ua);
    });

    test('caches per host — one robots fetch for repeated evaluations',
        () async {
      final http = _RobotsFakeHttp()
        ..robotsBody = 'User-agent: *\nDisallow: /x'
        ..robotsStatus = 200;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);

      await gate.evaluate(Uri.parse('https://example.com/a'));
      await gate.evaluate(Uri.parse('https://example.com/x/y'));
      await gate.evaluate(Uri.parse('https://example.com/b'));

      expect(http.robotsCalls, hasLength(1));
    });

    test('cache key separates hosts', () async {
      final http = _RobotsFakeHttp()..robotsStatus = 404;
      final gate = RobotsGate(httpClient: http, userAgent: _ua);

      await gate.evaluate(Uri.parse('https://a.example/x'));
      await gate.evaluate(Uri.parse('https://b.example/x'));

      expect(http.robotsCalls, hasLength(2));
    });
  });

  group('Q-B.30.3 / DefaultWebFetch integration', () {
    test('disallowed URL → WebFetchRobotsDenied, body never requested',
        () async {
      final http = _RobotsFakeHttp()
        ..robotsBody = 'User-agent: *\nDisallow: /secret'
        ..robotsStatus = 200
        ..bodyResponse = _okText('should never be read');
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/secret/page'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebFetchRobotsDenied>());
      expect((thrown! as WebFetchRobotsDenied).reason,
          RobotsDenialReason.robotsDisallow);
      // The fetch was refused before any body request.
      expect(http.bodyCalls, isEmpty);
    });

    test('unreachable robots (500) → WebFetchRobotsDenied(robotsUnreachable)',
        () async {
      final http = _RobotsFakeHttp()
        ..robotsStatus = 500
        ..bodyResponse = _okText('blocked');
      final fetch = DefaultWebFetch(httpClient: http);

      Object? thrown;
      try {
        await fetch.fetch(Uri.parse('https://example.com/x'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebFetchRobotsDenied>());
      expect((thrown! as WebFetchRobotsDenied).reason,
          RobotsDenialReason.robotsUnreachable);
      expect(http.bodyCalls, isEmpty);
    });

    test('allowed URL proceeds to the body fetch', () async {
      final http = _RobotsFakeHttp()
        ..robotsBody = 'User-agent: *\nDisallow: /secret'
        ..robotsStatus = 200
        ..bodyResponse = _okText('hello');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(Uri.parse('https://example.com/public'));
      expect(result.text, 'hello');
      expect(http.bodyCalls, hasLength(1));
    });

    test('obeyRobots: false skips the gate entirely', () async {
      final http = _RobotsFakeHttp()
        ..robotsBody = 'User-agent: *\nDisallow: /'
        ..robotsStatus = 200
        ..bodyResponse = _okText('owned site');
      final fetch = DefaultWebFetch(httpClient: http);

      final result = await fetch.fetch(
        Uri.parse('https://example.com/anything'),
        options: const WebFetchOptions(obeyRobots: false),
      );
      expect(result.text, 'owned site');
      // No robots fetch happened at all.
      expect(http.robotsCalls, isEmpty);
      expect(http.bodyCalls, hasLength(1));
    });

    test('surface reachable from the package barrel', () {
      expect(RobotsGate, isNotNull);
      expect(RobotsRules, isNotNull);
      expect(WebFetchRobotsDenied, isNotNull);
      expect(RobotsDenialReason.values, hasLength(2));
      expect(parseRobotsTxt, isNotNull);
    });
  });
}

const String _ua = 'TomBrain/0.1 (+https://tom-brain.local) WebFetch';

// ─── Test double ──────────────────────────────────────────────────────────

/// Fake `WebHttpClient` serving a canned `/robots.txt` over `get` and a
/// canned body over `getBytes`, recording both call streams separately.
class _RobotsFakeHttp implements WebHttpClient {
  String robotsBody = '';
  int robotsStatus = 200;
  Object? robotsError;
  WebHttpBytesResponse? bodyResponse;

  final List<_GetCall> robotsCalls = <_GetCall>[];
  final List<Uri> bodyCalls = <Uri>[];

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    robotsCalls.add(_GetCall(url: url, headers: headers));
    if (robotsError != null) throw robotsError!;
    return WebHttpResponse(
      statusCode: robotsStatus,
      body: robotsBody,
      headers: const <String, String>{'content-type': 'text/plain'},
      url: url,
    );
  }

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    bodyCalls.add(url);
    return bodyResponse ??
        (throw StateError('_RobotsFakeHttp.bodyResponse not set'));
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _GetCall {
  final Uri url;
  final Map<String, String> headers;
  _GetCall({required this.url, required this.headers});
}

class _Boom implements Exception {
  const _Boom();
}

WebHttpBytesResponse _okText(String body) {
  final bytes = utf8.encode(body);
  return WebHttpBytesResponse(
    statusCode: 200,
    bodyBytes: bytes,
    headers: <String, String>{
      'content-type': 'text/plain',
      'content-length': bytes.length.toString(),
    },
    url: Uri.parse('https://example.com/'),
    contentLength: bytes.length,
    truncated: false,
  );
}
