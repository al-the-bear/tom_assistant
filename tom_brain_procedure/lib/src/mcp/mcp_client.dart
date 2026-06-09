// McpClient + the connection abstractions (Extension F step 8;
// `tom_brain_procedure_specification.md` § 21.3, § 21.10).
//
// The MCP client lets a procedure call *out* to MCP servers via the
// `mcp.servers` / `mcp.list` / `mcp.call` primitives. It owns three things:
//
//   1. The configured server registry ([McpServersConfig]) — what
//      `mcp.servers()` advertises.
//   2. A per-server-id connection pool — one [McpServerConnection] per id,
//      opened lazily on first use and reused across calls, closed all at
//      once on [close] (process shutdown).
//   3. A per-call wall-clock cap on the outbound tool call.
//
// The wire-level connection is abstracted behind [McpServerConnection] and
// [McpConnector] so this layer holds no `dart_mcp` types and no `dart:io`
// handle (PE-1): the concrete `dart_mcp` adapter (`dart_mcp_connection.dart`)
// implements them, and a test substitutes a stub. An unreachable server or a
// failed call surfaces as [McpFailure] — an *environmental* failure, never a
// fallback trigger (PE-6).

library;

import 'dart:async';

import 'mcp_event.dart';
import 'mcp_server_config.dart';

/// Wire code for a server the client could not reach (connect failed).
const String mcpUnreachableCode = 'mcp.unreachable';

/// Wire code for a tool call that reached the server but failed.
const String mcpCallFailedCode = 'mcp.call.failed';

/// An MCP-client failure — connect-time ([mcpUnreachableCode]) or call-time
/// ([mcpCallFailedCode]).
///
/// Both are *environmental* (PE-6): the bridge turns a call failure into
/// `{ok: false}` and lets a list failure propagate, but neither triggers a
/// fallback. Step 16 wires the matching `McpFailed` observability event
/// (§ 21.10): the client emits one on its [McpEventSink] wherever it raises or
/// rethrows an [McpFailure], so the typed event and this behavioural carrier
/// surface together.
final class McpFailure implements Exception {
  /// Builds a failure with a wire [code], the [serverId] it concerns, a
  /// human-readable [message], and the optional underlying [cause].
  const McpFailure(
    this.code, {
    required this.serverId,
    required this.message,
    this.cause,
  });

  /// The wire code — [mcpUnreachableCode] or [mcpCallFailedCode].
  final String code;

  /// The id of the server the failure concerns.
  final String serverId;

  /// Human-readable explanation, reused by [toString].
  final String message;

  /// The underlying error, when this wraps one.
  final Object? cause;

  @override
  String toString() {
    final because = cause == null ? '' : ' ($cause)';
    return '$code [$serverId]: $message$because';
  }
}

/// One open connection to an MCP server — the wire surface the client uses,
/// stripped of every `dart_mcp` type.
///
/// Implemented by the concrete `dart_mcp` adapter and by test stubs. The
/// client never sees a `ServerConnection`, only this contract.
abstract interface class McpServerConnection {
  /// The server's advertised tools, each as `{name, description,
  /// input_schema}`. Throws [McpFailure] (`mcp.call.failed`) on a wire error.
  Future<List<Map<String, Object?>>> listTools();

  /// Calls tool [name] with [args], returning the result payload. Throws
  /// [McpFailure] (`mcp.call.failed`) when the server reports an error or the
  /// wire call fails.
  Future<Map<String, Object?>> callTool(String name, Map<String, Object?> args);

  /// Closes the connection. Idempotent.
  Future<void> close();
}

/// Opens an [McpServerConnection] to a configured server.
///
/// The seam that keeps OS I/O out of the client: the concrete connector
/// ([DartMcpConnector]) opens a real channel; a test connector returns a
/// stub. A connect failure throws [McpFailure] (`mcp.unreachable`).
abstract interface class McpConnector {
  /// Connects to [config], or throws [McpFailure] (`mcp.unreachable`) if the
  /// server cannot be reached.
  Future<McpServerConnection> connect(McpServerConfig config);
}

/// The MCP client — configured registry + per-id connection pool.
///
/// Built once per process over the configured servers and a [McpConnector].
/// [servers] advertises the registry; [listTools] / [callTool] open (and
/// pool) a connection on demand; [close] tears the pool down at shutdown.
final class McpClient {
  /// Builds a client over [servers] (a list or an [McpServersConfig]) and a
  /// [connector], with an optional per-call wall-clock [callTimeout]
  /// (default 30s).
  ///
  /// [onEvent], when supplied, receives a typed [McpEvent] on every connect,
  /// call, and failure (step 16); the composition root wires it to an
  /// `McpEventBus`. [clock] stamps each event's `occurredAt` (UTC) and is
  /// injectable for deterministic tests; it defaults to
  /// `DateTime.now().toUtc()`.
  McpClient(
    Object servers,
    this._connector, {
    Duration callTimeout = const Duration(seconds: 30),
    McpEventSink? onEvent,
    DateTime Function()? clock,
  })  : _config = servers is McpServersConfig
            ? servers
            : McpServersConfig(servers as List<McpServerConfig>),
        _callTimeout = callTimeout,
        _onEvent = onEvent,
        _clock = clock ?? _utcNow;

