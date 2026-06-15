// PT-5.1 / § 8.4 — the production `McpReadConnection` over Streamable HTTP.
//
// `HttpMcpReadConnection` wraps the substrate's outbound `McpSession` into the
// observatory's transport-neutral read seam. These tests drive the *real*
// substrate `McpClient` + `HttpMcpTransport` against a loopback `HttpServer`
// that speaks the MCP JSON-RPC wire (the same fixture style as the substrate's
// own `b08_http_transport_roundtrip_test.dart`), so the full
// initialize → tools/list → tools/call handshake is exercised end-to-end. A
// `MockClient` would have to hand-fake that entire protocol; a loopback server
// is both shorter and faithful.
//
// What is pinned here:
//   - listTools maps each advertised tool to `{name, description, inputSchema}`.
//   - callTool unwraps `structuredContent` when present (the seam contract).
//   - callTool decodes the JSON object carried by a single text block when no
//     structuredContent is sent.
//   - a tool-reported error (`isError: true`) surfaces as `McpReadException`.
//   - a non-JSON / non-object text payload surfaces as `McpReadException`.
//   - a content-less result surfaces as `McpReadException`.
//   - an unreachable endpoint and a 401 (bearer rejected) both surface as
//     `McpReadException` (environmental — the views render "memory unavailable").
//   - the bearer token, when supplied, is forwarded as `Authorization: Bearer`.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:test/test.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';

void main() {
  group('HttpMcpReadConnection — over a loopback MCP server', () {
    late _McpServerFixture fixture;

    setUp(() async {
      fixture = await _McpServerFixture.start();
    });

    tearDown(() async {
      await fixture.stop();
    });

    test('listTools maps each tool to {name, description, inputSchema}',
        () async {
      fixture.tools = <Map<String, Object?>>[
        <String, Object?>{
          'name': 'memory.recall',
          'description': 'recall by query',
          'inputSchema': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'q': <String, Object?>{'type': 'string'},
            },
          },
        },
      ];

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      final tools = await connection.listTools();
      expect(tools, hasLength(1));
      expect(tools.single['name'], 'memory.recall');
      expect(tools.single['description'], 'recall by query');
      expect((tools.single['inputSchema'] as Map)['type'], 'object');
    });

    test('callTool unwraps structuredContent when present', () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'ignored when structured'},
            ],
            'structuredContent': <String, Object?>{
              'nodes': <Object?>[
                <String, Object?>{'id': 'n_1', 'typeName': 'Question'},
              ],
            },
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      final payload =
          await connection.callTool('memory.recall', <String, Object?>{'q': 'x'});
      expect(payload.containsKey('nodes'), isTrue);
      expect((payload['nodes'] as List), hasLength(1));
      // The structuredContent wins over the text block.
      expect(payload.containsKey('content'), isFalse);

      // The args the tool was called with reached the server verbatim.
      expect(fixture.lastCall?.name, 'memory.recall');
      expect(fixture.lastCall?.args, <String, Object?>{'q': 'x'});
    });

    test('callTool decodes the JSON object in a single text block when there '
        'is no structuredContent', () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': jsonEncode(<String, Object?>{'profile': 'default'}),
              },
            ],
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      final payload =
          await connection.callTool('memory.profile.current', const <String, Object?>{});
      expect(payload, <String, Object?>{'profile': 'default'});
    });

    test('a tool-reported error (isError) surfaces as McpReadException',
        () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'isError': true,
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'no such node'},
            ],
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      await expectLater(
        connection.callTool('memory.get', <String, Object?>{'id': 'missing'}),
        throwsA(isA<McpReadException>()),
      );
    });

    test('a non-JSON text payload surfaces as McpReadException', () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'not json at all'},
            ],
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      await expectLater(
        connection.callTool('memory.recall', const <String, Object?>{}),
        throwsA(isA<McpReadException>()),
      );
    });

    test('a content-less result surfaces as McpReadException', () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'content': <Object?>[],
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      await expectLater(
        connection.callTool('memory.recall', const <String, Object?>{}),
        throwsA(isA<McpReadException>()),
      );
    });

    test('a JSON-but-non-object text payload surfaces as McpReadException',
        () async {
      fixture.callToolResult = (name, args) => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '[1, 2, 3]'},
            ],
          };

      final connection = await HttpMcpReadConnection.connect(fixture.url);
      addTearDown(connection.close);

      await expectLater(
        connection.callTool('memory.recall', const <String, Object?>{}),
        throwsA(isA<McpReadException>()),
      );
    });
  });

  group('HttpMcpReadConnection — connect failures degrade to McpReadException',
      () {
    test('an unreachable endpoint surfaces as McpReadException', () async {
      // Bind+release a port so it is almost certainly closed when we connect.
      final probe = await io.HttpServer.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close(force: true);

      await expectLater(
        HttpMcpReadConnection.connect(
          Uri.parse('http://127.0.0.1:$port/mcp'),
        ),
        throwsA(isA<McpReadException>()),
      );
    });

    test('a 401 (bearer rejected) surfaces as McpReadException and the token '
        'was forwarded', () async {
      String? seenAuth;
      final server = await io.HttpServer.bind('127.0.0.1', 0);
      unawaited(server.forEach((request) async {
        seenAuth = request.headers.value('authorization');
        await utf8.decodeStream(request);
        request.response.statusCode = io.HttpStatus.unauthorized;
        await request.response.close();
      }));
      addTearDown(() => server.close(force: true));

      final url = Uri.parse('http://${server.address.host}:${server.port}/mcp');
      await expectLater(
        HttpMcpReadConnection.connect(url, bearerToken: 'tok-123'),
        throwsA(isA<McpReadException>()),
      );
      expect(seenAuth, 'Bearer tok-123');
    });
  });
}

