// #32 — LIVE end-to-end, OpenAI channel.
//
// Plan-2 step #32 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "LIVE end-to-end — OpenAI channel. Start the assembled process; send a real
//    POST /v1/chat/completions (stream + non-stream); assert the D4rt
//    `answer_with_memory_v1` runs, `recall` + `persist` hit the real on-disk
//    memory, and the answer is streamed from oMLX; then inspect the new Event +
//    Conclusion + interest stack via the MCP server. Verify: the full
//    prompt→script→memory→oMLX→answer→MCP-inspect chain passes against live oMLX
//    + Ollama."
//
// ── What this suite proves (and how it differs from #30 / #31) ───────
//
// #30 and #31 stand the *real* cognition up but never issue a chat completion —
// they only hit `/healthz` + `/v1/models`, so oMLX / Ollama are constructed but
// never dialed. #32 is the first suite that drives the **whole live chain**:
//
//   prompt → OpenAI edge → dispatcher → `answer_with_memory_v1` (D4rt) →
//   `recall`/`embed`/`classify`/`persist` against the **real on-disk
//   `SqliteTomBrainMemory`** → `llm(assistant_to_user)` **streamed from live
//   oMLX** → answer on the wire → memory inspected **through the MCP server**.
//
// The substrate is the *real* one `standUpBrainProcessFromConfig` manufactures
// from the parsed `substrate:` section (oMLX for chat, Ollama for embeddings) —
// no stub. So this suite only passes when both daemons are live; off-host it
// skips (per-test reachability probe), and on a platform with no packaged vec0
// the whole group skips (the on-disk store loads the extension at `open`).
//
// ── Why memory is inspected after the process stops ──────────────────
//
// The run hosts `SqliteTomBrainMemory` inside a worker isolate (the production
// `createSqliteTomBrainMemory` factory), and the MCP server forwards each tool
// call to a `TomBrainMemory` it holds *directly* — it cannot reach a store
// behind a `SendPort` (the same constraint E.55 documents). But the store is
// **on disk**: once the process stops (which disposes the isolate and closes the
// database handles), a fresh in-host `SqliteTomBrainMemory` opened over the same
// directory reads back everything the run persisted. So each test runs the live
// exchange, stops the process, then re-opens the same on-disk root in-host and
// inspects it through a real `dart_mcp` client → `TomBrainMemoryMcpServer` pair.
// This is the brain's true external memory-inspection surface, exercised over
// the real persisted graph.
//
// ── Why recall is split into two queries (prompt + answer) ───────────
//
// The run persists an `Event` whose `summary` is the prompt and a `Conclusion`
// whose `statement` is the (live, non-deterministic) answer. The memory MCP
// `recall` is BM25 over the per-type FTS index, so the most reliable way to
// surface each node is to query by *its own* indexed text: `recall(prompt)`
// ranks the `Event` (summary), `recall(answer)` ranks the `Conclusion`
// (statement). The assertions then locate each node by its exact field value, so
// they survive whatever wording live oMLX returns.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_access/tom_brain_access.dart'
    show serveWithShelfIo;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        MemoryConfig,
        SqliteTomBrainMemory,
        SqliteVecBinaryResolver,
        TomBrainMemory,
        TomBrainMemoryMcpServer;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

