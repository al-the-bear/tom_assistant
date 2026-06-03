// B.8 — Streamable HTTP transport for the outbound MCP client.
//
// What this transport implements:
//
//   - The POST-with-JSON-response subset of the MCP "Streamable HTTP"
//     binding (modelcontextprotocol.io spec 2025-06-18, section
//     "Streamable HTTP transport"). Each outbound JSON-RPC message
//     is POSTed to the configured endpoint URL with
//     `Content-Type: application/json`. The server responds with
//     either:
//       * 200 + `Content-Type: application/json` — body is a single
//         JSON-RPC response, which we feed into the inbound stream.
//       * 200 + empty body — accepted notification with no response;
//         nothing fed to the inbound stream.
//       * 4xx / 5xx — translated into a typed [McpClientException]
//         subtype as documented below.
//   - Optional `Authorization: Bearer <token>` header, applied
//     verbatim from the supplied [McpBearerCredential]. Auth is
//     transport-scoped per policy override 2 on
//     `prototype_implementation_plan.md` — stdio / channel transports
//     never authenticate.
//
// What this transport deliberately does NOT implement:
//
//   - Server-Sent Events (SSE) responses, either from a POST (when
//     the server returns `text/event-stream`) or from a GET-based
//     server-initiated stream. The v1 memory tool surface
//     (`memory_specification.md` § 3.2) is request / response with
//     no server-initiated notifications, so SSE is not on the
//     critical path. Adding it later does not require a contract
//     change here — it slots into the same channel surface.
//   - Resumability tokens (`Last-Event-ID` headers). Same reason.
//   - Retries. Substrate Spec § 12 enumerates the substrate failure
//     taxonomy at the LLM-call layer; for the MCP client at B.8 we
//     surface failures and let `McpClient` (B.8) decide. Retry /
//     cooldown policy lands in a later phase.
//
// Error mapping:
//
//   - 401, 403                 -> [McpAuthFailed]
//   - Network / DNS / TLS      -> [McpTransportUnreachable]
//   - 4xx (non-auth) and 5xx   -> [McpTransportUnreachable] with the
//                                 [statusCode] field set so callers
//                                 can branch (rate-limit handling
//                                 lands at the router layer later).
//   - Malformed JSON-RPC body  -> closes the inbound stream with a
//                                 [McpTransportUnreachable] error.
//
// The transport uses `package:http` for the actual POST. `package:http`
// is already on every `tom_core_kernel` consumer's transitive surface
// via `dart_mcp` (a json_rpc_2 / web_socket_channel transitive); this
// keeps the substrate footprint minimal while we wait for B.11 to
// adopt `tom_core_kernel.HttpClient` for the LLM provider calls. A
// future cleanup pass will migrate this transport onto
// `tom_core_kernel.HttpClient` so retry + circuit breaker semantics
// are shared with provider calls. Documented in
// `prototype_implementation_questions.md` under Q-B.8.2.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'mcp_errors.dart';
import 'mcp_transport.dart';

/// Streamable HTTP MCP transport (POST + JSON response subset).
final class HttpMcpTransport with CloseGuard implements McpTransport {
  @override
  final String id;

  /// The endpoint URL outbound messages are POSTed to.
  final Uri url;

  /// Bearer credential applied via `Authorization: Bearer <token>`.
  /// `null` disables the header — the endpoint is then expected to
  /// allow anonymous access.
  final McpBearerCredential? auth;

  /// Per-request wall-clock deadline. A request that exceeds this
  /// timeout is closed and surfaced as [McpTransportUnreachable].
  final Duration requestTimeout;

  /// Underlying HTTP client. Injected for tests (so a tiny in-isolate
  /// `MockClient` can stand in for the network); defaults to a
  /// fresh `http.Client()` in production.
  final http.Client _httpClient;

  /// Whether [close] should also close the injected [_httpClient].
  /// True when this transport owns the client (default constructor),
  /// false when an external client is injected.
  final bool _ownsHttpClient;

  final _doneCompleter = Completer<void>();
  StreamChannelController<String>? _controller;
  bool _connected = false;

  HttpMcpTransport({
    required this.id,
    required this.url,
    this.auth,
    this.requestTimeout = const Duration(seconds: 30),
    http.Client? httpClient,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  @override
  Future<StreamChannel<String>> connect() async {
    if (_connected) {
      throw StateError(
        'HttpMcpTransport($id) has already been connected. '
        'Transports are single-use; construct a new one to re-connect.',
      );
    }
    _connected = true;

    final controller = StreamChannelController<String>(
      sync: false,
      allowForeignErrors: true,
    );
    _controller = controller;

    // Wire outbound: each string from the local sink becomes a POST.
    controller.local.stream.listen(
      (line) => unawaited(_postLine(line, controller)),
      onDone: () {
        // Local side closed (consumer is done). Tear down the
        // foreign side so dart_mcp's stream completes.
        unawaited(controller.foreign.sink.close());
        if (!_doneCompleter.isCompleted) _doneCompleter.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!_doneCompleter.isCompleted) {
          _doneCompleter.completeError(error, stack);
        }
      },
      cancelOnError: false,
    );

    return controller.foreign;
  }

  Future<void> _postLine(
    String line,
    StreamChannelController<String> controller,
  ) async {
    if (isClosed) return;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (auth != null) {
      headers['Authorization'] = 'Bearer ${auth!.token}';
    }

    http.Response response;
    try {
      response = await _httpClient
          .post(url, headers: headers, body: line)
          .timeout(requestTimeout);
    } on TimeoutException catch (error) {
      _failTransport(
        controller,
        McpTransportUnreachable(
          id,
          'HTTP POST to $url exceeded ${requestTimeout.inMilliseconds}ms: '
          '$error',
        ),
      );
      return;
    } on Object catch (error) {
      _failTransport(
        controller,
        McpTransportUnreachable(
          id,
          'HTTP POST to $url failed before response: $error',
        ),
      );
      return;
    }

    final status = response.statusCode;
    if (status == 401 || status == 403) {
      _failTransport(
        controller,
        McpAuthFailed(
          id,
          'HTTP $status from $url: bearer-token rejected by endpoint.',
          status,
        ),
      );
      return;
    }
    if (status < 200 || status >= 300) {
      _failTransport(
        controller,
        McpTransportUnreachable(
          id,
          'HTTP $status from $url: '
          '${response.reasonPhrase ?? "no reason phrase"}.',
          statusCode: status,
        ),
      );
      return;
    }

    final body = response.body;
    if (body.isEmpty) {
      // Accepted notification — nothing inbound. Done.
      return;
    }

    // Body may contain a single JSON-RPC message or a newline-
    // delimited batch. We split on '\n' and forward each non-empty
    // line. dart_mcp's framing expects one JSON-RPC message per line.
    for (final responseLine in const LineSplitter().convert(body)) {
      if (responseLine.isEmpty) continue;
      controller.foreign.sink.add(responseLine);
    }
  }

  void _failTransport(
    StreamChannelController<String> controller,
    McpClientException error,
  ) {
    if (isClosed) return;
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(error);
    }
    // Close the foreign side so dart_mcp's pending `initialize`
    // resolves (with a StateError it will then have to be racing
    // against `done`).
    unawaited(controller.foreign.sink.close());
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  Future<void> close() async {
    if (!markClosed()) return;
    final controller = _controller;
    if (controller != null) {
      try {
        await controller.local.sink.close();
      } catch (_) {/* already closed */}
      try {
        await controller.foreign.sink.close();
      } catch (_) {/* already closed */}
    }
    if (_ownsHttpClient) {
      _httpClient.close();
    }
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }
}
