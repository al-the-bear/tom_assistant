// B.35 — Outbound MCP client conformance against the three plan-named
// concerns.
//
// `prototype_implementation_plan.md` step B.35 (verbatim):
//
//   > Tests: tool discovery; tool call roundtrip; auth failure surfaces
//   > as typed error.
//
// Why this file exists separately from `b08_mcp_client_test.dart`.
//
//   The B.8 file was authored together with the B.8 pre-delivery of
//   the MCP client and carries the per-transport wire-shape coverage
//   (fixture-server tool discovery, fixture-server roundtrip with
//   numeric arguments, HTTP transport bearer-header presence /
//   absence, 401 vs. 500 discrimination). That coverage is necessary
//   and stays in place.
//
//   What B.35 adds is a **plan-named conformance contract**: three
//   assertions that map 1:1 onto the three plan-text concerns and
//   that read as a self-contained acceptance surface for the plan
//   step. A future change to the `McpSession` surface or to the
//   transport / auth boundary that quietly drops one of the three
//   concerns will fail a test whose name *is* the plan-text concern
//   — not a test whose name describes a wire-shape detail.
//
//   This mirrors the per-step pattern that landed at B.28
//   (`EmbeddingService` cross-impl conformance) and B.32 (`WebSearch`
//   / `WebFetch` cross-impl conformance): per-impl details stay where
//   they were, a plan-named conformance file pins the contract.
//
// Scope cut (per Q-B.33.3, recommended-default-taken).
//
//   B.35 does NOT lift the per-transport tests into a fully abstract
//   `_runMcpClientConformance(builder, transportBuilder)` driver yet.
//   That extraction waits for B.44 (the Phase-B reuse-extraction
//   pass) or for the appearance of a second `McpClient` impl — both
//   of which would force a real transport-construction abstraction
//   to be designed rather than guessed. At B.35 we have one client
//   and three transports with deliberately heterogeneous lifecycles;
//   the conformance assertions below are written against the
//   channel + HTTP transports directly, with the same harness pair
//   the per-transport tests already use.

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.35 / plan-named conformance / McpClient', () {
    group('contract — tool discovery', () {
      late McpClient client;
      late _FixtureMcpServer server;
      late McpSession session;

      setUp(() async {
        final pair = _linkedChannelPair();
        server = _FixtureMcpServer(pair.serverSide);
        client = McpClient(
          identity: const McpClientIdentity(
            name: 'tom_brain_substrate_b35',
            version: '0.0.1',
          ),
        );
        final transport = ChannelMcpTransport(
          pair.clientSide,
          id: 'b35-discovery',
        );
        session = await client.connect(transport);
      });

      tearDown(() async {
        await session.close();
        await client.close();
        await server.shutdown();
      });

      test(
          'listTools() returns the catalogue the server advertises, with '
          'name + description + inputSchema preserved as plain Dart',
          () async {
        final tools = await session.listTools();

        // The fixture advertises exactly two tools, by design — the
        // conformance assertion is that **the catalogue surfaces**,
        // not that any particular tool exists.
        expect(tools.map((t) => t.name).toSet(),
            equals(<String>{'echo', 'add'}),
            reason: 'tool discovery must surface the full catalogue the '
                'server advertised, not a subset');

        // The substrate intentionally hides dart_mcp's typed `Tool`
        // wrapper; the conformance assertion is that callers receive
        // plain `String` + `Map<String, Object?>` and can pattern-match
        // without binding to the upstream library.
        for (final tool in tools) {
          expect(tool.name, isA<String>());
          expect(tool.description, anyOf(isNull, isA<String>()));
          expect(tool.inputSchema, isA<Map<String, Object?>>());
          expect(tool.inputSchema['type'], 'object');
        }
      });
    });

    group('contract — tool call roundtrip', () {
      late McpClient client;
      late _FixtureMcpServer server;
      late McpSession session;

      setUp(() async {
        final pair = _linkedChannelPair();
        server = _FixtureMcpServer(pair.serverSide);
        client = McpClient(
          identity: const McpClientIdentity(
            name: 'tom_brain_substrate_b35',
            version: '0.0.1',
          ),
        );
        final transport = ChannelMcpTransport(
          pair.clientSide,
          id: 'b35-roundtrip',
        );
        session = await client.connect(transport);
      });

      tearDown(() async {
        await session.close();
        await client.close();
        await server.shutdown();
      });

      test(
          'callTool() round-trips arguments to the server and returns the '
          "server's content blocks as plain Dart maps", () async {
        final result = await session.callTool('echo', {
          'message': 'tom-brain-b35-roundtrip',
        });

        expect(result.isError, isFalse,
            reason: 'a successful roundtrip must not be flagged isError');
        expect(result.content, hasLength(1));

        final block = result.content.single;
        expect(block, isA<Map<String, Object?>>(),
            reason: 'content blocks must be plain Dart maps so callers '
                'never need to bind to dart_mcp typed wrappers');
        expect(block['type'], 'text');
        expect(block['text'], 'tom-brain-b35-roundtrip',
            reason: 'argument value must arrive at the server unmodified '
                'and the server response must arrive at the client '
                'unmodified — that is the contract of "roundtrip"');
      });

      test(
          'callTool() roundtrips structured (non-string) argument values',
          () async {
        // The `add` fixture proves number-typed arguments survive the
        // JSON-RPC roundtrip on both directions (in: numeric args; out:
        // computed result rendered as text). The conformance concern is
        // that argument types are preserved across the wire, not that
        // the server does arithmetic.
        final result = await session.callTool('add', {'a': 7, 'b': 35});

        expect(result.isError, isFalse);
        expect(result.content.single['text'], '42');
      });
    });

    group('contract — auth failure surfaces as typed error', () {
      late io.HttpServer http;

      setUp(() async {
        http = await io.HttpServer.bind('127.0.0.1', 0);
      });

      tearDown(() async {
        await http.close(force: true);
      });

      test('HTTP 401 from the endpoint surfaces as McpAuthFailed — never '
          'as a raw dart_mcp StateError', () async {
        unawaited(http.forEach((request) async {
          request.response.statusCode = io.HttpStatus.unauthorized;
          await request.response.close();
        }));

        final client = McpClient(
          identity: const McpClientIdentity(
            name: 'tom_brain_substrate_b35',
            version: '0.0.1',
          ),
        );
        addTearDown(client.close);

        final transport = HttpMcpTransport(
          id: 'b35-auth-401',
          url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
          auth: const McpBearerCredential('b35-not-a-real-token'),
          requestTimeout: const Duration(seconds: 2),
        );

        Object? captured;
        try {
          await client.connect(transport);
          fail('Expected the connect to fail with a typed McpAuthFailed.');
        } on Object catch (error) {
          captured = error;
        }

        expect(captured, isA<McpAuthFailed>(),
            reason: 'the contract is that auth failure surfaces as the '
                'typed error subtype — not as the dart_mcp StateError '
                'that would otherwise bubble out of a closed channel');
        expect(captured, isA<McpClientException>(),
            reason: 'McpAuthFailed must remain inside the sealed '
                'McpClientException taxonomy so dispatcher critique '
                'paths can pattern-match exhaustively');

        final authFailed = captured as McpAuthFailed;
        expect(authFailed.endpointId, 'b35-auth-401',
            reason: 'the typed error must carry the endpoint id so '
                'observability + trail entries can attribute the '
                'failure to a specific McpEndpoint');
        expect(authFailed.statusCode, 401,
            reason: 'the typed error must preserve the HTTP status '
                'code that triggered the rejection so the caller can '
                'distinguish 401 (rotate credential) from 403 '
                '(credential is valid but not entitled)');
      });

      test('HTTP 403 from the endpoint also surfaces as McpAuthFailed '
          'with status code preserved', () async {
        // 401 and 403 are both auth-shape failures per
        // `mcp_errors.dart`'s documented mapping — the conformance
        // contract is "the auth-rejection class fires for both", not
        // "the auth-rejection class fires for 401 only".
        unawaited(http.forEach((request) async {
          request.response.statusCode = io.HttpStatus.forbidden;
          await request.response.close();
        }));

        final client = McpClient(
          identity: const McpClientIdentity(
            name: 'tom_brain_substrate_b35',
            version: '0.0.1',
          ),
        );
        addTearDown(client.close);

        final transport = HttpMcpTransport(
          id: 'b35-auth-403',
          url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
          auth: const McpBearerCredential('b35-revoked-token'),
          requestTimeout: const Duration(seconds: 2),
        );

        Object? captured;
        try {
          await client.connect(transport);
          fail('Expected the connect to fail with McpAuthFailed.');
        } on Object catch (error) {
          captured = error;
        }

        expect(captured, isA<McpAuthFailed>());
        expect((captured as McpAuthFailed).statusCode, 403);
      });

      test('non-auth HTTP error (500) must NOT be misclassified as '
          'McpAuthFailed — the auth-vs-transport discrimination is the '
          'point of the typed surface', () async {
        // Counter-example: if 500 also surfaced as McpAuthFailed, the
        // dispatcher would rotate credentials on every server outage.
        // The conformance contract therefore includes a negative
        // assertion alongside the positive one.
        unawaited(http.forEach((request) async {
          request.response.statusCode = io.HttpStatus.internalServerError;
          await request.response.close();
        }));

        final client = McpClient(
          identity: const McpClientIdentity(
            name: 'tom_brain_substrate_b35',
            version: '0.0.1',
          ),
        );
        addTearDown(client.close);

        final transport = HttpMcpTransport(
          id: 'b35-not-auth-500',
          url: Uri.parse('http://${http.address.host}:${http.port}/mcp'),
          auth: const McpBearerCredential('b35-some-token'),
          requestTimeout: const Duration(seconds: 2),
        );

        Object? captured;
        try {
          await client.connect(transport);
          fail('Expected the connect to fail with McpClientException.');
        } on Object catch (error) {
          captured = error;
        }

        expect(captured, isA<McpClientException>());
        expect(captured, isA<McpTransportUnreachable>(),
            reason: '500 is a transport-layer failure, not an auth-layer '
                'failure');
        expect(captured, isNot(isA<McpAuthFailed>()),
            reason: 'discrimination is the point — auth-vs-transport '
                'must be a strict partition, not an overlap');
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Test fixtures (channel pair + dart_mcp fixture server)
// ---------------------------------------------------------------------------
//
// Duplicated locally from `b08_mcp_client_test.dart` to keep B.35 a
// self-contained conformance file. Sharing the fixture is a B.44
// reuse-extraction candidate (logged as Q-B.35.2); for now, two copies
// of ~70 lines beats inventing a `test/_helpers/` package layout that
// the rest of substrate has no use for yet.

/// A linked pair of `StreamChannel<String>` instances. Whatever the
/// client writes to its side appears on the server side, and vice
/// versa. No process boundary, no network — pure in-isolate framing.
({StreamChannel<String> clientSide, StreamChannel<String> serverSide})
    _linkedChannelPair() {
  final clientController = StreamChannelController<String>(
    sync: false,
    allowForeignErrors: true,
  );
  final serverController = StreamChannelController<String>(
    sync: false,
    allowForeignErrors: true,
  );

  clientController.local.stream.listen(
    serverController.local.sink.add,
    onDone: serverController.local.sink.close,
  );
  serverController.local.stream.listen(
    clientController.local.sink.add,
    onDone: clientController.local.sink.close,
  );

  return (
    clientSide: clientController.foreign,
    serverSide: serverController.foreign,
  );
}

/// Minimal `dart_mcp` server fixture. Registers `echo` (string
/// passthrough) and `add` (numeric arguments → text result) so the
/// conformance assertions exercise both string- and number-typed
/// argument shapes across the wire.
base class _FixtureMcpServer extends mcp_server.MCPServer
    with mcp_server.ToolsSupport {
  _FixtureMcpServer(super.channel)
      : super.fromStreamChannel(
          implementation: mcp_server.Implementation(
            name: 'b35_fixture_mcp_server',
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
        final rendered = sum == sum.truncateToDouble()
            ? sum.toInt().toString()
            : sum.toString();
        return mcp_server.CallToolResult(
          content: [mcp_server.Content.text(text: rendered)],
        );
      },
      validateArguments: false,
    );

    return super.initialize(request);
  }
}