/// The bearer token the live access config binds; the request authenticates
/// with it.
const String _bearerToken = 'run-token';

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors the #30 / #31 suites.
String? _findSqliteVecRoot() {
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

/// A live daemon endpoint: its (slash-terminated) base URI and the model id to
/// exercise. Resolution is synchronous and reads env overrides; reachability is
/// a separate, awaited TCP probe done inside the test body (so the connect can
/// actually complete — see p2_12's note on runtime-skip vs registration-skip).
class _LiveEndpoint {
  final Uri baseUri;
  final String model;
  final String daemonName;

  _LiveEndpoint._(this.baseUri, this.model, this.daemonName);

  /// Reads `[baseUriEnv]` (default [defaultBaseUri]) and `[modelEnv]` (default
  /// [defaultModel]); normalises the base URI to an explicit port + trailing
  /// slash so the providers' relative path resolution keeps the host.
  factory _LiveEndpoint.resolve({
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
    return _LiveEndpoint._(
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
_LiveEndpoint _omlx() => _LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OMLX_BASE_URI',
      defaultBaseUri: 'http://10.8.0.7:8000/',
      modelEnv: 'TOM_BRAIN_OMLX_MODEL',
      defaultModel: 'gemma-4-26b-a4b-it-4bit',
      daemonName: 'oMLX',
    );

/// Ollama (embeddings). Defaults to the on-box daemon (`nomic-embed-text`, 768
/// dims); Ollama binds loopback, so the default is `127.0.0.1`.
_LiveEndpoint _ollama() => _LiveEndpoint.resolve(
      baseUriEnv: 'TOM_BRAIN_OLLAMA_BASE_URI',
      defaultBaseUri: 'http://127.0.0.1:11434/',
      modelEnv: 'TOM_BRAIN_OLLAMA_EMBED_MODEL',
      defaultModel: 'nomic-embed-text',
      daemonName: 'Ollama',
    );

/// Builds the whole-process YAML for the live run: the real oMLX + Ollama
/// substrate, the on-disk memory rooted at [memoryRoot] (vec0 from
/// [binariesRoot]), and a permissive single-bearer access config.
/// The version-controlled cognition config tree (`config/bomber/cognition`)
/// the live run wires the `sub.run` prompt / route resolvers from
/// (`prompt_configuration.md` §7.4). `Directory.current` is the package root
/// under `dart test` / testkit.
String _cognitionConfigRoot() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    ).absolute.path;

String _liveRunYaml({
  required _LiveEndpoint omlx,
  required _LiveEndpoint ollama,
  required String memoryRoot,
  required String binariesRoot,
  required String cognitionRoot,
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
access:
  openai:
    port: 8080
    basePath: /v1
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - $_bearerToken
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000
cognition:
  root: "$cognitionRoot"
''';

/// A `chat/completions` request body for [prompt].
Map<String, Object?> _chatBody(String prompt, {required bool stream}) =>
    <String, Object?>{
      'model': 'tom-assistant',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': stream,
    };

/// Issues a JSON `POST` and returns status + decoded JSON body.
Future<({int statusCode, Object? body})> _postJson(
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
typedef _StreamResult = ({int statusCode, String? contentType, String body});

/// Issues a streaming JSON `POST` and returns status, `content-type`, raw body.
Future<_StreamResult> _postForStream(
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
List<String> _frames(String body) => body
    .split('\n\n')
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList();

/// Decodes the JSON of one `data: {…}` frame, or `null` for `data: [DONE]`.
Map<String, Object?>? _framePayload(String frame) {
  if (!frame.startsWith('data:')) return null;
  final String data = frame.substring('data:'.length).trim();
  if (data == '[DONE]') return null;
  return jsonDecode(data) as Map<String, Object?>;
}

void main() {
  // The real providers source their wire HTTP client from the `tom_core_kernel`
  // factory via the active `TomPlatformUtils`; a bare `dart test` runs the
  // fallback platform, whose `httpClient()` throws. The production entrypoint
  // installs the standalone platform at startup — the test does the same so the
  // live HTTP path is exercised end-to-end (mirrors #30 / #31 / p2_12).
  setUpAll(() {
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
  });

  final String? vecRoot = _findSqliteVecRoot();
  final SqliteVecBinaryResolver resolver = SqliteVecBinaryResolver();
  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final String path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }
  final String? skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('#32 LIVE end-to-end — OpenAI channel', () {
    /// Stands a fresh live cognition up over a unique on-disk memory root.
    /// Returns the running process and the parsed config (its `memory` section
    /// is reused to re-open the same store for MCP inspection after teardown).
    Future<({BrainProcess process, BrainRunConfig config})> standUpLive({
      required _LiveEndpoint omlx,
      required _LiveEndpoint ollama,
    }) async {
      final Directory memoryRoot =
          Directory.systemTemp.createTempSync('tom_brain_run_32_mem_');
      addTearDown(() {
        if (memoryRoot.existsSync()) memoryRoot.deleteSync(recursive: true);
      });

      final BrainRunConfig config = BrainRunConfigLoader.parse(
        _liveRunYaml(
          omlx: omlx,
          ollama: ollama,
          memoryRoot: memoryRoot.path,
          binariesRoot: vecRoot!,
          cognitionRoot: _cognitionConfigRoot(),
        ),
      );
      final BrainProcess process = await standUpBrainProcessFromConfig(
        config,
        // Bind an OS-assigned ephemeral port; read the real one back.
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
      return (process: process, config: config);
    }

    test(
        'non-stream: prompt → answer_with_memory_v1 → recall+persist on real '
        'on-disk memory, answer from live oMLX, inspected via MCP', () async {
      final omlx = _omlx();
      final ollama = _ollama();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt = 'In one short sentence, what is the capital of '
          'France?';

      final live = await standUpLive(omlx: omlx, ollama: ollama);
      String answer;
      try {
        final result = await _postJson(
          live.process.port,
          '/v1/chat/completions',
          _chatBody(prompt, stream: false),
          token: _bearerToken,
        );
        expect(result.statusCode, 200);
        final body = result.body as Map<String, Object?>;
        expect(body['object'], 'chat.completion');
        final choices = body['choices'] as List<Object?>;
        final message = (choices.single as Map<String, Object?>)['message']
            as Map<String, Object?>;
        answer = message['content'] as String;
        // A real answer streamed from live oMLX, buffered into the body.
        expect(answer.trim(), isNotEmpty,
            reason: 'live oMLX must return a non-empty completion');
      } finally {
        // Stop first: dispose the memory isolate + close the DB handles so the
        // on-disk store can be re-opened in-host for MCP inspection.
        await live.process.stop();
      }

      // Re-open the same on-disk root in-host and inspect through the MCP
      // server — the brain's real external memory-inspection surface.
      await _inspectOnDisk(live.config.memory, (mcp) async {
        await _assertExchangePersisted(mcp, prompt: prompt, answer: answer);
      });
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'stream: SSE chunk ordering + [DONE] from live oMLX, and the streamed '
        'exchange is persisted to real on-disk memory', () async {
      final omlx = _omlx();
      final ollama = _ollama();
      final omlxSkip = await omlx.unreachableReason();
      if (omlxSkip != null) return markTestSkipped(omlxSkip);
      final ollamaSkip = await ollama.unreachableReason();
      if (ollamaSkip != null) return markTestSkipped(ollamaSkip);

      const String prompt = 'In one short sentence, name a primary colour.';

      final live = await standUpLive(omlx: omlx, ollama: ollama);
      String streamedAnswer;
      try {
        final _StreamResult result = await _postForStream(
          live.process.port,
          '/v1/chat/completions',
          _chatBody(prompt, stream: true),
          token: _bearerToken,
        );
        expect(result.statusCode, 200);
        // The OpenAI streaming media type — proof the edge took the SSE branch.
        expect(result.contentType, isNotNull);
        expect(result.contentType!.startsWith('text/event-stream'), isTrue);

        final List<String> frames = _frames(result.body);
        expect(frames.length, greaterThanOrEqualTo(2),
            reason: 'at least one content frame plus the terminal [DONE]');

        // Every non-terminal frame is a well-formed chat.completion.chunk that
        // repeats one stable id; their deltas concatenate to the answer.
        final StringBuffer content = StringBuffer();
        final Set<String> ids = <String>{};
        for (final String frame in frames) {
          final Map<String, Object?>? payload = _framePayload(frame);
          if (payload == null) continue;
          expect(payload['object'], 'chat.completion.chunk');
          ids.add(payload['id'] as String);
          final choice = (payload['choices'] as List<Object?>).first
              as Map<String, Object?>;
          final delta = choice['delta'] as Map<String, Object?>;
          if (delta['content'] is String) {
            content.write(delta['content'] as String);
          }
        }
        expect(ids, hasLength(1), reason: 'one completion, many chunks');
        streamedAnswer = content.toString();
        expect(streamedAnswer.trim(), isNotEmpty,
            reason: 'live oMLX must stream non-empty completion text');

        // The wire is terminated by exactly one final data: [DONE] line.
        expect(frames.last, 'data: [DONE]');
        expect(frames.where((String f) => f == 'data: [DONE]'), hasLength(1));
      } finally {
        await live.process.stop();
      }

      // The streamed exchange persisted to real memory just like the buffered
      // path: the same procedure runs regardless of the delivery mode.
      await _inspectOnDisk(live.config.memory, (mcp) async {
        await _assertExchangePersisted(
          mcp,
          prompt: prompt,
          answer: streamedAnswer,
        );
      });
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: skipNoBinary);
}

/// Asserts the run's exchange landed in real memory: a recalled `Event` whose
/// `summary` is [prompt], a recalled `Conclusion` whose `statement` is [answer],
/// and a cold-path `interests` stack entry resolving to an `InterestItem` whose
/// `topic` is [prompt] — all read through the MCP server.
Future<void> _assertExchangePersisted(
  _McpInspector mcp, {
  required String prompt,
  required String answer,
}) async {
  // The Event is indexed by its `summary` (the prompt); recall by the prompt.
  final byPrompt = await mcp.recall(text: prompt, k: 50);
  final events = byPrompt
      .where((n) => n['typeName'] == 'Event')
      .where((n) => (n['values'] as Map)['summary'] == prompt)
      .toList(growable: false);
  expect(events, isNotEmpty,
      reason: 'the run persisted an Event whose summary is the prompt');

  // The Conclusion is indexed by its `statement` (the answer); recall by the
  // answer text so BM25 ranks it regardless of the live wording.
  final byAnswer = await mcp.recall(text: answer, k: 50);
  final conclusions = byAnswer
      .where((n) => n['typeName'] == 'Conclusion')
      .where((n) => (n['values'] as Map)['statement'] == answer)
      .toList(growable: false);
  expect(conclusions, isNotEmpty,
      reason: 'the run persisted a Conclusion whose statement is the answer');

  // The cold-classification path pushed an InterestItem onto `interests`.
  final stacks = await mcp.stackList();
  final interests =
      stacks.where((s) => s['name'] == 'interests').toList(growable: false);
  expect(interests, hasLength(1),
      reason: 'the cold path pushed the `interests` stack');
  expect((interests.single['size'] as int), greaterThanOrEqualTo(1));

  final entries = await mcp.stackPeek(name: 'interests', k: 16);
  expect(entries, isNotEmpty);
  final interestIds =
      entries.map((e) => e['nodeId'] as String).toList(growable: false);
  final fetched = await mcp.get(ids: interestIds);
  final topics = fetched
      .where((n) => n['typeName'] == 'InterestItem')
      .map((n) => (n['values'] as Map)['topic'])
      .toList(growable: false);
  expect(topics, contains(prompt),
      reason: 'an InterestItem carries the prompt as its topic');
}

/// Opens a fresh in-host `SqliteTomBrainMemory` over [config] (the same on-disk
/// root the stopped run wrote to), stands a `TomBrainMemoryMcpServer` up over it,
/// runs the MCP handshake, hands an [_McpInspector] to [body], then tears the
/// connection and the store down.
Future<void> _inspectOnDisk(
  MemoryConfig config,
  Future<void> Function(_McpInspector mcp) body,
) async {
  final SqliteTomBrainMemory memory = SqliteTomBrainMemory();
  await memory.open(config);
  try {
    await _inspectViaMcp(memory, body);
  } finally {
    await memory.close();
  }
}

/// Stands the memory MCP server up over [memory] (anonymous mode), runs the
/// handshake, hands an [_McpInspector] to [body], then tears the connection
/// down. Mirrors the smoke's E.55 in-process MCP harness: eager construction so
/// the server is listening before the client starts `initialize`.
Future<void> _inspectViaMcp(
  TomBrainMemory memory,
  Future<void> Function(_McpInspector mcp) body,
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
    await body(_McpInspector(connection));
  } finally {
    await client.shutdown();
    await server.shutdown();
  }
}

/// A thin read-only view over an MCP [mcp_client.ServerConnection] that calls
/// the memory MCP tools and decodes their JSON payloads.
class _McpInspector {
  final mcp_client.ServerConnection _connection;

  _McpInspector(this._connection);

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
          mcp_client.Implementation(name: 'r32-run-client', version: '0.0.1'),
        );
}
