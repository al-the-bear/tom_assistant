// B.8 — HttpMcpTransport success round-trip (regression).
//
// The existing B.8 suite (`b08_mcp_client_test.dart`) only exercises the
// HttpMcpTransport *error* paths (401 → McpAuthFailed, 500 →
// McpTransportUnreachable). The success path — a 200 response whose JSON-RPC
// body must reach the consumer's `foreign.stream` — was never covered, and it
// regressed: inbound response lines were written to `controller.foreign.sink`,
// which a `StreamChannelController` emits back on `local.stream` — exactly the
// outbound listener that re-POSTs them, an infinite feedback loop (the server
// receives its own response echoed back as a new request).
//
// The fix routes inbound responses to `controller.local.sink` (which emits on
// the consumer's `foreign.stream`). This test pins the round trip directly
// against the transport, with a loopback `HttpServer` fixture.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:async/async.dart' show StreamQueue;
import 'package:http/http.dart' as httpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show HttpMcpTransport;

void main() {
  group('B.8 — HttpMcpTransport success round-trip', () {
    late io.HttpServer server;
    late httpc.Client client;
    final received = <String>[];

    setUp(() async {
      server = await io.HttpServer.bind('127.0.0.1', 0);
      client = httpc.Client();
      received.clear();
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    test('a 200 JSON-RPC response reaches the consumer exactly once', () async {
      unawaited(server.forEach((request) async {
        final body = await utf8.decodeStream(request);
        received.add(body);
        final decoded = jsonDecode(body) as Map<String, Object?>;
        request.response.statusCode = io.HttpStatus.ok;
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': <String, Object?>{'pong': true},
        }));
        await request.response.close();
      }));

      final transport = HttpMcpTransport(
        id: 'fixture',
        url: Uri.parse('http://${server.address.host}:${server.port}/'),
        httpClient: client,
      );
      final StreamChannel<String> channel = await transport.connect();
      final inbound = StreamQueue<String>(channel.stream);

      channel.sink.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'ping',
      }));

      final reply = await inbound.next.timeout(const Duration(seconds: 5));
      final replyJson = jsonDecode(reply) as Map<String, Object?>;
      expect(replyJson['id'], equals(42));
      expect((replyJson['result'] as Map)['pong'], isTrue);

      // The server must have received exactly ONE request — the response must
      // never be echoed back as a second POST (the feedback-loop regression).
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, hasLength(1));
      expect(
        jsonDecode(received.single),
        equals(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 42,
          'method': 'ping',
        }),
      );

      await channel.sink.close();
      await inbound.cancel();
      await transport.close();
    });
  });
}
