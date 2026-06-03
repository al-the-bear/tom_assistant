// todo #3 — Streamable HTTP / HTTPS server transport conformance tests.
//
// Locks the wire contract of `McpHttpServer` (the network transport the
// cross-machine Big-Beast/bomber topology needs — `memory_specification.md`
// §§ 3.2, 10):
//
//   1. A POST `initialize` with no session id opens a session: the reply
//      is `200 application/json`, carries a generated `Mcp-Session-Id`
//      header, and the body is the JSON-RPC `initialize` result with the
//      tom_brain_memory identity.
//   2. A follow-up `notifications/initialized` (no `id`) is acknowledged
//      `202` with an empty body.
//   3. A follow-up request on the established session (here `tools/list`)
//      is correlated and answered `200` — proving the session persists
//      across POSTs and the server reached `ready`.
//   4. A non-`initialize` POST with no session id is rejected `400`.
//   5. A POST with an unknown session id is rejected `404`.
//   6. `GET` is rejected `405` (no SSE stream in the v1 subset).
//   7. `DELETE` terminates the session; a subsequent request on the same
//      id is then `404`.
//   8. The HTTPS bind path (`securityContext` supplied) round-trips an
//      `initialize` handshake over TLS and reports `isSecure == true`.
//
// The server side is the A.75 skeleton (`TomBrainMemoryMcpServer` with no
// memory binding, no authenticator) — these tests exercise the transport,
// not the tool surface. Requests are driven with `dart:io`'s `HttpClient`
// so the test pulls in no new dependency (the package forbids an HTTP
// client dependency; the SDK client is fine).

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('todo #3 McpHttpServer (HTTP)', () {
    late McpHttpServer server;
    late io.HttpClient client;

    setUp(() async {
      server = await McpHttpServer.bind(
        onSession: (channel) => TomBrainMemoryMcpServer(channel),
      );
      client = io.HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    test('initialize opens a session and returns the Mcp-Session-Id header',
        () async {
      final res = await _post(client, server.url, _initRequest(1));

      expect(res.status, equals(200));
      expect(res.contentType, contains('application/json'));
      final sessionId = res.headers['mcp-session-id'];
      expect(sessionId, isNotNull, reason: 'initialize must mint a session id');
      expect(sessionId, isNotEmpty);

      final body = jsonDecode(res.body) as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>;
      final serverInfo = result['serverInfo'] as Map<String, Object?>;
      expect(serverInfo['name'], equals('tom_brain_memory'));
      expect(server.sessionCount, equals(1));
    });

    test('full handshake then tools/list round-trips on the same session',
        () async {
      final init = await _post(client, server.url, _initRequest(1));
      final sessionId = init.headers['mcp-session-id']!;

      final notify = await _post(
        client,
        server.url,
        _notification('notifications/initialized'),
        sessionId: sessionId,
      );
      expect(notify.status, equals(202),
          reason: 'a notification has no id and yields no body');
      expect(notify.body, isEmpty);

      final tools = await _post(
        client,
        server.url,
        _request(2, 'tools/list'),
        sessionId: sessionId,
      );
      expect(tools.status, equals(200));
      final body = jsonDecode(tools.body) as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>;
      expect(result['tools'], isEmpty,
          reason: 'the skeleton registers no tools');
    });

    test('non-initialize POST without a session id is rejected 400', () async {
      final res = await _post(client, server.url, _request(1, 'tools/list'));
      expect(res.status, equals(400));
    });

    test('POST with an unknown session id is rejected 404', () async {
      final res = await _post(
        client,
        server.url,
        _request(1, 'tools/list'),
        sessionId: 'deadbeefdeadbeefdeadbeefdeadbeef',
      );
      expect(res.status, equals(404));
    });

    test('malformed JSON body is rejected 400', () async {
      final res = await _post(client, server.url, '{not json');
      expect(res.status, equals(400));
    });

    test('GET is rejected 405 (no SSE in v1)', () async {
      final req = await client.getUrl(server.url);
      final resp = await req.close();
      await resp.drain<void>();
      expect(resp.statusCode, equals(405));
    });

    test('DELETE terminates the session', () async {
      final init = await _post(client, server.url, _initRequest(1));
      final sessionId = init.headers['mcp-session-id']!;
      expect(server.sessionCount, equals(1));

      final del = await _delete(client, server.url, sessionId);
      expect(del.status, anyOf(equals(204), equals(200)));
      expect(server.sessionCount, equals(0));

      // The id is no longer addressable.
      final after = await _post(
        client,
        server.url,
        _request(2, 'tools/list'),
        sessionId: sessionId,
      );
      expect(after.status, equals(404));
    });
  });

  group('todo #3 McpHttpServer (HTTPS)', () {
    test('initialize round-trips over TLS and reports isSecure', () async {
      final context = io.SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_testCertPem))
        ..usePrivateKeyBytes(utf8.encode(_testKeyPem));

      final server = await McpHttpServer.bind(
        onSession: (channel) => TomBrainMemoryMcpServer(channel),
        securityContext: context,
      );
      addTearDown(server.close);

      expect(server.isSecure, isTrue);
      expect(server.url.scheme, equals('https'));

      final client = io.HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      addTearDown(() => client.close(force: true));

      final res = await _post(client, server.url, _initRequest(1));
      expect(res.status, equals(200));
      final body = jsonDecode(res.body) as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>;
      final serverInfo = result['serverInfo'] as Map<String, Object?>;
      expect(serverInfo['name'], equals('tom_brain_memory'));
    });
  });

  group('todo #3 transport barrel', () {
    test('McpHttpSessionHandler is reachable through the package barrel', () {
      const McpHttpSessionHandler handler = _noopHandler;
      expect(handler, isNotNull);
    });
  });
}

