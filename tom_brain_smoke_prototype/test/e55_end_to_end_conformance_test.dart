// E.55 — end-to-end conformance test (OpenAI + Telegram, inspected via MCP).
//
// Plan step E.55 (verbatim): "End-to-end conformance test: scripted scenario —
// start process → OpenAI request → answer → memory inspect (via the MCP
// server) → assert event + conclusion + interest stack contents. Repeat for
// Telegram. Both must pass in CI."
//
// Where E.47–E.49 inspected the post-run graph through the cross-isolate
// marshalling client ([SmokeProcess.memory] / `stats()`), E.55 has the stricter
// obligation the plan names: inspect memory **through the MCP server** — the
// brain's real external memory-inspection surface (`memory_specification.md`
// § 3.2). The MCP server is constructed over a `TomBrainMemory` and forwards
// each tool call to it directly; it cannot reach a store behind a SendPort in a
// worker isolate.
//
// So this suite boots the cognition over the *in-process* memory transport: the
// run and the MCP server share one [InspectableSmokeMemory] in the host
// isolate. The run writes through the dispatcher/engine; the MCP server reads it
// back through the seven v1 read tools. Both channels — OpenAI and Telegram —
// are driven end-to-end, and after each the post-run graph is asserted purely
// through MCP tool calls:
//
//   1. `memory.recall` surfaces the run's `Event` (summary == the prompt) and
//      `Conclusion` (statement == the answer).
//   2. `memory.stack.list` shows the cold-path `interests` stack carrying one
//      entry.
//   3. `memory.stack.peek` + `memory.get` resolve that entry to an
//      `InterestItem` whose `topic` is the prompt.
//
// ── Why recall returns empty during the run but populated for the inspection ──
//
// `answer_with_memory_v1` recalls *before* it persists, so the in-run recall
// over [InspectableSmokeMemory] (which returns "every persisted node") is empty
// at recall time — keeping the procedure on its cold-classification path
// (InterestItem + `interests` push). After the run the same recall returns the
// persisted Event + Conclusion, which is exactly what the MCP inspection reads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemory, TomBrainMemoryMcpServer;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:tom_chattools/tom_chattools.dart' show ChatReceiver;

import '_support/loopback_chat_api.dart';

/// The chunked answer the stub substrate streams; its concatenation is the
/// answer the channel delivers and the `Conclusion` records.
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

/// The Telegram bot token the smoke configures (any non-null value makes the
/// access process stand the Telegram edge up; the loopback ignores it).
const String _botToken = 'smoke-bot-token';

/// The whitelisted Telegram sender id.
const String _allowedSender = 'tg-allowed';

