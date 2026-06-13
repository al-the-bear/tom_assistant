// r38 — HTTP MCP transport in the run channel factory (request b;
// `agent_sdk_provider_and_mcp_liveness.md` § 2).
//
// `productionMcpChannelFactory` used to *reject* an `http:` MCP server (only a
// `stdio:` child process was opened; HTTP raised an `mcp.unreachable`
// McpFailure). The VS Code Extension MCP server (request b) is reached over
// HTTP at `http://127.0.0.1:19920/`, so the factory must open an HTTP channel
// by delegating to the substrate's `HttpMcpTransport` (reuse, don't rebuild).
//
// These tests pin the new behaviour with a real loopback `HttpServer` fixture
// (the same shape the substrate's B.8 transport tests use) and an injected
// `http.Client` whose lifetime the test owns — production sources the client
// from `tom_core_kernel.TomHttpClientFactory`.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:async/async.dart' show StreamQueue;
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpFailure, McpServerConfig, McpTransport, mcpUnreachableCode;
import 'package:tom_brain_run/tom_brain_run.dart'
    show productionMcpChannelFactory;

void main() {
  group('r38 — productionMcpChannelFactory HTTP transport', () {
    late io.HttpServer server;
    late http.Client client;
    final receivedAuth = <String?>[];

    setUp(() async {
      server = await io.HttpServer.bind('127.0.0.1', 0);
      client = http.Client();
      receivedAuth.clear();
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    Uri serverUrl() =>
        Uri.parse('http://${server.address.host}:${server.port}/');

    test('opens an HTTP channel that round-trips a JSON-RPC line', () async {
      // Echo server: for every POST, reply 200 with a single JSON-RPC line
      // carrying the request id back, so we can assert the round trip.
      unawaited(server.forEach((request) async {
        receivedAuth.add(request.headers.value('authorization'));
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body) as Map<String, Object?>;
        request.response.statusCode = io.HttpStatus.ok;
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': <String, Object?>{'echoed': decoded['method']},
        }));
        await request.response.close();
      }));

      final factory = productionMcpChannelFactory(httpClient: client);
      final channel = await factory(McpServerConfig(
        id: 'vscode_ext',
        transport: McpTransport.http,
        url: serverUrl().toString(),
      ));

      final inbound = StreamQueue<String>(channel.stream);
      channel.sink.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'ping',
      }));

      final reply = await inbound.next.timeout(const Duration(seconds: 5));
      final replyJson = jsonDecode(reply) as Map<String, Object?>;
      expect(replyJson['id'], equals(7));
      expect((replyJson['result'] as Map)['echoed'], equals('ping'));

      await channel.sink.close();
      await inbound.cancel();
    });

    test('forwards an Authorization: Bearer header from config headers',
        () async {
      unawaited(server.forEach((request) async {
        receivedAuth.add(request.headers.value('authorization'));
        await utf8.decodeStream(request);
        request.response.statusCode = io.HttpStatus.ok;
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{},
        }));
        await request.response.close();
      }));

      final factory = productionMcpChannelFactory(httpClient: client);
      final channel = await factory(McpServerConfig(
        id: 'vscode_ext',
        transport: McpTransport.http,
        url: serverUrl().toString(),
        headers: const <String, String>{'Authorization': 'Bearer s3cr3t'},
      ));

      final inbound = StreamQueue<String>(channel.stream);
      channel.sink.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      }));
      await inbound.next.timeout(const Duration(seconds: 5));

      expect(receivedAuth.single, equals('Bearer s3cr3t'));

      await channel.sink.close();
      await inbound.cancel();
    });

    test('an http server with no url raises an mcp.unreachable McpFailure',
        () async {
      final factory = productionMcpChannelFactory(httpClient: client);

      await expectLater(
        factory(const McpServerConfig(
          id: 'no-url',
          transport: McpTransport.http,
        )),
        throwsA(isA<McpFailure>()
            .having((e) => e.code, 'code', mcpUnreachableCode)
            .having((e) => e.serverId, 'serverId', 'no-url')),
      );
    });
  });
}
