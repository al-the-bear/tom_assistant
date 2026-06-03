// MCP server transports.
//
// Supported transports (memory_specification.md § 3.2):
//
//   - **stdio** — re-exported from `package:dart_mcp/stdio.dart` so
//     deployment code consumes a single transport surface. The dart_mcp
//     helper does newline-delimited UTF-8 framing exactly the way
//     MCP requires; there is no reason to rewrap it.
//   - **UNIX-domain socket** — adapted from a `dart:io` [io.Socket] by
//     [socketChannel]. The function mirrors `stdioChannel`'s framing
//     (UTF-8 codec + [LineSplitter] on the inbound side; '\n'-appending
//     on the outbound side). `Socket` already implements both
//     `Stream<List<int>>` and `StreamSink<List<int>>`, so the adapter
//     is a thin StreamChannel transform.
//   - **Streamable HTTP / HTTPS** ([McpHttpServer], todo #3) — the
//     network transport the cross-machine Big-Beast/bomber topology
//     (memory_specification.md § 10) needs: neither stdio nor a UNIX
//     socket crosses a host boundary. Implements the POST + single
//     JSON-RPC response subset of the MCP "Streamable HTTP" binding
//     (spec 2025-06-18), mirroring the outbound client subset in
//     `tom_brain_substrate`'s `http_transport.dart`. SSE / server-
//     initiated streams are out of scope (the v1 tool surface is pure
//     request/response).
//
// Why a transports file separate from the server class:
//
//   - The server class (`tom_brain_memory_mcp_server.dart`) is purely
//     about the MCP protocol surface: identity, capability
//     advertisement, tool registration. Transports are about how bytes
//     arrive — they belong to deployment, not protocol. Each transport
//     hands the server class a `StreamChannel<String>`; the server
//     never learns whether the bytes arrived over stdio, a socket, or
//     an HTTP POST.
//   - Future deployment shapes plug in here without touching the
//     server class.
//
// Authentication (todo #4): when [McpHttpServer] is bound with a
// [BearerTokenAuthenticator], it terminates bearer auth at the
// **HTTP-header** layer — every `POST` / `DELETE` must carry a valid
// `Authorization: Bearer <token>` or it is refused `401`. This mirrors
// the substrate MCP *client*, which sends the token as the same header
// (`tom_brain_substrate`'s `http_transport.dart`) and treats `401`/`403`
// as `McpAuthFailed`. Auth is **off unless configured**: with no
// authenticator the endpoint admits anonymous callers, the trust-the-VPN
// posture the cross-machine link uses by default.
//
// Auth is transport-scoped (policy override 2): stdio / UNIX-socket
// transports never authenticate, so this header check lives in the HTTP
// transport rather than in the protocol-level server class. For an
// HTTP deployment the per-session server is built without an
// `_meta`-level authenticator — the HTTP layer is the single auth
// boundary, so a client that sends only the header (the substrate
// client does) is not double-challenged. Per-tool authorisation by the
// authenticated principal over HTTP is future work; like the substrate
// client, the token is treated here as an opaque gate.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' show Random;

import 'package:async/async.dart' show StreamSinkTransformer;
import 'package:stream_channel/stream_channel.dart';

import 'bearer_auth.dart';

// Re-export `stdioChannel` so callers depend on a single transport
// surface (`mcp_server` barrel) rather than reaching directly into the
// `dart_mcp` sub-library. The re-export goes through the MCP-library
// adapter (todo #5) so the concrete `package:dart_mcp/stdio.dart`
// dependency stays confined to that one file. The re-export also
// documents that stdio is one of the two A.75 supported transports.
export 'mcp_library_adapter.dart' show stdioChannel;

/// Adapts a `dart:io` [io.Socket] (typically a UNIX-domain socket) to the
/// newline-delimited UTF-8 [StreamChannel] of `String` that `dart_mcp`'s
/// [MCPServer] consumes.
///
/// Mirrors the framing rules of `stdioChannel`:
///
///   - Incoming bytes are UTF-8-decoded and split on newlines.
///   - Outgoing strings are UTF-8-encoded with a trailing `\n` appended
///     by an output transformer.
///
/// The [io.Socket] is used in both directions: it implements
/// `Stream<Uint8List>` (which satisfies `Stream<List<int>>`) and
/// `IOSink` (which implements `StreamSink<List<int>>`). The caller owns
/// the socket's lifecycle — closing the returned channel will not
/// destroy the underlying socket on its own, and connecting / accepting
/// the socket is a deployment concern outside the scope of this helper.
///
/// Typical deployment pattern:
///
/// ```dart
/// final listener = await io.ServerSocket.bind(
///   io.InternetAddress(path, type: io.InternetAddressType.unix),
///   0,
/// );
/// await for (final socket in listener) {
///   final channel = socketChannel(socket);
///   TomBrainMemoryMcpServer(channel);
/// }
/// ```
StreamChannel<String> socketChannel(io.Socket socket) =>
    StreamChannel<List<int>>.withCloseGuarantee(socket, socket)
        .transform(StreamChannelTransformer.fromCodec(utf8))
        .transformStream(const LineSplitter())
        .transformSink(
          StreamSinkTransformer.fromHandlers(
            handleData: (data, sink) {
              sink.add('$data\n');
            },
          ),
        );