  final McpServersConfig _config;
  final McpConnector _connector;
  final Duration _callTimeout;
  final McpEventSink? _onEvent;
  final DateTime Function() _clock;

  /// The wall-clock UTC default for [_clock].
  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Forwards [event] to the injected sink when observability is wired.
  void _emit(McpEvent event) {
    final sink = _onEvent;
    if (sink != null) sink(event);
  }

  /// Builds (but does not emit) the `McpFailed` event for [failure].
  McpFailed _failedEvent(McpFailure failure) => McpFailed(
        occurredAt: _clock(),
        serverId: failure.serverId,
        code: failure.code,
        message: failure.message,
      );

  /// The live connection pool, keyed by server id. The value is the *future*
  /// of the connection so concurrent callers share one connect; a failed
  /// connect is removed so the next call retries.
  final Map<String, Future<McpServerConnection>> _pool =
      <String, Future<McpServerConnection>>{};

  /// The `{id, transport, description}` advertisements `mcp.servers()`
  /// returns.
  List<Map<String, Object?>> servers() => <Map<String, Object?>>[
        for (final server in _config.servers) server.toAdvertisement(),
      ];

  /// Whether a server with [id] is configured.
  bool isConfigured(String id) => _config.byId(id) != null;

  /// Lists the advertised tools of server [id].
  ///
  /// Throws [McpFailure] (`mcp.unreachable`) when [id] is not configured or
  /// the server cannot be reached, propagating the cause.
  Future<List<Map<String, Object?>>> listTools(String id) async {
    final connection = await _connectionFor(id);
    return connection.listTools();
  }

  /// Calls tool [tool] on server [id] with [args], bounded by the per-call
  /// wall-clock cap.
  ///
  /// Throws [McpFailure] when [id] is not configured (`mcp.unreachable`), the
  /// server cannot be reached (`mcp.unreachable`), the call exceeds the cap,
  /// or the server reports an error (`mcp.call.failed`).
  Future<Map<String, Object?>> callTool(
    String id,
    String tool,
    Map<String, Object?> args,
  ) async {
    final connection = await _connectionFor(id);
    try {
      final result = await connection.callTool(tool, args).timeout(_callTimeout);
      _emit(McpToolCalled(occurredAt: _clock(), serverId: id, tool: tool));
      return result;
    } on McpFailure catch (failure) {
      _emit(_failedEvent(failure));
      rethrow;
    } catch (error) {
      final failure = McpFailure(
        mcpCallFailedCode,
        serverId: id,
        message: 'tool call "$tool" failed',
        cause: error,
      );
      _emit(_failedEvent(failure));
      throw failure;
    }
  }

  /// Closes every pooled connection. Idempotent — safe to call at shutdown
  /// even if no connection was ever opened.
  Future<void> close() async {
    final pending = _pool.values.toList();
    _pool.clear();
    for (final future in pending) {
      try {
        final connection = await future;
        await connection.close();
      } on McpFailure {
        // A connection that never came up has nothing to close; the failed
        // connect was already surfaced to the caller that triggered it.
      }
    }
  }

  /// Returns the pooled connection for [id], opening one if needed. A failed
  /// connect is evicted so a later call can retry.
  Future<McpServerConnection> _connectionFor(String id) {
    final existing = _pool[id];
    if (existing != null) return existing;

    final config = _config.byId(id);
    if (config == null) {
      final failure = McpFailure(
        mcpUnreachableCode,
        serverId: id,
        message: 'no MCP server configured with id "$id"',
      );
      _emit(_failedEvent(failure));
      return Future<McpServerConnection>.error(failure);
    }

    final future = _connect(config);
    _pool[id] = future;
    // Evict a failed connect so the pool never caches a dead future. This is a
    // fire-and-forget side-effect listener: it *swallows* its copy of the
    // error (eviction only). The error still reaches the real caller, which
    // awaits the same `future` (a Future has independent listeners). Rethrowing
    // here would instead leave a second, unawaited errored future — an
    // unhandled async error.
    unawaited(future.then(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (identical(_pool[id], future)) _pool.remove(id);
      },
    ));
    return future;
  }

  /// Connects to [config], wrapping any non-[McpFailure] error as an
  /// `mcp.unreachable` failure.
  Future<McpServerConnection> _connect(McpServerConfig config) async {
    try {
      final connection = await _connector.connect(config);
      _emit(McpConnected(occurredAt: _clock(), serverId: config.id));
      return connection;
    } on McpFailure catch (failure) {
      _emit(_failedEvent(failure));
      rethrow;
    } catch (error) {
      final failure = McpFailure(
        mcpUnreachableCode,
        serverId: config.id,
        message: 'could not connect to MCP server "${config.id}"',
        cause: error,
      );
      _emit(_failedEvent(failure));
      throw failure;
    }
  }
}
