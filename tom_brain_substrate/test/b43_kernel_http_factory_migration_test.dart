// B.43 (Q-B.43.3 / Q-B.8.2) — kernel `TomHttpClientFactory` migration for
// the LLM wire clients and the MCP HTTP transport.
//
// The web layer joined the workspace HTTP convention at B.31 via
// `TomKernelWebHttpClient`, which sources its `package:http.Client` from
// `tom_core_kernel.TomHttpClientFactory` rather than constructing
// `http.Client()` directly. This file proves the same is now true for the
// two paths Q-B.43.3 flagged as still owning a parallel HTTP stack:
//
//   1. The shared LLM wire base (`DefaultWireHttpClientBase`, exercised
//      through `DefaultOllamaHttpClient` / `DefaultOpenAiHttpClient`).
//   2. The outbound MCP Streamable-HTTP transport (`HttpMcpTransport`).
//
// What this file asserts:
//
//   - With no explicit `client` injected, each path acquires its
//     underlying `package:http.Client` from the supplied
//     `TomHttpClientFactory` (one `getClient()` call, cached for the
//     client's lifetime — not one per request).
//   - The acquired client is the one actually used for the round-trip.
//   - An explicitly injected `client` takes precedence and the factory is
//     never consulted (so the dependency-discipline tests that inject a
//     `MockClient` keep working unchanged).
//   - `close()` releases a factory-owned client; an injected client is
//     left open for the caller to manage.
//
// No live network: a scripted in-isolate `_StubHttpClient` stands in for
// the wire, exactly as the B.31 adapter test does.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;

void main() {
  group('B.43 / LLM wire base — default client via kernel factory', () {
    test('DefaultOllamaHttpClient acquires its client from the factory once',
        () async {
      final stub = _StubHttpClient()..nextStatus = 503;
      final factory = _StubFactory(stub);
      final client = DefaultOllamaHttpClient(factory: factory);

      // Eager acquisition at construction: the factory is consulted once.
      expect(factory.getClientCalls, 1);

      // The acquired client is the one the round-trip actually uses.
      await expectLater(
        () => client.chat(
          baseUri: Uri.parse('http://localhost:11434'),
          model: 'gemma3:27b',
          messages: const [OllamaMessage(role: 'user', content: 'hi')],
          options: const OllamaGenerationOptions(),
        ),
        throwsA(isA<OllamaHttpException>()),
      );
      expect(stub.postCalls, hasLength(1));
      // Still one acquisition — the client is cached, not re-acquired.
      expect(factory.getClientCalls, 1);
      client.close();
    });

    test('DefaultOpenAiHttpClient acquires its client from the factory',
        () async {
      final stub = _StubHttpClient()..nextStatus = 503;
      final factory = _StubFactory(stub);
      final client = DefaultOpenAiHttpClient(factory: factory);

      expect(factory.getClientCalls, 1);
      await expectLater(
        () => client.listModels(baseUri: Uri.parse('https://api.openai.com')),
        throwsA(isA<OpenAiHttpException>()),
      );
      expect(stub.getCalls, hasLength(1));
      expect(factory.getClientCalls, 1);
      client.close();
    });

    test('injected client takes precedence; the factory is never consulted',
        () async {
      final injected = _StubHttpClient()..nextStatus = 503;
      final factory = _StubFactory(_StubHttpClient());
      final client =
          DefaultOllamaHttpClient(client: injected, factory: factory);

      await expectLater(
        () => client.chat(
          baseUri: Uri.parse('http://localhost:11434'),
          model: 'm',
          messages: const [OllamaMessage(role: 'user', content: 'hi')],
          options: const OllamaGenerationOptions(),
        ),
        throwsA(isA<OllamaHttpException>()),
      );
      expect(injected.postCalls, hasLength(1));
      expect(factory.getClientCalls, 0);
    });

    test('close() releases a factory-owned client', () {
      final stub = _StubHttpClient();
      final client = DefaultOllamaHttpClient(factory: _StubFactory(stub));
      client.close();
      expect(stub.closed, isTrue);
    });

    test('close() does NOT release an injected client', () {
      final stub = _StubHttpClient();
      final client = DefaultOllamaHttpClient(client: stub);
      client.close();
      expect(stub.closed, isFalse);
    });
  });

  group('B.43 / MCP HTTP transport — default client via kernel factory', () {
    test('HttpMcpTransport acquires its client from the factory once', () {
      final stub = _StubHttpClient();
      final factory = _StubFactory(stub);
      HttpMcpTransport(
        id: 'mcp',
        url: Uri.parse('http://localhost:9119/mcp'),
        factory: factory,
      );
      expect(factory.getClientCalls, 1);
    });

    test('the factory-acquired client is used for the outbound POST',
        () async {
      final stub = _StubHttpClient()
        ..nextStatus = 200
        ..nextBody = '';
      final factory = _StubFactory(stub);
      final transport = HttpMcpTransport(
        id: 'mcp',
        url: Uri.parse('http://localhost:9119/mcp'),
        factory: factory,
      );

      final channel = await transport.connect();
      // Drain the inbound stream the way a real consumer (dart_mcp) does;
      // without a listener the channel's `close()` done-event can never be
      // delivered and `transport.close()` below would hang.
      channel.stream.listen((_) {});
      channel.sink.add('{"jsonrpc":"2.0","id":1,"method":"ping"}');
      // The transport POSTs asynchronously (unawaited); poll (bounded) for
      // the scripted round-trip to land before asserting.
      for (var i = 0; i < 100 && stub.postCalls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(factory.getClientCalls, 1);
      expect(stub.postCalls, hasLength(1));
      await transport.close();
    });

    test('injected httpClient takes precedence; the factory is never consulted',
        () {
      final injected = _StubHttpClient();
      final factory = _StubFactory(_StubHttpClient());
      HttpMcpTransport(
        id: 'mcp',
        url: Uri.parse('http://localhost:9119/mcp'),
        httpClient: injected,
        factory: factory,
      );
      expect(factory.getClientCalls, 0);
    });

    test('close() releases a factory-owned client', () async {
      final stub = _StubHttpClient();
      final transport = HttpMcpTransport(
        id: 'mcp',
        url: Uri.parse('http://localhost:9119/mcp'),
        factory: _StubFactory(stub),
      );
      await transport.close();
      expect(stub.closed, isTrue);
    });

    test('close() does NOT release an injected client', () async {
      final stub = _StubHttpClient();
      final transport = HttpMcpTransport(
        id: 'mcp',
        url: Uri.parse('http://localhost:9119/mcp'),
        httpClient: stub,
      );
      await transport.close();
      expect(stub.closed, isFalse);
    });
  });
}

/// In-test `TomHttpClientFactory` that always returns the same
/// `_StubHttpClient` and counts `getClient()` invocations so tests can
/// prove the migrated paths consult the factory (and cache its result).
class _StubFactory extends kernel.TomHttpClientFactory {
  final _StubHttpClient _client;
  int getClientCalls = 0;
  _StubFactory(this._client);

  @override
  http.Client getClient() {
    getClientCalls += 1;
    return _client;
  }
}

/// Minimal scripted `package:http.Client`. Records the requests it sees by
/// method and answers with a configurable status + body.
class _StubHttpClient extends http.BaseClient {
  int nextStatus = 200;
  String nextBody = '';
  final List<http.BaseRequest> getCalls = <http.BaseRequest>[];
  final List<http.BaseRequest> postCalls = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') {
      getCalls.add(request);
    } else if (request.method == 'POST') {
      postCalls.add(request);
    }
    final bytes = utf8.encode(nextBody);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      nextStatus,
      contentLength: bytes.length,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}
