// B.31 — `TomKernelWebHttpClient` adapter conformance.
//
// Scope of this test file (per plan step B.31):
//
//   - Prove the adapter delegates GET / POST / GETBYTES to the
//     `package:http.Client` returned by the injected
//     `TomHttpClientFactory`, with the same wire-shape conversions
//     `DefaultWebHttpClient` does (lower-case headers, transport
//     exception wrapping, content-length parsing, byte budget
//     truncation).
//   - Prove the adapter caches the `package:http.Client` between
//     calls (the factory's `getClient()` is invoked once, not per
//     call).
//   - Prove `close()` releases the factory-owned client; subsequent
//     calls throw `StateError`. The `withClient` constructor variant
//     leaves the caller-owned client open.
//   - Prove byte-budget enforcement: a 1 KiB body with a 128 B budget
//     returns 128 bytes + `truncated: true`.
//   - Prove the surface is reachable through the top-level barrel.
//
// Scope this file is NOT for:
//
//   - No live network. The test factory returns a `mocktail`-style
//     `_StubHttpClient` that scripts responses.
//   - No retry / circuit-breaker behaviour — that lives in
//     `b31_retrying_web_http_client_test.dart`.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;

void main() {
  group('B.31 / TomKernelWebHttpClient — delegation through factory', () {
    test('GET routes to factory client and returns lower-case headers',
        () async {
      final stub = _StubHttpClient()
        ..nextResponse = http.Response(
          'hello',
          200,
          headers: <String, String>{'Content-Type': 'text/plain'},
        );
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      final response = await adapter.get(Uri.parse('https://example.com/a'));
      expect(response.statusCode, 200);
      expect(response.body, 'hello');
      expect(response.headers['content-type'], 'text/plain');
      expect(stub.getCalls, hasLength(1));
      adapter.close();
    });

    test('POSTform encodes form, forces content-type, and forwards body',
        () async {
      final stub = _StubHttpClient()
        ..nextResponse = http.Response('{"ok":true}', 200);
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      await adapter.postForm(
        Uri.parse('https://example.com/q'),
        form: const <String, String>{'q': 'hello world', 'lang': 'en'},
      );
      expect(stub.postCalls, hasLength(1));
      final call = stub.postCalls.single;
      expect(call.headers['Content-Type'],
          'application/x-www-form-urlencoded');
      // Uri.encodeQueryComponent encodes ' ' as '+', not '%20' — the
      // query-component form is correct for application/x-www-form-urlencoded.
      expect(call.body, 'q=hello+world&lang=en');
      adapter.close();
    });

    test('transport exception wraps as WebHttpTransportException', () async {
      final stub = _StubHttpClient()
        ..nextException = const SocketIoException('connection refused');
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      Object? thrown;
      try {
        await adapter.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebHttpTransportException>());
      adapter.close();
    });
  });

  group('B.31 / TomKernelWebHttpClient — getBytes', () {
    test('reads up to byteBudget and reports truncated: true', () async {
      final body = List<int>.generate(1024, (i) => i & 0xff);
      final stub = _StubHttpClient()
        ..nextStreamedResponse = _streamedFromBytes(
          body,
          headers: <String, String>{'content-length': '1024'},
        );
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      final response = await adapter.getBytes(
        Uri.parse('https://example.com/big'),
        byteBudget: 128,
      );
      expect(response.statusCode, 200);
      expect(response.bodyBytes, hasLength(128));
      expect(response.truncated, isTrue);
      expect(response.contentLength, 1024);
      adapter.close();
    });

    test('byteBudget = null reads the whole body', () async {
      final body = const <int>[1, 2, 3, 4, 5];
      final stub = _StubHttpClient()
        ..nextStreamedResponse = _streamedFromBytes(body);
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      final response = await adapter.getBytes(
        Uri.parse('https://example.com/small'),
      );
      expect(response.bodyBytes, body);
      expect(response.truncated, isFalse);
      adapter.close();
    });

    test('rejects negative byteBudget', () async {
      final adapter = TomKernelWebHttpClient(factory: _StubFactory(_StubHttpClient()));
      Object? thrown;
      try {
        await adapter.getBytes(Uri.parse('https://example.com/a'),
            byteBudget: -1);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<ArgumentError>());
      adapter.close();
    });
  });

  group('B.31 / TomKernelWebHttpClient — caching + lifecycle', () {
    test('factory.getClient() invoked once even across multiple calls',
        () async {
      final stub = _StubHttpClient()
        ..nextResponse = http.Response('a', 200);
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);

      await adapter.get(Uri.parse('https://example.com/a'));
      stub.nextResponse = http.Response('b', 200);
      await adapter.get(Uri.parse('https://example.com/b'));
      stub.nextResponse = http.Response('c', 200);
      await adapter.get(Uri.parse('https://example.com/c'));

      expect(factory.getClientCalls, 1);
      adapter.close();
    });

    test('close() releases factory-owned client', () {
      final stub = _StubHttpClient();
      final factory = _StubFactory(stub);
      final adapter = TomKernelWebHttpClient(factory: factory);
      // Force lazy acquisition.
      stub.nextResponse = http.Response('x', 200);
      adapter.get(Uri.parse('https://example.com/a'));

      adapter.close();
      expect(stub.closed, isTrue);
    });

    test('withClient does NOT close the caller-owned client', () {
      final stub = _StubHttpClient();
      final adapter = TomKernelWebHttpClient.withClient(stub);
      adapter.close();
      expect(stub.closed, isFalse);
    });

    test('subsequent calls after close throw StateError', () async {
      final stub = _StubHttpClient();
      final adapter = TomKernelWebHttpClient(factory: _StubFactory(stub));
      adapter.close();
      Object? thrown;
      try {
        await adapter.get(Uri.parse('https://example.com/a'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<StateError>());
    });
  });

  group('B.31 / TomKernelWebHttpClient — barrel reachability', () {
    test('symbols reachable through top-level package barrel', () {
      expect(TomKernelWebHttpClient, isNotNull);
    });
  });
}

/// In-test `TomHttpClientFactory` that always returns the same
/// `_StubHttpClient`. Counts how many times `getClient()` was called
/// so tests can prove caching.
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

/// Minimal stub of `package:http.Client` that returns a scripted
/// response (or throws a scripted exception) per call.
class _StubHttpClient extends http.BaseClient {
  http.Response? nextResponse;
  http.StreamedResponse? nextStreamedResponse;
  Object? nextException;
  final List<http.Request> getCalls = <http.Request>[];
  final List<http.Request> postCalls = <http.Request>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final ex = nextException;
    if (ex != null) {
      nextException = null;
      throw ex;
    }
    if (request is http.Request) {
      if (request.method == 'GET') {
        getCalls.add(request);
      } else if (request.method == 'POST') {
        postCalls.add(request);
      }
    }
    final streamed = nextStreamedResponse;
    if (streamed != null) {
      nextStreamedResponse = null;
      return streamed;
    }
    final response = nextResponse!;
    nextResponse = null;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(response.body)]),
      response.statusCode,
      headers: response.headers,
      contentLength: response.body.length,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse _streamedFromBytes(
  List<int> body, {
  Map<String, String> headers = const <String, String>{},
  int statusCode = 200,
}) {
  // Emit in 64-byte chunks to exercise the streaming path.
  Stream<List<int>> chunks() async* {
    const chunkSize = 64;
    for (var i = 0; i < body.length; i += chunkSize) {
      final end = (i + chunkSize) > body.length ? body.length : (i + chunkSize);
      yield Uint8List.fromList(body.sublist(i, end));
    }
  }

  return http.StreamedResponse(
    chunks(),
    statusCode,
    headers: headers,
    contentLength: body.length,
  );
}

/// Sentinel exception type used to simulate a transport-level failure
/// inside the stub. The adapter wraps anything thrown by
/// `package:http` as a `WebHttpTransportException` — we use a custom
/// type so the assertion does not need to import `dart:io`.
class SocketIoException implements Exception {
  final String message;
  const SocketIoException(this.message);
  @override
  String toString() => 'SocketIoException: $message';
}