/// Builds (and owns) the MCP server for a freshly-created HTTP session.
///
/// [McpHttpServer] calls this once per session — when an `initialize`
/// request arrives with no session id — handing the implementation the
/// duplex [StreamChannel] of `String` the session's JSON-RPC frames flow
/// over. The callback constructs a `TomBrainMemoryMcpServer` (or any
/// `dart_mcp` server) bound to [channel]:
///
/// ```dart
/// final http = await McpHttpServer.bind(
///   port: 8642,
///   onSession: (channel) => TomBrainMemoryMcpServer(
///     channel,
///     memory: memory,
///     authenticator: authenticator,
///   ),
/// );
/// ```
///
/// The server's lifecycle is tied to [channel]: when the session ends
/// (client `DELETE`, or [McpHttpServer.close]) the channel is closed,
/// which shuts the `dart_mcp` server's run loop down. The callback does
/// not need to retain the server reference.
typedef McpHttpSessionHandler = void Function(StreamChannel<String> channel);

/// Streamable HTTP / HTTPS transport for the memory MCP **server**
/// (todo #3).
///
/// This is the network surface the multi-machine topology in
/// `memory_specification.md` § 10 requires — a cognitive worker
/// ("bomber") reads from, and submits writes back to, the canonical
/// authority ("Big Beast") over MCP, and neither stdio nor a UNIX socket
/// crosses a host boundary.
///
/// ## Wire contract (the implemented subset)
///
/// Mirrors the outbound subset in `tom_brain_substrate`'s
/// `http_transport.dart`: the **POST + single JSON-RPC response** slice
/// of the MCP "Streamable HTTP" binding (spec 2025-06-18). Server-
/// Sent-Events responses, GET-based server-initiated streams, and
/// resumability tokens are **out of scope** — the v1 memory tool
/// surface (`memory_specification.md` § 3.2) is pure request/response
/// with no server-initiated notifications.
///
///   - **`POST {path}`** — body is one JSON-RPC message (object).
///       * `initialize` request with no `Mcp-Session-Id` header → a new
///         session is created; the response carries the generated
///         `Mcp-Session-Id` header and the body is the `initialize`
///         result. `200 application/json`.
///       * any request (`id` present) on an existing session → the
///         correlated JSON-RPC response. `200 application/json`.
///       * any notification (`id` absent, e.g.
///         `notifications/initialized`) → `202 Accepted`, empty body.
///       * unknown / missing session id (non-`initialize`) → `404`.
///       * malformed body, or non-`initialize` first message → `400`.
///   - **`DELETE {path}`** with a known `Mcp-Session-Id` → terminates
///     the session, `204`.
///   - **`GET {path}`** → `405` (no SSE stream in v1).
///   - any other path → `404`.
///
/// ## Session model
///
/// Each session owns a [StreamChannelController]: inbound POST bodies are
/// written to the controller's local sink (the server reads them as its
/// inbound stream); the server's outbound frames arrive on the
/// controller's local stream, where they are demultiplexed back to the
/// awaiting POST by JSON-RPC `id`. A session lives until a `DELETE`, a
/// channel close from the server side, or [close].
///
/// Concurrent in-flight requests on one session are supported — each
/// JSON-RPC `id` maps to its own pending completer.
final class McpHttpServer {
  final io.HttpServer _httpServer;
  final McpHttpSessionHandler _onSession;

  /// The request path the transport serves. Requests to any other path
  /// receive `404`. Defaults to `/mcp`.
  final String path;

  /// Per-request wall-clock deadline for a server response. A request
  /// whose correlated response does not arrive within this window is
  /// answered `504` and its pending slot is discarded.
  final Duration requestTimeout;