void _noopHandler(StreamChannel<String> _) {}

String _initRequest(int id) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'http-transport-test', 'version': '0.0.1'},
      },
    });

String _request(int id, String method) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': <String, Object?>{},
    });

String _notification(String method) => jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
    });

typedef _HttpResult = ({
  int status,
  Map<String, String> headers,
  String body,
  String contentType,
});

Future<_HttpResult> _post(
  io.HttpClient client,
  Uri url,
  String body, {
  String? sessionId,
}) async {
  final req = await client.postUrl(url);
  req.headers.contentType = io.ContentType.json;
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  req.write(body);
  final resp = await req.close();
  final text = await utf8.decoder.bind(resp).join();
  return _collect(resp, text);
}

Future<_HttpResult> _delete(
  io.HttpClient client,
  Uri url,
  String sessionId,
) async {
  final req = await client.deleteUrl(url);
  req.headers.set('Mcp-Session-Id', sessionId);
  final resp = await req.close();
  final text = await utf8.decoder.bind(resp).join();
  return _collect(resp, text);
}

_HttpResult _collect(io.HttpClientResponse resp, String body) {
  final headers = <String, String>{};
  resp.headers.forEach((name, values) => headers[name] = values.join(','));
  return (
    status: resp.statusCode,
    headers: headers,
    body: body,
    contentType: resp.headers.contentType?.toString() ?? '',
  );
}

// Self-signed localhost certificate (CN=localhost, SAN DNS:localhost +
// IP:127.0.0.1), generated for tests only. 100-year validity so the
// fixture does not rot. Never used outside this test.
const String _testCertPem = '''
-----BEGIN CERTIFICATE-----
MIIDJzCCAg+gAwIBAgIUNiTEjSX9437MbOJ3COfLqBwpLwEwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDYwMzE2NDQzM1oYDzIxMjYw
NTEwMTY0NDMzWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDX6oabfS9p+haSUJB4ztxLh6r3HhDmkCyxEZ7xE53K
CBCrHFKr6x9O3BttY7TQMDKmx5kg9cvGsu1r1aJ9eXUQUx6begwL9figVD11miV4
9zNu+Ummd9B0XpfOgqHwKvES6bND8Q/8S6P9WKBpyG8Se0U0olaue7X5ZkMU/rGk
c72scrri2ZEdB/HvdkOyO41H6RbO/cdWJNf6IH/j6E+XAsm1C9HnQ+uC2pOi3Qwq
dyE1mdSn7r6fN/4E4rdvcRW630u260EvRE2+GYzg6CjJiO5wm+kWNcMeoYD35tIP
U6PfPPTbijfsTkCcF5hgD7mK5ePqBXI+o+rUdK9DohQtAgMBAAGjbzBtMB0GA1Ud
DgQWBBSLK3wq6OhtRENDpwGjxkXqbxBCUjAfBgNVHSMEGDAWgBSLK3wq6OhtREND
pwGjxkXqbxBCUjAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAY64nIzcjl29hL3O6n8hipL0VkJgN
4Rbjo3EkdW6nwoJkOnaebiT/cWaAmJthNQ5UrbplqLGhYkAFQKqvfhdqDiGXGGXa
7ysVV/3pYehNenz0EnL12yL0geNGrrLG4QClDW+7DbyQmxA/igz8dLDGivMBnhYZ
RjKMdOg5QYs595ftMsqOR23HYcXRuGAWaOGcFnfF2JVOfUWkIpBHHKJkj9wwOXSo
UewEpIVvuXV8+OGYGlc3itEW7QG9oZipZquJVQcKhdddLcnKV7HdVjOPwMlQcvBw
q5Pn2hk3tv8FaMPmRzdsq69UtEjfXLDc2DIxSmnKUq0sPa/Kc5+CvVWXMw==
-----END CERTIFICATE-----
''';

