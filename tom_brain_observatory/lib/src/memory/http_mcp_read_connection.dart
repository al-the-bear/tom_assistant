// The production [McpReadConnection] (`prompt_tracing.md` § 8.4): a
// Streamable-HTTP client over the brain's standalone memory MCP server
// (`tom_brain_memory/bin/memory_mcp_server.dart`, path `/mcp`). It wraps the
// substrate's outbound `McpSession` into the observatory's transport-neutral
// read seam, so the observatory holds no `dart_mcp` wire types of its own — the
// substrate already owns the client side of the protocol.
//
// Why this honours OBS-3 (the observatory "never opens a DB file",
// `doc/running_the_observatory.md` § 5, proven by `obs_conformance_test.dart`):
// the SQLite store handle lives in the *separate* `memory_mcp_server` process,
// which opens the root WAL-mode read-concurrent. This class holds only an HTTP
// MCP session — the exact nine-read door the [MemoryReadClient] over it (PT-5.1)
// confines itself to. A live brain and the observatory can therefore read the
// same memory root at once; neither blocks the other.
//
// Every failure is environmental: a connect/handshake error or a mid-call
// transport drop surfaces as [McpReadException], which the memory views render
// as "memory unavailable" rather than crashing (§ 8.4).

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        HttpMcpTransport,
        McpBearerCredential,
        McpClient,
        McpClientException,
        McpClientIdentity,
        McpSession,
        McpToolResult;

import 'mcp_read_connection.dart';

/// A [McpReadConnection] backed by a Streamable-HTTP [McpSession] to the brain's
/// standalone memory MCP server. Open one with [connect]; close it with [close].
final class HttpMcpReadConnection implements McpReadConnection {
  HttpMcpReadConnection._(this._client, this._session, this._ownedHttpClient);

  final McpClient _client;
  final McpSession _session;

  /// The HTTP client this connection created and must therefore close itself.
  /// `null` when the caller injected its own client (a test `MockClient`) — that
  /// client's lifecycle stays with the caller. See [connect].
  final http.Client? _ownedHttpClient;

  /// The MCP client identity the observatory presents on the `initialize`
  /// handshake — read-only by construction (it calls only the nine read tools).
  static const McpClientIdentity _identity = McpClientIdentity(
    name: 'tom-brain-observatory',
    version: '0.0.1',
  );

  /// Opens and initializes a read connection to the memory MCP server at [url]
  /// (the standalone server serves `/mcp`). [bearerToken] is forwarded as
  /// `Authorization: Bearer <token>` when the endpoint requires auth; omit it
  /// for the anonymous loopback posture. [httpClient] is injectable for tests
  /// (a loopback / mock client standing in for the network); when omitted, the
  /// connection creates and owns a plain `package:http` client.
  ///
  /// Why we supply the client rather than let [HttpMcpTransport] source one from
  /// `tom_core_kernel.TomHttpClientFactory`: the factory's default platform path
  /// throws `UnimplementedError` in a plain server VM (no Flutter/web platform
  /// registered), which is exactly the `dart run bin/observatory.dart` context.
  /// The observatory only ever opens this one loopback read connection, so a
  /// directly-constructed client is both correct and the simplest thing that
  /// boots. An injected client's lifecycle stays with the caller; an owned one
  /// is closed by [close].
  ///
  /// A transport or handshake failure surfaces as [McpReadException] —
  /// environmental, so the caller degrades to "memory unavailable" rather than
  /// aborting the observatory boot.
  static Future<HttpMcpReadConnection> connect(
    Uri url, {
    String? bearerToken,
    http.Client? httpClient,
  }) async {
    final ownedHttpClient = httpClient == null ? http.Client() : null;
    final client = McpClient(identity: _identity);
    final transport = HttpMcpTransport(
      id: 'memory',
      url: url,
      auth: bearerToken == null ? null : McpBearerCredential(bearerToken),
      httpClient: httpClient ?? ownedHttpClient,
    );
    try {
      final session = await client.connect(transport);
      return HttpMcpReadConnection._(client, session, ownedHttpClient);
    } on McpClientException catch (error) {
      await client.close();
      ownedHttpClient?.close();
      throw McpReadException(
        'cannot reach the memory MCP server at $url',
        cause: error,
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> listTools() async {
    try {
      final tools = await _session.listTools();
      return <Map<String, Object?>>[
        for (final tool in tools)
          <String, Object?>{
            'name': tool.name,
            'description': tool.description,
            'inputSchema': tool.inputSchema,
          },
      ];
    } on McpClientException catch (error) {
      throw McpReadException('listing memory tools failed', cause: error);
    }
  }

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final McpToolResult result;
    try {
      result = await _session.callTool(name, args);
    } on McpClientException catch (error) {
      throw McpReadException('memory tool "$name" failed', cause: error);
    }
    if (result.isError) {
      throw McpReadException(
        'memory tool "$name" reported an error',
        cause: _firstText(result.content),
      );
    }
    // The seam contract (§ 8.4): the tool's decoded payload map, which arrives
    // either as MCP `structuredContent` or as a single text block whose body is
    // that JSON object. Unwrapping it here keeps [MemoryReadClient] a pure
    // marshalling facade.
    final structured = result.structuredContent;
    if (structured != null) return structured;
    return _decodeTextPayload(name, result.content);
  }

  @override
  Future<void> close() async {
    await _client.close();
    _ownedHttpClient?.close();
  }

  /// Decodes the JSON object carried by the first text content block. The v1
  /// memory read tools always answer a JSON object; anything else is a server
  /// contract violation surfaced as [McpReadException].
  static Map<String, Object?> _decodeTextPayload(
    String tool,
    List<Map<String, Object?>> content,
  ) {
    final text = _firstText(content);
    if (text == null) {
      throw McpReadException(
        'memory tool "$tool" returned neither structuredContent nor text',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw McpReadException(
        'memory tool "$tool" returned non-JSON text',
        cause: error,
      );
    }
    if (decoded is! Map) {
      throw McpReadException(
        'memory tool "$tool" returned a non-object JSON payload',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  /// The text of the first `type: "text"` content block, or `null` when none
  /// carries text.
  static String? _firstText(List<Map<String, Object?>> content) {
    for (final block in content) {
      if (block['type'] == 'text' && block['text'] is String) {
        return block['text'] as String;
      }
    }
    return null;
  }
}