  /// Whether this endpoint terminates TLS (i.e. was bound with a
  /// [io.SecurityContext]).
  final bool isSecure;

  /// Optional HTTP-header bearer authenticator (todo #4).
  ///
  /// `null` ⇒ the endpoint is **anonymous** — no `Authorization` header
  /// is required and every well-formed request is admitted. This is the
  /// off-by-default, trust-the-VPN posture.
  ///
  /// When non-null, every `POST` / `DELETE` must carry a valid
  /// `Authorization: Bearer <token>`; a missing, malformed, or rejected
  /// token is refused `401` before any session is created or addressed.
  final BearerTokenAuthenticator? _authenticator;

  final _sessions = <String, _McpHttpSession>{};
  final Random _sessionIdRng = Random.secure();
  bool _closed = false;

  McpHttpServer._(
    this._httpServer,
    this._onSession, {
    required this.path,
    required this.requestTimeout,
    required this.isSecure,
    required BearerTokenAuthenticator? authenticator,
  }) : _authenticator = authenticator {
    _httpServer.listen(
      _dispatch,
      onError: (Object _) {/* per-connection errors are non-fatal */},
    );
  }

  /// Binds an MCP server over HTTP (or HTTPS when [securityContext] is
  /// supplied) and starts accepting requests.
  ///
  /// [address] is a host string or an [io.InternetAddress]; it defaults
  /// to the IPv4 loopback. [port] defaults to `0`, letting the OS pick a
  /// free port (read it back from [port]).
  ///
  /// [onSession] constructs the `dart_mcp` server for each new session;
  /// see [McpHttpSessionHandler].
  ///
  /// When [securityContext] is non-null the listener is bound with
  /// `bindSecure`, producing an HTTPS endpoint ([isSecure] is then
  /// `true`).
  ///
  /// [authenticator] enables HTTP-header bearer auth (todo #4). When
  /// omitted (or `null`) the endpoint is anonymous — the off-by-default
  /// posture. When supplied, every `POST` / `DELETE` must carry a valid
  /// `Authorization: Bearer <token>` or it is refused `401`. See
  /// `bearer_auth.dart` for the two shipped implementations
  /// ([JwtBearerTokenAuthenticator], [StaticBearerTokenAuthenticator]).
  static Future<McpHttpServer> bind({
    required McpHttpSessionHandler onSession,
    Object? address,
    int port = 0,
    io.SecurityContext? securityContext,
    String path = '/mcp',
    Duration requestTimeout = const Duration(seconds: 30),
    BearerTokenAuthenticator? authenticator,
  }) async {
    final bindAddress = address ?? io.InternetAddress.loopbackIPv4;
    final httpServer = securityContext == null
        ? await io.HttpServer.bind(bindAddress, port)
        : await io.HttpServer.bindSecure(bindAddress, port, securityContext);
    return McpHttpServer._(
      httpServer,
      onSession,
      path: path,
      requestTimeout: requestTimeout,
      isSecure: securityContext != null,
      authenticator: authenticator,
    );
  }

  /// The port the listener is bound to.
  int get port => _httpServer.port;

  /// The address the listener is bound to.
  io.InternetAddress get address => _httpServer.address;

  /// The number of live sessions. Exposed for observability / tests.
  int get sessionCount => _sessions.length;

  /// Whether this endpoint requires HTTP-header bearer auth. `false`
  /// when bound without an authenticator (anonymous, off-by-default).
  bool get requiresAuth => _authenticator != null;

  /// The base URL clients POST to (`scheme://host:port{path}`).
  Uri get url => Uri(
        scheme: isSecure ? 'https' : 'http',
        host: address.host,
        port: port,
        path: path,
      );

  Future<void> _dispatch(io.HttpRequest request) async {
    try {
      if (request.uri.path != path) {
        await _respondError(request.response, io.HttpStatus.notFound,
            'No MCP endpoint at ${request.uri.path}.');
        return;
      }
      switch (request.method) {
        case 'POST':
          if (!await _authorize(request)) return;
          await _handlePost(request);
        case 'DELETE':
          if (!await _authorize(request)) return;
          await _handleDelete(request);
        case 'GET':
          // SSE / server-initiated streams are not part of the v1
          // subset; advertise the methods we do serve.
          request.response.headers.set(io.HttpHeaders.allowHeader,
              'POST, DELETE');
          await _respondError(request.response, io.HttpStatus.methodNotAllowed,
              'This MCP endpoint does not support GET (no SSE in v1).');
        default:
          request.response.headers.set(io.HttpHeaders.allowHeader,
              'POST, DELETE');
          await _respondError(request.response, io.HttpStatus.methodNotAllowed,
              '${request.method} is not supported.');
      }
    } catch (error) {
      // Last-resort guard: a handler bug must not take the listener
      // down. Surface a 500 and keep serving.
      try {
        await _respondError(request.response,
            io.HttpStatus.internalServerError, 'Internal transport error.');
      } catch (_) {/* response already (partly) sent */}
    }
  }

