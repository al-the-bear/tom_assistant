// B.8 (B.35) — outbound MCP client conformance tests.
//
// Plan B.35 names the three test concerns this file owns:
//
//   1. **Tool discovery** — `McpSession.listTools()` returns the tool
//      catalogue advertised by a real `dart_mcp` server.
//   2. **Tool call roundtrip** — `McpSession.callTool(name, args)`
//      sends arguments to the server and returns the server's
//      response content; the round-trip preserves both shapes.
//   3. **Auth failure surfaces as typed error** — the HTTP transport
//      with a bearer credential surfaces a `McpAuthFailed` when the
//      endpoint returns 401 / 403, *not* a generic dart_mcp
//      `StateError`.
//
// Test approach:
//
//   - The first two tests use an in-process `dart_mcp` `MCPServer`
//     wired to the client via a `StreamChannelController` pair (so
//     no stdio framing, no network, but a real protocol round-trip
//     through `dart_mcp` on both ends).
//   - The auth-failure test spins up a tiny `HttpServer` in the
//     test isolate that returns 401 on every POST. The client is
//     pointed at that endpoint with a `McpBearerCredential`; the
//     test asserts the surfaced error is `McpAuthFailed` with the
//     status code preserved and that no generic dart_mcp StateError
//     leaks.
//
// What this file does NOT cover:
//
//   - SSE / Streamable HTTP server-initiated-message path — see
//     scope cut in `http_transport.dart` header.
//   - Reconnect-after-disconnect behaviour — Spec § 3.2 mentions
//     exponential backoff; the prototype client at B.8 does not
//     implement it (`McpClient` is single-attempt). Reconnect tests
//     land alongside reconnect implementation in a later step.
//   - Bearer credential redaction in logs — observability tests
//     land at B.39 with the rest of the substrate event surface.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:http/http.dart' as httpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.8 — McpClient over in-process channel', () {
    late McpClient client;
    late _FixtureMcpServer server;
    late McpSession session;

    setUp(() async {
      final controllers = _linkedChannelPair();
      server = _FixtureMcpServer(controllers.serverSide);
      client = McpClient(
        identity: const McpClientIdentity(
          name: 'tom_brain_substrate_test',
          version: '0.0.1',
        ),
      );
      final transport = ChannelMcpTransport(
        controllers.clientSide,
        id: 'fixture-in-process',
      );
      session = await client.connect(transport);
    });

    tearDown(() async {
      await session.close();
      await client.close();
      await server.shutdown();
    });

    test('tool discovery surfaces the server-advertised catalogue', () async {
      final tools = await session.listTools();

      // The fixture registers two tools; both should round-trip.
      expect(tools.map((t) => t.name), containsAll(<String>['echo', 'add']));

      final echo = tools.firstWhere((t) => t.name == 'echo');
      expect(echo.description, 'Returns the message verbatim.');
      // Input schema is preserved as a Map — the substrate intentionally
      // does not bind to dart_mcp's typed schema wrapper.
      expect(echo.inputSchema['type'], 'object');
      expect(
        (echo.inputSchema['properties'] as Map?)?.containsKey('message'),
        isTrue,
      );
    });

    test('tool call roundtrips arguments and content', () async {
      final result = await session.callTool('echo', {
        'message': 'hello tom brain',
      });

      expect(result.isError, isFalse);
      expect(result.content, hasLength(1));
      final first = result.content.single;
      expect(first['type'], 'text');
      expect(first['text'], 'hello tom brain');
    });

    test('tool call propagates numeric arguments', () async {
      final result = await session.callTool('add', {'a': 2, 'b': 3});

      expect(result.isError, isFalse);
      expect(result.content.single['text'], '5');
    });
  });

  group('B.8 — HttpMcpTransport bearer-token auth', () {
    late io.HttpServer http;
    // Production sources the transport's `package:http.Client` from
    // `tom_core_kernel.TomHttpClientFactory` (Q-B.43.3). The VM test
    // platform has no real `TomPlatformUtils`, so these fixture-server
    // tests inject a real client whose lifetime they own.
    late httpc.Client httpClient;

    setUp(() async {
      http = await io.HttpServer.bind('127.0.0.1', 0);
      httpClient = httpc.Client();
    });

    tearDown(() async {
      httpClient.close();
      await http.close(force: true);
    });

    test(
        '401 from endpoint surfaces as McpAuthFailed with status code',
        () async {
      // Server always replies 401 — does not even read the body. This
      // exercises the auth-rejection path before any MCP handshake
      // bytes are exchanged.
      unawaited(http.forEach((request) async {
        request.response.statusCode = io.HttpStatus.unauthorized;
        request.response.headers.contentType = io.ContentType.text;
        request.response.write('go away');
        await request.response.close();
      }));

      final client = McpClient(
        identity: const McpClientIdentity(
          name: 'tom_brain_substrate_test',
          version: '0.0.1',
        ),
      );
      addTearDown(client.close);

      final transport = HttpMcpTransport(
        id: 'fixture-http',
        url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
        auth: const McpBearerCredential('not-a-real-token'),
        requestTimeout: const Duration(seconds: 2),
        httpClient: httpClient,
      );

      McpAuthFailed? captured;
      try {
        await client.connect(transport);
        fail('Expected McpAuthFailed; connect() returned successfully.');
      } on McpAuthFailed catch (error) {
        captured = error;
      }

      expect(captured, isNotNull);
      expect(captured.endpointId, 'fixture-http');
      expect(captured.statusCode, 401);
    });

    test(
        '500 from endpoint surfaces as McpTransportUnreachable, not Auth',
        () async {
      unawaited(http.forEach((request) async {
        request.response.statusCode = io.HttpStatus.internalServerError;
        await request.response.close();
      }));

      final client = McpClient(
        identity: const McpClientIdentity(
          name: 'tom_brain_substrate_test',
          version: '0.0.1',
        ),
      );
      addTearDown(client.close);

      final transport = HttpMcpTransport(
        id: 'fixture-http-500',
        url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
        auth: const McpBearerCredential('whatever'),
        requestTimeout: const Duration(seconds: 2),
        httpClient: httpClient,
      );

      McpClientException? captured;
      try {
        await client.connect(transport);
        fail('Expected an McpClientException; connect() returned.');
      } on McpClientException catch (error) {
        captured = error;
      }

      // Critically: 500 must NOT be misclassified as McpAuthFailed.
      expect(captured, isA<McpTransportUnreachable>());
      expect(captured, isNot(isA<McpAuthFailed>()));
      expect((captured as McpTransportUnreachable).statusCode, 500);
    });

    test(
        'sets Authorization: Bearer <token> header on the POST',
        () async {
      String? observedAuthHeader;
      unawaited(http.forEach((request) async {
        observedAuthHeader = request.headers.value('authorization');
        // Reject with 401 so the test stops cleanly; we only care
        // about the header here.
        request.response.statusCode = io.HttpStatus.unauthorized;
        await request.response.close();
      }));

      final client = McpClient(
        identity: const McpClientIdentity(
          name: 'tom_brain_substrate_test',
          version: '0.0.1',
        ),
      );
      addTearDown(client.close);

      final transport = HttpMcpTransport(
        id: 'fixture-http-bearer',
        url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
        auth: const McpBearerCredential('secret-token-12345'),
        requestTimeout: const Duration(seconds: 2),
        httpClient: httpClient,
      );

      try {
        await client.connect(transport);
      } on McpAuthFailed {
        // Expected; we set the server to 401.
      }

      expect(observedAuthHeader, 'Bearer secret-token-12345');
    });

    test(
        'no Authorization header when transport has no bearer credential',
        () async {
      String? observedAuthHeader = 'sentinel';
      unawaited(http.forEach((request) async {
        observedAuthHeader = request.headers.value('authorization');
        request.response.statusCode = io.HttpStatus.unauthorized;
        await request.response.close();
      }));

      final client = McpClient(
        identity: const McpClientIdentity(
          name: 'tom_brain_substrate_test',
          version: '0.0.1',
        ),
      );
      addTearDown(client.close);

      final transport = HttpMcpTransport(
        id: 'fixture-http-no-auth',
        url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
        // No `auth:` argument — anonymous transport.
        requestTimeout: const Duration(seconds: 2),
        httpClient: httpClient,
      );

      try {
        await client.connect(transport);
      } on McpClientException {
        // Expected — server returns 401 either way.
      }

      // The header must be entirely absent (not "Bearer null", not
      // "Bearer ", not present).
      expect(observedAuthHeader, isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

/// A linked pair of `StreamChannel<String>` instances; whatever is
/// written to one side appears on the other. Used to wire a
/// dart_mcp client to a dart_mcp server in the same isolate.
({StreamChannel<String> clientSide, StreamChannel<String> serverSide})
    _linkedChannelPair() {
  final clientController =
      StreamChannelController<String>(sync: false, allowForeignErrors: true);
  final serverController =
      StreamChannelController<String>(sync: false, allowForeignErrors: true);

  // Wire client outbound → server inbound.
  //
  // StreamChannelController semantics: when a consumer holds the
  // `foreign` end, what it reads from `foreign.stream` is fed by
  // writes to `local.sink` (and vice versa). The client holds
  // `clientController.foreign`; its outbound writes appear on
  // `clientController.local.stream`. To deliver those bytes to the
  // server (which reads from `serverController.foreign.stream`) we
  // must write into `serverController.local.sink` — *not* the foreign
  // sink. Symmetric for the reverse direction.
  clientController.local.stream.listen(
    serverController.local.sink.add,
    onDone: serverController.local.sink.close,
  );
  // Wire server outbound → client inbound.
  serverController.local.stream.listen(
    clientController.local.sink.add,
    onDone: clientController.local.sink.close,
  );

  return (
    clientSide: clientController.foreign,
    serverSide: serverController.foreign,
  );
}

/// Minimal `dart_mcp` server fixture that registers `echo` and `add`
/// tools. Used by the discovery + roundtrip tests above.
base class _FixtureMcpServer extends mcp_server.MCPServer
    with mcp_server.ToolsSupport {
  _FixtureMcpServer(super.channel)
      : super.fromStreamChannel(
          implementation: mcp_server.Implementation(
            name: 'fixture_mcp_server',
            version: '0.0.1',
          ),
        );

  @override
  FutureOr<mcp_server.InitializeResult> initialize(
    mcp_server.InitializeRequest request,
  ) async {
    registerTool(
      mcp_server.Tool(
        name: 'echo',
        description: 'Returns the message verbatim.',
        inputSchema: mcp_server.ObjectSchema(
          properties: {'message': mcp_server.Schema.string()},
          required: ['message'],
        ),
      ),
      (req) => mcp_server.CallToolResult(
        content: [
          mcp_server.Content.text(
            text: (req.arguments?['message'] ?? '') as String,
          ),
        ],
      ),
      validateArguments: false,
    );

    registerTool(
      mcp_server.Tool(
        name: 'add',
        description: 'Returns the sum of a and b.',
        inputSchema: mcp_server.ObjectSchema(
          properties: {
            'a': mcp_server.Schema.num(),
            'b': mcp_server.Schema.num(),
          },
          required: ['a', 'b'],
        ),
      ),
      (req) {
        final a = (req.arguments?['a'] as num).toDouble();
        final b = (req.arguments?['b'] as num).toDouble();
        final sum = a + b;
        // Render as integer when both inputs are integers.
        final rendered =
            sum == sum.truncateToDouble() ? sum.toInt().toString() : sum.toString();
        return mcp_server.CallToolResult(
          content: [mcp_server.Content.text(text: rendered)],
        );
      },
      validateArguments: false,
    );

    return super.initialize(request);
  }
}

// Keep `dart:convert` import (LineSplitter helpers in the production
// transport) reachable for future test additions without an unused
// import warning.
// ignore: unused_element
LineSplitter? _ensureLineSplitterStaysImported() => null;