const String _testKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDX6oabfS9p+haS
UJB4ztxLh6r3HhDmkCyxEZ7xE53KCBCrHFKr6x9O3BttY7TQMDKmx5kg9cvGsu1r
1aJ9eXUQUx6begwL9figVD11miV49zNu+Ummd9B0XpfOgqHwKvES6bND8Q/8S6P9
WKBpyG8Se0U0olaue7X5ZkMU/rGkc72scrri2ZEdB/HvdkOyO41H6RbO/cdWJNf6
IH/j6E+XAsm1C9HnQ+uC2pOi3QwqdyE1mdSn7r6fN/4E4rdvcRW630u260EvRE2+
GYzg6CjJiO5wm+kWNcMeoYD35tIPU6PfPPTbijfsTkCcF5hgD7mK5ePqBXI+o+rU
dK9DohQtAgMBAAECggEAA0m4/wkq/awnR9cePBi6VhQc0GKO01QCujeQeg9Yackx
p8looOGVunezmzjXegwh2VRUyqGzlrUG1IuOS+bbl4IMh0WWhWAbhyWBQhc01uC8
0cXOD1Dnxb3jBewLV0LwJN+WMUSsf6UPPD5rQvEgb+Gcri6Cr2mG3eNmxh0Sy3RI
mAsD/9xKS4VqAw1qgnZOScSrWCBnkTMNfEwR2E8nsQ63EJdWvfc2wetNf3Aliu6v
7Rm8uUBRWS58ogoCqInTjLzoebjfvVG5vsojHeoGk5VdoAOXaTAruJjdqN/5REW/
tb96ZRrit3N1NwY27N5jpCBmueyJV2KIleMjTt9twQKBgQDsH9o5pwcaEaAaf/Ht
uVbCNlP3+8eh02K1ZVzTxhqXfbDmZ216fcaedL1QYjdapt5VBHyWwJme1FkE68E6
0+g8St0Q8J2w7dHIo0GuaQfTrVXh6XIsjMWkpn7hKLbVv4VO/60fjfSOO1tpHtva
soh/HP50R2SWfxQFJEJwEyE2qQKBgQDqFzaBhZ+isz1hUeh8/lPtbCR7eoW+fn7A
womp95VJOxNEcW1DEcX3FtH/V9MZ5QNJbLYrLmBBx9XJQHgCXdjb26Bxgblv4qy7
Wn0WX/vo9kAT3pQUk85IVyapn5Hv75wPOxa47+Kpmtf+WwHILGvoNnyCBVGHHoEG
7VE8G8sX5QKBgQCtob6XJnvSb6OL2QnOBbwGlGyqrjrehNLREPhxwftL6uFqjCO1
L0gevTl5IsARqSNU4Te8o2RTp1LOi45L9AeSTnrBOi67LCZXo7Voy1M2FQBSX5fV
qq6rpMMoTwgjpfIhZWGpEnoDHSLa6hZBe4dj8a4rU1RkVo4iOcehInAKAQKBgQDk
Xlb3TqOotxG3Yo/beMXpxmlk6OeXKpJ/fImOfhFuiqpGSB2eo7UsU1/0qfowteFZ
/StOvwR6x/hBSJqLPIC2I/HHKhX9F/cJI8MKVANOhwWGHMr7tCI3IoZ+TkSx/WCS
30NQkf3fFkeHRcNcRDHVLWqT8ZpSpiib2GM6r6aXHQKBgDyUAyZb1+IwN4e///Uq
8lDo5xXvSdvVaQjVnVRtyiR61qX0feXqWIZWsXZkYbLGFn8vOvYWkrlQnmmkZnSl
W3EQxfZlo4VV8j88FTnudAiGqdtujXYnepovCYo3oWaXu+lwltEA/elfnMQDCedp
PmqssqzUh4FiUBzBcNnu1F39
-----END PRIVATE KEY-----
''';
