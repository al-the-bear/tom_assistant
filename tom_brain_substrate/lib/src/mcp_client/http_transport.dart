// B.8 — Streamable HTTP transport for the outbound MCP client.
//
// What this transport implements:
//
//   - The POST request subset of the MCP "Streamable HTTP" binding
//     (modelcontextprotocol.io spec 2025-06-18, section "Streamable
//     HTTP transport"). Each outbound JSON-RPC message is POSTed to the
//     configured endpoint URL with `Content-Type: application/json` and
//     an `Accept: application/json, text/event-stream` header (both are
//     mandatory — the SDK server 406s a POST that omits either). The
//     server picks its response shape:
//       * 200 + `Content-Type: application/json` — body is a single
//         JSON-RPC response (or newline-delimited batch), fed into the
//         inbound stream.
//       * 200 + `Content-Type: text/event-stream` — an SSE stream whose
//         `data:` payloads each carry one JSON-RPC message; we extract
//         and feed those. This is the SDK's *default* response mode
//         (`enableJsonResponse` false), used by the VS Code Extension
//         MCP server.
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
//   - GET-based server-initiated SSE streams (the server opening its own
//     notification channel). Only the SSE response to a *client POST* is
//     parsed (above). The tool surfaces tom_brain calls are request /
//     response with no server-initiated notifications, so the standalone
//     GET stream is not on the critical path; it slots into the same
//     channel surface later without a contract change here.
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
// The transport uses `package:http` for the actual POST, sourcing its
// `package:http.Client` from `tom_core_kernel.TomHttpClientFactory`
// (Q-B.8.2 / Q-B.43.3) when no client is injected — the same
// workspace-shared factory the LLM wire clients and the web adapter
// (`TomKernelWebHttpClient`) use, so the substrate keeps no parallel HTTP
// stack (spec § 11). Retry / circuit-breaker semantics are not yet shared
// here: the v1 memory MCP surface is request/response and the MCP client
// surfaces failures for the caller to handle; a first-class kernel
// `RetryPolicy` / `CircuitBreaker` surface is tracked under Q-B.31.1.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;

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
  /// `MockClient` can stand in for the network); when not injected it is
  /// acquired from `tom_core_kernel.TomHttpClientFactory` (Q-B.43.3) in
  /// production.
  final http.Client _httpClient;

  /// Whether [close] should also close the [_httpClient]. True when this
  /// transport sourced the client (no [httpClient] injected → acquired
  /// from the factory), false when an external client is injected.
  final bool _ownsHttpClient;

  final _doneCompleter = Completer<void>();
  StreamChannelController<String>? _controller;
  bool _connected = false;

  /// The MCP session id the server assigned on the `initialize` response
  /// (`Mcp-Session-Id` header), echoed back on every follow-up POST. The
  /// spec's `StreamableHTTPServerTransport` — and the memory server's
  /// `McpHttpServer` — create a session on `initialize` and then `400`/`404`
  /// any later request that omits this header, so capturing and replaying it
  /// is mandatory for anything beyond the handshake. `null` until the first
  /// session-bearing response; an anonymous, session-less server simply never
  /// sends the header and the field stays `null` (no header is added).
  String? _sessionId;

  /// The MCP "Streamable HTTP" session-id header, both as it arrives on the
  /// `initialize` response and as it is replayed on subsequent requests
  /// (matched case-insensitively by `package:http`, which lower-cases response
  /// header names).
  static const String _sessionIdHeader = 'Mcp-Session-Id';

  /// [httpClient] — an explicit `package:http.Client`; takes precedence
  /// over [factory] and is left open for the caller on [close].
  ///
  /// [factory] — the `tom_core_kernel.TomHttpClientFactory` to acquire a
  /// client from when [httpClient] is null. Defaults to a fresh
  /// `TomHttpClientFactory()` (the workspace-shared path). The acquired
  /// client is owned and closed by [close].
  HttpMcpTransport({
    required this.id,
    required this.url,
    this.auth,
    this.requestTimeout = const Duration(seconds: 30),
    http.Client? httpClient,
    kernel.TomHttpClientFactory? factory,
  })  : _httpClient = httpClient ??
            (factory ?? kernel.TomHttpClientFactory()).getClient(),
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

    // Wire outbound: each string the consumer writes to the returned
    // `foreign.sink` is emitted on `local.stream`, where this listener turns it
    // into a POST. Inbound responses go the other way — written to `local.sink`
    // (below), which the `StreamChannelController` emits on the consumer's
    // `foreign.stream`. (Writing a response to `foreign.sink` would emit it on
    // `local.stream` — i.e. feed it straight back into this outbound listener,
    // an infinite POST-the-response feedback loop.)
    controller.local.stream.listen(
      (line) => unawaited(_postLine(line, controller)),
      onDone: () {
        // Consumer closed its sink (it is done). Close our `local.sink` so the
        // consumer's `foreign.stream` completes, then settle `done`.
        unawaited(controller.local.sink.close());
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
      // The MCP "Streamable HTTP" binding requires a POST to advertise that it
      // accepts BOTH a single JSON response and an SSE stream — the server
      // chooses which to return. The `@modelcontextprotocol/sdk`
      // `StreamableHTTPServerTransport` rejects a POST whose `Accept` omits
      // either with `406 Not Acceptable` (before any JSON-RPC logic runs),
      // regardless of its `enableJsonResponse` setting. Advertising both is
      // harmless against a JSON-only server (it picks `application/json`) and
      // mandatory against a spec-compliant one.
      'Accept': 'application/json, text/event-stream',
    };
    if (auth != null) {
      headers['Authorization'] = 'Bearer ${auth!.token}';
    }
    // Replay the server-assigned session id on every request after the
    // handshake. Without it a session-based server (`McpHttpServer`, the SDK
    // transport) rejects the very next message — e.g. `notifications/
    // initialized` — with `400`/`404`, which drops the channel before any tool
    // call can run.
    final sessionId = _sessionId;
    if (sessionId != null) {
      headers[_sessionIdHeader] = sessionId;
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

    // Capture the session id the server minted on the `initialize` response so
    // every later POST can replay it (above). `package:http` lower-cases
    // response header names, so the lookup uses the lower-cased key. Only the
    // first non-empty value is adopted — subsequent responses do not carry it.
    final assignedSessionId = response.headers[_sessionIdHeader.toLowerCase()];
    if (_sessionId == null &&
        assignedSessionId != null &&
        assignedSessionId.isNotEmpty) {
      _sessionId = assignedSessionId;
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

    // The server picks its response shape (see the `Accept` header above):
    //   * `text/event-stream` — an SSE stream whose `data:` payloads each carry
    //     one JSON-RPC message. The SDK's default mode (`enableJsonResponse`
    //     false), used by the VS Code Extension MCP server, returns this.
    //   * anything else (`application/json`) — a single JSON-RPC message or a
    //     newline-delimited batch.
    // Either way we feed bare JSON-RPC lines to `local.sink` → emitted on the
    // consumer's `foreign.stream` (never `foreign.sink`, which would loop back
    // to `local.stream` and re-POST the response).
    final contentType =
        (response.headers['content-type'] ?? '').toLowerCase();
    final lines = contentType.contains('text/event-stream')
        ? _extractSseMessages(body)
        : const LineSplitter().convert(body);
    for (final responseLine in lines) {
      if (responseLine.isEmpty) continue;
      controller.local.sink.add(responseLine);
    }
  }

  /// Extracts the JSON-RPC payloads from an SSE response body.
  ///
  /// Per the SSE wire format each event is a block of `field: value` lines
  /// terminated by a blank line; a message's payload is the concatenation
  /// (newline-joined) of its `data:` field values. Non-`data` fields
  /// (`event:` / `id:` / `retry:`) and comment lines (`:`) are ignored, so a
  /// `event: message\ndata: {…}\n\n` block yields exactly the JSON object.
  static List<String> _extractSseMessages(String body) {
    final messages = <String>[];
    final dataLines = <String>[];
    void flush() {
      if (dataLines.isEmpty) return;
      messages.add(dataLines.join('\n'));
      dataLines.clear();
    }

    for (final raw in const LineSplitter().convert(body)) {
      if (raw.isEmpty) {
        flush(); // event boundary
        continue;
      }
      if (raw.startsWith(':')) continue; // SSE comment
      if (raw.startsWith('data:')) {
        var value = raw.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        dataLines.add(value);
      }
      // `event:` / `id:` / `retry:` carry no JSON-RPC payload — ignored.
    }
    flush(); // trailing event with no terminating blank line
    return messages;
  }

  void _failTransport(
    StreamChannelController<String> controller,
    McpClientException error,
  ) {
    if (isClosed) return;
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.completeError(error);
    }
    // Close our `local.sink` so the consumer's `foreign.stream` completes and
    // dart_mcp's pending `initialize` resolves (racing against `done`, which
    // has just completed with the error).
    unawaited(controller.local.sink.close());
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