  Future<void> _handlePost(io.HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.trim().isEmpty) {
      await _respondError(
          request.response, io.HttpStatus.badRequest, 'Empty request body.');
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, Object?>) {
      await _respondError(request.response, io.HttpStatus.badRequest,
          'Request body must be a single JSON-RPC object.');
      return;
    }

    final method = decoded['method'];
    final id = decoded['id'];
    final sessionId =
        request.headers.value(_sessionIdHeader)?.trim();

    final _McpHttpSession session;
    final bool isNewSession;
    if (sessionId == null || sessionId.isEmpty) {
      if (method != 'initialize') {
        await _respondError(request.response, io.HttpStatus.badRequest,
            'Missing $_sessionIdHeader; only an initialize request may '
            'open a new session.');
        return;
      }
      session = _createSession();
      isNewSession = true;
    } else {
      final existing = _sessions[sessionId];
      if (existing == null) {
        await _respondError(request.response, io.HttpStatus.notFound,
            'Unknown or expired session id.');
        return;
      }
      session = existing;
      isNewSession = false;
    }

    final line = jsonEncode(decoded);

    // A message without an `id` is a notification (or a response): the
    // server produces nothing to return. Hand it off and acknowledge.
    if (id == null) {
      session.deliverInbound(line);
      request.response.statusCode = io.HttpStatus.accepted;
      await request.response.close();
      return;
    }

    final String responseLine;
    try {
      responseLine = await session.request(id, line, requestTimeout);
    } on TimeoutException {
      if (isNewSession) _dropSession(session.id);
      await _respondError(request.response, io.HttpStatus.gatewayTimeout,
          'Timed out waiting for the MCP server to respond.');
      return;
    }

