// Shared scaffolding for the LIVE end-to-end suites (r32 / r34 / r50).
//
// These suites each drive the *real* substrate `standUpBrainProcessFromConfig`
// manufactures (oMLX for chat, Ollama for embeddings) against the real on-disk
// `SqliteTomBrainMemory`, then inspect the persisted graph through the memory
// MCP server. They share a large body of identical scaffolding — daemon-endpoint
// resolution + reachability probing, the whole-process YAML, the vec0-binary
// skip gate, the standalone-platform install, the HTTP/SSE post helpers, and the
// in-process MCP inspection harness. That common surface lives here so the three
// suites carry only their distinct assertions (MSPP-50 / MSPP-60).
//
// ── Skip semantics (preserved verbatim from the original suites) ─────
//
//   * No packaged vec0 binary for this platform ⇒ the whole group skips
//     (the on-disk store loads the extension at `open`). Computed once via
//     [sqliteVecSkipReason] and passed as the group `skip:`.
//   * A daemon (oMLX / Ollama) not reachable ⇒ that test skips at runtime via
//     [LiveEndpoint.unreachableReason] + `markTestSkipped` (a per-test probe, so
//     the connect can actually complete — registration-skip vs runtime-skip).
//
// ── Why memory is inspected after the process stops (r32 / r50) ──────
//
// The run hosts `SqliteTomBrainMemory` inside a worker isolate; the MCP server
// forwards each tool call to a `TomBrainMemory` it holds directly and cannot
// reach a store behind a `SendPort`. But the store is on disk: once the process
// stops (disposing the isolate, closing the DB handles), a fresh in-host store
// re-opened over the same directory reads back everything the run persisted. So
// those suites run the live exchange, stop the process, then re-open the same
// on-disk root in-host via [inspectOnDisk]. r34 instead inspects its still-open
// in-host store directly via [inspectViaMcp].

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        MemoryConfig,
        SqliteTomBrainMemory,
        SqliteVecBinaryResolver,
        TomBrainMemory,
        TomBrainMemoryMcpServer;
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

/// The bearer token the single-principal access config binds (r32 / r34); the
/// request authenticates with it.
const String defaultBearerToken = 'run-token';

// ── Platform + vec0 binary gate ─────────────────────────────────────