void main() {
  group('E.55 end-to-end conformance — OpenAI', () {
    late InspectableSmokeMemory memory;
    late SmokeProcess smoke;

    setUp(() async {
      memory = InspectableSmokeMemory();
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
        inProcessMemory: memory,
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test(
        'start → OpenAI request → answer → MCP inspect: '
        'event + conclusion + interest stack', () async {
      const String prompt = 'how do I automate backups?';

      // ── Start → OpenAI request → answer. ──
      final result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody(prompt),
        token: smokeBearerToken,
      );
      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;
      final choices = body['choices'] as List<Object?>;
      final message =
          (choices.single as Map<String, Object?>)['message']
              as Map<String, Object?>;
      expect(message['content'], _answerText);

      // ── Memory inspect, via the MCP server. ──
      await _inspectViaMcp(smoke.inProcessMemory!, (mcp) async {
        await _assertConformantGraph(mcp, prompt: prompt, answer: _answerText);
      });
    });
  });

  group('E.55 end-to-end conformance — Telegram', () {
    late InspectableSmokeMemory memory;
    late LoopbackChatApi loopback;
    late SmokeProcess smoke;

    setUp(() async {
      memory = InspectableSmokeMemory();
      loopback = LoopbackChatApi();
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
        telegramBotToken: _botToken,
        telegramWhitelist: const <String>{_allowedSender},
        telegramChatApiFactory: (_) => loopback,
        inProcessMemory: memory,
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test(
        'start → Telegram message → answer → MCP inspect: '
        'event + conclusion + interest stack', () async {
      const String prompt = 'what is the capital of curiosity?';

      // ── Start → Telegram message → answer. ──
      loopback.injectText(senderId: _allowedSender, text: prompt);
      await _waitForSent(loopback);
      expect(loopback.sentMessages.single, _answerText);
      expect(loopback.sentReceivers.single, ChatReceiver.id(_allowedSender));

      // ── Memory inspect, via the MCP server. ──
      await _inspectViaMcp(smoke.inProcessMemory!, (mcp) async {
        await _assertConformantGraph(mcp, prompt: prompt, answer: _answerText);
      });
    });
  });
}

/// Asserts the post-run graph through the MCP read tools: a recalled `Event`
/// whose `summary` is [prompt], a recalled `Conclusion` whose `statement` is
/// [answer], and a cold-path `interests` stack whose single entry resolves to an
/// `InterestItem` carrying [prompt] as its `topic`.
Future<void> _assertConformantGraph(
  _McpInspector mcp, {
  required String prompt,
  required String answer,
}) async {
  // 1. recall surfaces the Event + Conclusion the run persisted.
  final recalled = await mcp.recall(text: prompt, k: 50);
  final byType = <String, List<Map<String, Object?>>>{};
  for (final node in recalled) {
    (byType[node['typeName'] as String] ??= <Map<String, Object?>>[])
        .add(node);
  }

  final events = byType['Event'] ?? const <Map<String, Object?>>[];
  expect(events, hasLength(1), reason: 'one Event per run');
  expect((events.single['values'] as Map)['summary'], prompt);

  final conclusions = byType['Conclusion'] ?? const <Map<String, Object?>>[];
  expect(conclusions, hasLength(1), reason: 'one Conclusion per run');
  expect((conclusions.single['values'] as Map)['statement'], answer);

  // 2. the cold-path interests stack carries exactly one entry.
  final stacks = await mcp.stackList();
  final interests =
      stacks.where((s) => s['name'] == 'interests').toList(growable: false);
  expect(interests, hasLength(1), reason: 'the cold path pushed `interests`');
  expect(interests.single['size'], 1);

  // 3. that entry resolves to an InterestItem whose topic is the prompt.
  final entries = await mcp.stackPeek(name: 'interests', k: 8);
  expect(entries, hasLength(1));
  final interestNodeId = entries.single['nodeId'] as String;

  final fetched = await mcp.get(ids: <String>[interestNodeId]);
  expect(fetched, hasLength(1));
  expect(fetched.single['typeName'], 'InterestItem');
  expect((fetched.single['values'] as Map)['topic'], prompt);
}

/// Stands the memory MCP server up over [memory] (anonymous mode), runs the MCP
/// handshake, hands an [_McpInspector] to [body], then tears the connection
/// down. Mirrors the in-process MCP harness from `a77_mcp_tools_test.dart`:
/// eager construction (NOT `late` init) so the server is listening before the
/// client starts `initialize`.
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

  final client = _SmokeMcpClient();
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
/// the memory MCP tools and decodes their JSON payloads — the surface the E.55
/// conformance assertions speak through.
class _McpInspector {
  final mcp_client.ServerConnection _connection;

  _McpInspector(this._connection);

  /// `memory.recall` → the recalled node maps.
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
    final payload =
        await _call('memory.get', <String, Object?>{'ids': ids});
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

base class _SmokeMcpClient extends mcp_client.MCPClient {
  _SmokeMcpClient()
      : super(
          mcp_client.Implementation(name: 'e55-smoke-client', version: '0.0.1'),
        );
}

/// Issues a `POST` of [body] as JSON against the bound smoke process, carrying
/// the bearer [token], and returns the status code and decoded JSON body.
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
    final Object? decoded = text.isEmpty ? null : jsonDecode(text);
    return (statusCode: response.statusCode, body: decoded);
  } finally {
    client.close(force: true);
  }
}

/// A `chat/completions` request body for [prompt] with `stream=false`.
Map<String, Object?> _chatBody(String prompt) => <String, Object?>{
      'model': 'tom-brain',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': false,
    };

/// Polls until the loopback has recorded at least [atLeast] sent message(s), or
/// throws on [timeout]. The Telegram path is async across delivery, so the test
/// waits for delivery rather than assuming it is synchronous.
Future<void> _waitForSent(
  LoopbackChatApi loopback, {
  int atLeast = 1,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (loopback.sentMessages.length < atLeast) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        'timed out waiting for $atLeast sent Telegram message(s); '
        'got ${loopback.sentMessages.length}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