    final response = request.response;
    response.statusCode = io.HttpStatus.ok;
    response.headers.contentType = io.ContentType.json;
    if (isNewSession) {
      response.headers.set(_sessionIdHeader, session.id);
    }
    response.write(responseLine);
    await response.close();
  }

  Future<void> _handleDelete(io.HttpRequest request) async {
    final sessionId = request.headers.value(_sessionIdHeader)?.trim();
    if (sessionId == null || !_sessions.containsKey(sessionId)) {
      await _respondError(request.response, io.HttpStatus.notFound,
          'Unknown session id.');
      return;
    }
    await _dropSession(sessionId);
    request.response.statusCode = io.HttpStatus.noContent;
    await request.response.close();
  }

  _McpHttpSession _createSession() {
    final id = _newSessionId();
    final session = _McpHttpSession(id, _onSession);
    _sessions[id] = session;
    // If the server closes its side of the channel, forget the session
    // so its id can no longer be addressed.
    session.onChannelClosed = () => _sessions.remove(id);
    return session;
  }

  Future<void> _dropSession(String id) async {
    final session = _sessions.remove(id);
    if (session != null) await session.close();
  }

  String _newSessionId() {
    final bytes =
        List<int>.generate(16, (_) => _sessionIdRng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// HTTP-header bearer gate (todo #4). Runs before [_handlePost] /
  /// [_handleDelete].
  ///
  /// Returns `true` when the request may proceed:
  ///   - the endpoint is anonymous (no authenticator configured), or
  ///   - the `Authorization: Bearer <token>` header carries a token the
  ///     authenticator accepts.
  ///
  /// Returns `false` after writing a `401` response when an authenticator
  /// is configured and the header is missing, malformed, or rejected.
  /// The token is consumed only as a gate — the authenticated principal
  /// is not propagated, matching the substrate client which treats the
  /// token as opaque (per-tool authorisation over HTTP is future work).
  Future<bool> _authorize(io.HttpRequest request) async {
    final authenticator = _authenticator;
    if (authenticator == null) return true;

    final token = _bearerToken(
        request.headers.value(io.HttpHeaders.authorizationHeader));
    if (token == null) {
      await _respondUnauthorized(
          request.response, 'Missing or malformed Bearer credentials.');
      return false;
    }
    try {
      authenticator.authenticate(token);
      return true;
    } on BearerAuthFailure catch (failure) {
      // Generic wire message (reason tag only); the detailed
      // `failure.message` stays server-side so the response cannot be
      // used to fingerprint individual tokens (mirrors the server class's
      // `initialize`-time redaction).
      await _respondUnauthorized(request.response,
          'Bearer authentication failed: ${failure.reason.name}');
      return false;
    }
  }

  /// Extracts the token from an `Authorization` header value, or `null`
  /// when the header is absent or not a non-empty `Bearer` credential.
  /// The scheme match is case-insensitive per RFC 7235.
  static String? _bearerToken(String? header) {
    if (header == null) return null;
    const prefix = 'bearer ';
    if (header.length <= prefix.length) return null;
    if (header.substring(0, prefix.length).toLowerCase() != prefix) {
      return null;
    }
    final token = header.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  Future<void> _respondUnauthorized(
    io.HttpResponse response,
    String message,
  ) async {
    response.statusCode = io.HttpStatus.unauthorized;
    response.headers.set(io.HttpHeaders.wwwAuthenticateHeader, 'Bearer');
    response.headers.contentType = io.ContentType.json;
    response.write(jsonEncode({'error': message}));
    await response.close();
  }

  Future<void> _respondError(
    io.HttpResponse response,
    int statusCode,
    String message,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = io.ContentType.json;
    response.write(jsonEncode({'error': message}));
    await response.close();
  }

  /// Tears down every live session and stops the listener.
  ///
  /// Idempotent: a second call is a no-op. When [force] is true (the
  /// default) in-flight requests are aborted; pass `false` to let active
  /// connections drain first.
  Future<void> close({bool force = true}) async {
    if (_closed) return;
    _closed = true;
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      await session.close();
    }
    await _httpServer.close(force: force);
  }

  /// The HTTP header that carries the session id, both as the response
  /// header on an `initialize` reply and as the request header on every
  /// follow-up POST / DELETE. Matches the MCP "Streamable HTTP" binding.
  static const String _sessionIdHeader = 'Mcp-Session-Id';
}

/// One HTTP session: a [StreamChannelController] bridging POSTed
/// JSON-RPC frames to a single `dart_mcp` server instance, plus the
/// id→completer table that routes server responses back to the awaiting
/// POST.
class _McpHttpSession {
  final String id;
  final StreamChannelController<String> _controller;
  final _pending = <Object, Completer<String>>{};
  late final StreamSubscription<String> _outboundSub;
  bool _closed = false;

  /// Invoked once when the server closes its side of the channel.
  void Function()? onChannelClosed;

  _McpHttpSession(this.id, McpHttpSessionHandler onSession)
      : _controller = StreamChannelController<String>(
          sync: false,
          allowForeignErrors: true,
        ) {
    // The server consumes the foreign end; the transport keeps the local
    // end. Frames written by the server to `foreign.sink` arrive on
    // `local.stream`, where `_onOutbound` routes them by JSON-RPC id.
    onSession(_controller.foreign);
    _outboundSub = _controller.local.stream.listen(
      _onOutbound,
      onDone: _onChannelDone,
    );
  }

  /// Writes a notification / response line to the server (no reply
  /// expected).
  void deliverInbound(String line) {
    if (_closed) return;
    _controller.local.sink.add(line);
  }

  /// Writes a request line to the server and resolves with the server's
  /// correlated response line (matched by JSON-RPC [id]).
  Future<String> request(Object id, String line, Duration timeout) {
    if (_closed) {
      return Future.error(
          StateError('MCP session $id is closed; cannot submit request.'));
    }
    final completer = Completer<String>();
    // Register before writing so a synchronously-produced response is
    // never missed.
    _pending[id] = completer;
    _controller.local.sink.add(line);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('MCP server response for id=$id timed out');
    });
  }

  void _onOutbound(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return; // Non-JSON frame: nothing we can route.
    }
    if (decoded is! Map<String, Object?>) return;
    final id = decoded['id'];
    if (id == null) return; // Server-initiated notification: dropped (no SSE).
    final completer = _pending.remove(id);
    completer?.complete(line);
  }

  void _onChannelDone() {
    onChannelClosed?.call();
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _outboundSub.cancel();
    // Fail any still-pending request so its POST does not hang to the
    // request deadline.
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
            StateError('MCP session $id closed before a response arrived.'));
      }
    }
    _pending.clear();
    try {
      await _controller.local.sink.close();
    } catch (_) {/* already closed */}
  }
}