/// Installs the standalone platform so the live HTTP path is exercised
/// end-to-end. The real providers source their wire HTTP client from the
/// `tom_core_kernel` factory via the active `TomPlatformUtils`; a bare
/// `dart test` runs the fallback platform, whose `httpClient()` throws. The
/// production entrypoint installs the standalone platform at startup — the
/// suites do the same in `setUpAll`.
void installStandalonePlatformForLiveHttp() {
  TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`, walking up from the package
/// root. Returns `null` when no such directory exists within eight levels.
String? findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// The group-level `skip:` rationale when this platform has no packaged vec0
/// binary under `tom_binaries/sqlite_vec` (the on-disk store loads the extension
/// at `open`), or `null` when a usable binary is present. [vecRoot] is the
/// result of [findSqliteVecRoot].
String? sqliteVecSkipReason(String? vecRoot) {
  final resolver = SqliteVecBinaryResolver();
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }
  return resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;
}

// ── Live daemon endpoints ───────────────────────────────────────────

/// A live daemon endpoint: its (slash-terminated) base URI and the model id to
/// exercise. Resolution is synchronous and reads env overrides; reachability is
/// a separate, awaited TCP probe done inside the test body (so the connect can
/// actually complete — runtime-skip vs registration-skip).
class LiveEndpoint {
  /// The normalised base URI (explicit port + trailing slash).
  final Uri baseUri;

  /// The model id to exercise.
  final String model;

  /// The daemon's display name (used in the skip rationale).
  final String daemonName;

  LiveEndpoint._(this.baseUri, this.model, this.daemonName);

  /// Reads `[baseUriEnv]` (default [defaultBaseUri]) and `[modelEnv]` (default
  /// [defaultModel]); normalises the base URI to an explicit port + trailing
  /// slash so the providers' relative path resolution keeps the host.
  factory LiveEndpoint.resolve({
    required String baseUriEnv,
    required String defaultBaseUri,
    required String modelEnv,
    required String defaultModel,
    required String daemonName,
  }) {
    final env = Platform.environment;
    final model = env[modelEnv] ?? defaultModel;
    Uri parsed;
    try {
      parsed = Uri.parse(env[baseUriEnv] ?? defaultBaseUri);
    } on FormatException {
      parsed = Uri.parse(defaultBaseUri);
    }
    final port =
        parsed.hasPort ? parsed.port : (parsed.scheme == 'https' ? 443 : 80);
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return LiveEndpoint._(
      parsed.replace(port: port, path: path),
      model,
      daemonName,
    );
  }

  /// One awaited `Socket.connect` with a two-second timeout. Returns `null` when
  /// reachable, or a skip-rationale string when not.
  Future<String?> unreachableReason() async {
    try {
      final socket = await Socket.connect(baseUri.host, baseUri.port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return null;
    } on Object catch (e) {
      return 'no TCP connect to ${baseUri.host}:${baseUri.port} within 2s '
          '($daemonName not reachable; this live e2e is skipped off-host by '
          'design): $e';
    }
  }
}

/// oMLX (OpenAI-compatible chat) — base URI MUST be host-only (no `/v1`); the
/// passthrough provider resolves `v1/chat/completions` relatively.
LiveEndpoint omlxEndpoint() => LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OMLX_BASE_URI',
      defaultBaseUri: 'http://10.8.0.7:8000/',
      modelEnv: 'TOM_BRAIN_OMLX_MODEL',
      defaultModel: 'gemma-4-26b-a4b-it-4bit',
      daemonName: 'oMLX',
    );

/// Ollama (embeddings). Defaults to the on-box daemon (`nomic-embed-text`, 768
/// dims); Ollama binds loopback, so the default is `127.0.0.1`.
LiveEndpoint ollamaEndpoint() => LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OLLAMA_BASE_URI',
      defaultBaseUri: 'http://127.0.0.1:11434/',
      modelEnv: 'TOM_BRAIN_OLLAMA_EMBED_MODEL',
      defaultModel: 'nomic-embed-text',
      daemonName: 'Ollama',
    );

// ── Whole-process YAML ──────────────────────────────────────────────

/// The version-controlled cognition config tree (`config/bomber/cognition`) the
/// live run wires the `sub.run` prompt / route resolvers from
/// (`prompt_configuration.md` §7.4). `Directory.current` is the package root
/// under `dart test` / testkit.
String cognitionConfigRoot() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    ).absolute.path;

/// Builds the whole-process YAML for a live run: the real oMLX + Ollama
/// substrate (routing the user-facing role to oMLX), the on-disk memory rooted
/// at [memoryRoot] (vec0 from [binariesRoot]), the [accessBlock] (the full
/// `access:` section — use [bearerAccessBlock] or [apiKeyAccessBlock]), and the
/// cognition tree at [cognitionRoot].
String liveRunYaml({
  required LiveEndpoint omlx,
  required LiveEndpoint ollama,
  required String memoryRoot,
  required String binariesRoot,
  required String cognitionRoot,
  required String accessBlock,
}) =>
    '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: ${omlx.baseUri}
      models:
        - ${omlx.model}
    - id: ollama
      kind: ollama
      baseUrl: ${ollama.baseUri}
      models:
        - ${ollama.model}
  roleRoutes:
    assistant_to_user:
      - providerId: omlx
        model: ${omlx.model}
  embedding:
    providerId: ollama
    model: ${ollama.model}
    dims: 768
    normalize: true
memory:
  root: "$memoryRoot"
  sqliteVec:
    binariesRoot: "$binariesRoot"
${accessBlock}cognition:
  root: "$cognitionRoot"
''';

/// The `access:` block authenticating a single bearer principal (r32 / r34): a
/// permissive single-user config whose `openaiBearerTokens` carries [token].
String bearerAccessBlock(String token) => '''
access:
  openai:
    port: 8080
    basePath: /v1
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - $token
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000
''';

/// The `access:` block with one namespaced `apiKeys[]` credential (r50): the key
/// [key] bound to [principal], namespaced by [sessionPrefix] / [memoryPrefix] so
/// a marker-wrapped Bearer routes the request to a profile.
String apiKeyAccessBlock({
  required String key,
  required String principal,
  required String sessionPrefix,
  required String memoryPrefix,
  required String displayName,
}) =>
    '''
access:
  openai:
    port: 8080
    basePath: /v1
  apiKeys:
    - key: $key
      principal: $principal
      sessionPrefix: $sessionPrefix
      memoryPrefix: $memoryPrefix
      displayName: $displayName
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000
''';

// ── HTTP / SSE post helpers ─────────────────────────────────────────

/// A `chat/completions` request body for [prompt] with the given [stream] flag.
Map<String, Object?> chatBody(String prompt, {required bool stream}) =>
    <String, Object?>{
      'model': 'tom-assistant',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': stream,
    };

/// The result of a JSON `POST`: status + decoded JSON body.
typedef JsonPostResult = ({int statusCode, Object? body});

/// Issues a JSON `POST` and returns status + decoded JSON body.
Future<JsonPostResult> postJson(
  int port,
  String path,
  Object body, {
  required String token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      body: text.isEmpty ? null : jsonDecode(text),
    );
  } finally {
    client.close(force: true);
  }
}

/// The raw result of a streaming `POST`: status, `content-type`, raw body.
typedef StreamPostResult = ({int statusCode, String? contentType, String body});

/// Issues a streaming JSON `POST` and returns status, `content-type`, raw body.
Future<StreamPostResult> postForStream(
  int port,
  String path,
  Object body, {
  required String token,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.add(utf8.encode(jsonEncode(body)));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (
      statusCode: response.statusCode,
      contentType: response.headers.value('content-type'),
      body: text,
    );
  } finally {
    client.close(force: true);
  }
}

/// Splits an SSE wire body into its ordered, non-empty `data:` frame lines.
List<String> sseFrames(String body) => body
    .split('\n\n')
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList();

/// Decodes the JSON of one `data: {…}` frame, or `null` for `data: [DONE]`.
Map<String, Object?>? sseFramePayload(String frame) {
  if (!frame.startsWith('data:')) return null;
  final String data = frame.substring('data:'.length).trim();
  if (data == '[DONE]') return null;
  return jsonDecode(data) as Map<String, Object?>;
}

// ── In-process MCP inspection ───────────────────────────────────────

/// Opens a fresh in-host `SqliteTomBrainMemory` over [config] (the same on-disk
/// root a stopped run wrote to — already profile-bound by the caller via
/// `MemoryConfig.withProfile`), stands a `TomBrainMemoryMcpServer` up over it,
/// runs the MCP handshake, hands a [McpInspector] to [body], then tears the
/// connection and the store down.
Future<void> inspectOnDisk(
  MemoryConfig config,
  Future<void> Function(McpInspector mcp) body,
) async {
  final SqliteTomBrainMemory memory = SqliteTomBrainMemory();
  await memory.open(config);
  try {
    await inspectViaMcp(memory, body);
  } finally {
    await memory.close();
  }
}

/// Stands the memory MCP server up over [memory] (anonymous mode), runs the
/// handshake, hands a [McpInspector] to [body], then tears the connection down.
/// Eager construction so the server is listening before the client starts
/// `initialize` (the E.55 in-process MCP harness).
Future<void> inspectViaMcp(
  TomBrainMemory memory,
  Future<void> Function(McpInspector mcp) body,
) async {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  final clientChannel = StreamChannel<String>.withCloseGuarantee(
    serverController.stream,
    clientController.sink,
  );
  final serverChannel = StreamChannel<String>.withCloseGuarantee(
    clientController.stream,
    serverController.sink,
  );

  final client = _RunMcpClient();
  final server = TomBrainMemoryMcpServer(serverChannel, memory: memory);
  final connection = client.connectServer(clientChannel);

  final init = await connection.initialize(
    mcp_server.InitializeRequest(
      protocolVersion: mcp_server.ProtocolVersion.latestSupported,
      capabilities: client.capabilities,
      clientInfo: client.implementation,
    ),
  );
  if (init.protocolVersion?.isSupported == true) {
    connection.notifyInitialized(mcp_server.InitializedNotification());
    await server.initialized;
  }

  try {
    await body(McpInspector(connection));
  } finally {
    await client.shutdown();
    await server.shutdown();
  }
}

/// A thin read-only view over an MCP [mcp_client.ServerConnection] that calls the
/// memory MCP tools and decodes their JSON payloads. Carries the union of the
/// read tools the live suites exercise; each suite uses the subset it needs.
class McpInspector {
  final mcp_client.ServerConnection _connection;

  McpInspector(this._connection);

  /// `memory.recall` (BM25) → the recalled node maps.
  Future<List<Map<String, Object?>>> recall({
    required String text,
    int k = 8,
  }) async {
    final payload = await _call('memory.recall', <String, Object?>{
      'text': text,
      'modes': <String>['bm25'],
      'k': k,
    });
    return _maps(payload['nodes']);
  }

  /// `memory.get` → the fetched node maps.
  Future<List<Map<String, Object?>>> get({required List<String> ids}) async {
    final payload = await _call('memory.get', <String, Object?>{'ids': ids});
    return _maps(payload['nodes']);
  }

  /// `memory.stack.list` → the stack-summary maps.
  Future<List<Map<String, Object?>>> stackList() async {
    final payload = await _call('memory.stack.list', const <String, Object?>{});
    return _maps(payload['stacks']);
  }

  /// `memory.stack.peek` → the stack-entry maps.
  Future<List<Map<String, Object?>>> stackPeek({
    required String name,
    int k = 16,
  }) async {
    final payload = await _call('memory.stack.peek', <String, Object?>{
      'name': name,
      'k': k,
    });
    return _maps(payload['entries']);
  }

  Future<Map<String, Object?>> _call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final result = await _connection.callTool(
      mcp_server.CallToolRequest(name: name, arguments: arguments),
    );
    expect(result.isError, isNot(isTrue),
        reason: 'MCP tool $name returned an error');
    final text = (result.content.first as mcp_server.TextContent).text;
    return jsonDecode(text) as Map<String, Object?>;
  }

  List<Map<String, Object?>> _maps(Object? raw) => <Map<String, Object?>>[
        for (final item in (raw as List)) item as Map<String, Object?>,
      ];
}

base class _RunMcpClient extends mcp_client.MCPClient {
  _RunMcpClient()
      : super(
          mcp_client.Implementation(
            name: 'tom-brain-run-e2e-client',
            version: '0.0.1',
          ),
        );
}