/// A loopback `HttpServer` that speaks just enough of the MCP Streamable-HTTP
/// JSON-RPC wire to complete `initialize` → `tools/list` → `tools/call`.
///
/// It echoes the client's `protocolVersion` back in the initialize result so
/// the negotiated version is always supported, and serves JSON responses
/// (`application/json`) — the connector handles both JSON and SSE framing, and
/// the JSON path is the simpler fixture.
final class _McpServerFixture {
  _McpServerFixture._(this._server);

  final io.HttpServer _server;

  /// Tools returned by `tools/list`. Each is a `{name, description,
  /// inputSchema}` map.
  List<Map<String, Object?>> tools = const <Map<String, Object?>>[];

  /// Produces the `tools/call` *result* object (`{content, structuredContent?,
  /// isError?}`) for a given tool name + arguments.
  Map<String, Object?> Function(String name, Map<String, Object?> args)
      callToolResult = (_, _) => <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': '{}'},
            ],
          };

  /// The most recent `tools/call` the fixture saw — for argument assertions.
  ({String name, Map<String, Object?> args})? lastCall;

  Uri get url =>
      Uri.parse('http://${_server.address.host}:${_server.port}/mcp');

  static Future<_McpServerFixture> start() async {
    final server = await io.HttpServer.bind('127.0.0.1', 0);
    final fixture = _McpServerFixture._(server);
    unawaited(server.forEach(fixture._handle));
    return fixture;
  }

  Future<void> _handle(io.HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final message = jsonDecode(body) as Map<String, Object?>;
    final method = message['method'] as String?;
    final id = message['id'];

    // Notifications (no id, e.g. notifications/initialized) — accept silently.
    if (id == null) {
      request.response.statusCode = io.HttpStatus.ok;
      await request.response.close();
      return;
    }

    final Map<String, Object?> result;
    switch (method) {
      case 'initialize':
        final params = (message['params'] as Map?) ?? const <String, Object?>{};
        result = <String, Object?>{
          'protocolVersion': params['protocolVersion'],
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'serverInfo': <String, Object?>{
            'name': 'fixture-memory-mcp',
            'version': '0.0.1',
          },
        };
      case 'tools/list':
        result = <String, Object?>{'tools': tools};
      case 'tools/call':
        final params = (message['params'] as Map?) ?? const <String, Object?>{};
        final name = params['name'] as String;
        final args = ((params['arguments'] as Map?) ?? const <String, Object?>{})
            .map((k, v) => MapEntry(k as String, v));
        lastCall = (name: name, args: Map<String, Object?>.from(args));
        result = callToolResult(name, Map<String, Object?>.from(args));
      default:
        request.response.statusCode = io.HttpStatus.ok;
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'method not found: $method',
          },
        }));
        await request.response.close();
        return;
    }

    request.response.statusCode = io.HttpStatus.ok;
    request.response.headers.contentType = io.ContentType.json;
    request.response.write(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}
