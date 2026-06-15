// startObservatoryServer — the package-level assembly of the Observatory's
// read-only backend, factored out of `bin/observatory.dart` so both entrypoints
// share one body (`prompt_tracing.md` § 8.5, § 7.1):
//
//   * `bin/observatory.dart` — the standalone, hand-launched process. It parses
//     args, calls [startObservatoryServer], then installs the process-wide
//     SIGINT/SIGTERM handlers and `exit(0)`s on a signal.
//   * `bin/observatory_isolate.dart` — the in-process variant the brain spawns
//     via `Isolate.spawnUri`. It must NOT touch `ProcessSignal` or `exit` (those
//     are process-wide and belong to the parent brain isolate), so it calls the
//     same [startObservatoryServer] and tears down on a control message instead.
//
// Keeping the assembly here — not in either `bin/` — is what lets the
// signal-free isolate reuse it without copying the connect/load/serve logic.
//
// This file deliberately takes [onInfo] / [onWarning] sinks rather than writing
// to stdout/stderr: the standalone bin forwards them to the console, while the
// isolate forwards them back to the brain over its handshake port. The assembly
// itself never decides where its narration goes.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tom_brain_run/tom_brain_run.dart'
    show CognitionConfig, CognitionConfigException, CognitionConfigLoader;

import '../api/trail_read_api.dart';
import '../memory/http_mcp_read_connection.dart';
import '../memory/memory_read_client.dart';
import '../parse/trail_host.dart';
import 'runtime_snapshot.dart';

/// A narration sink for the assembly — one informational or warning line. The
/// caller routes it (console for the standalone bin, the handshake port for the
/// in-process isolate); the assembly never writes streams itself.
typedef ObservatoryLog = void Function(String message);

/// The parsed knobs the Observatory backend binds — the typed form of
/// `bin/observatory.dart`'s positional `<trail-host-root>` plus its `--key=value`
/// flags. Built directly (the brain's in-process launcher) or via [fromArgs]
/// (the two bins).
final class ObservatoryOptions {
  /// The default loopback port (mirrors the historical `_defaultPort`).
  static const int defaultPort = 8787;

  /// The default loopback bind address (loopback-only by design).
  static const String defaultHost = '127.0.0.1';

  /// The trail tree to read, e.g. `_ai/tom_brain_trail/<host>`.
  final String trailRoot;

  /// The `flutter build web` output served at `/`. `null` selects
  /// [defaultWebRoot].
  final String? webDir;

  /// The procedure scripts directory served read-only at `/api/procedures/<id>`.
  /// `null` selects [defaultScriptRoot].
  final String? scriptsDir;

  /// The cognition config root (registry + per-procedure config + templates +
  /// roles). `null` leaves `/api/catalogue` and the template routes at 503.
  final String? cognitionDir;

  /// The run-config root the substrate config file resolves against. `null`
  /// defaults to [cognitionDir] inside the assembly.
  final String? runConfigDir;

  /// The running memory MCP server's Streamable-HTTP endpoint. `null` leaves
  /// `/api/memory/*` at 503.
  final String? memoryMcpUrl;

  /// Optional bearer forwarded to the memory MCP endpoint.
  final String? memoryMcpToken;

  /// The bind address (loopback-only by design).
  final String host;

  /// The bind port.
  final int port;

  /// The live in-process values the running brain bound (gateway ports, the
  /// Telegram toggle, the resolved roots), threaded by `brain_serve` for the
  /// Runtime tab's "currently running" display (§ 6.4, § 8.3(13)). `null` when
  /// the observatory is launched standalone (no live brain to ask) — the
  /// `GET /api/runtime` route then `503`s "runtime unavailable".
  final RuntimeSnapshot? runtime;

  /// Binds the options. Only [trailRoot] is required; the rest carry the same
  /// defaults `bin/observatory.dart` applied.
  const ObservatoryOptions({
    required this.trailRoot,
    this.webDir,
    this.scriptsDir,
    this.cognitionDir,
    this.runConfigDir,
    this.memoryMcpUrl,
    this.memoryMcpToken,
    this.host = defaultHost,
    this.port = defaultPort,
    this.runtime,
  });

  /// Parses the CLI form: exactly one positional `<trail-host-root>` plus the
  /// `--key=value` flags. Throws [ArgumentError] when the positional count is
  /// not exactly one, so both bins report usage identically.
  factory ObservatoryOptions.fromArgs(List<String> args) {
    final positional = args.where((a) => !a.startsWith('-')).toList();
    if (positional.length != 1) {
      throw ArgumentError(
        'expected exactly one positional <trail-host-root>, '
        'got ${positional.length}',
      );
    }
    final flags = <String, String>{
      for (final a in args)
        if (a.startsWith('--') && a.contains('='))
          a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
    };
    return ObservatoryOptions(
      trailRoot: positional.single,
      webDir: flags['web'],
      scriptsDir: flags['scripts'],
      cognitionDir: flags['cognition'],
      runConfigDir: flags['run-config'],
      memoryMcpUrl: flags['memory-mcp-url'],
      memoryMcpToken: flags['memory-mcp-token'],
      host: flags['host'] ?? defaultHost,
      port: int.tryParse(flags['port'] ?? '') ?? defaultPort,
    );
  }

  /// The sibling web app's build output, relative to the running entrypoint's
  /// package root (both bins live in `bin/`, so the `../..` walk is identical).
  static String defaultWebRoot() => p.normalize(p.join(
        p.dirname(Platform.script.toFilePath()),
        '..',
        '..',
        'tom_brain_observatory_web',
        'build',
        'web',
      ));

  /// The sibling procedure package's `scripts/system` directory, relative to the
  /// running entrypoint's package root (§ 4.6).
  static String defaultScriptRoot() => p.normalize(p.join(
        p.dirname(Platform.script.toFilePath()),
        '..',
        '..',
        'tom_brain_procedure',
        'scripts',
        'system',
      ));
}

/// A bound, serving Observatory backend — the live socket plus its read-only
/// teardown. The teardown is socket-only (`server.close`): unlike the standalone
/// bin, it never `exit`s, so an in-process caller can stop the Observatory
/// without killing the brain.
final class ObservatoryServer {
  final HttpServer _server;

  ObservatoryServer._(this._server);

  /// The bound host (the resolved address the socket actually listens on).
  String get boundHost => _server.address.host;

  /// The bound port.
  int get port => _server.port;

  /// The loopback URL to open in a browser.
  Uri get url => Uri(scheme: 'http', host: boundHost, port: port);

  /// Stops the socket. Read-only: closes the listening server (force-closing
  /// in-flight requests). Does not `exit` the process.
  Future<void> close() => _server.close(force: true);
}

/// Assembles and binds the Observatory backend from [options], returning the
/// live [ObservatoryServer]. Narration (which roots were found, whether memory
/// connected) is routed through [onInfo] / [onWarning] rather than stdout/stderr,
/// so the in-process isolate can forward it to the brain. All degradations are
/// soft (a missing web build, absent cognition root, or unreachable memory MCP
/// server only narrows the served surface), matching the read-only-mirror
/// posture (OBS-1…OBS-5): the only hard failure is the socket bind itself.
Future<ObservatoryServer> startObservatoryServer(
  ObservatoryOptions options, {
  ObservatoryLog? onInfo,
  ObservatoryLog? onWarning,
}) async {
  final info = onInfo ?? (_) {};
  final warn = onWarning ?? (_) {};

  final webDir = options.webDir ?? ObservatoryOptions.defaultWebRoot();
  final scriptsDir = options.scriptsDir ?? ObservatoryOptions.defaultScriptRoot();

  final webRoot = Directory(webDir);
  if (!webRoot.existsSync()) {
    warn(
      'web build not found at $webDir — run `flutter build web` in '
      'tom_brain_observatory_web first (serving the /api surface only).',
    );
  }

  final scriptRoot = Directory(scriptsDir);
  if (!scriptRoot.existsSync()) {
    warn(
      'procedure scripts not found at $scriptsDir — GET/PUT '
      "/api/procedures/<id> will 404 until --scripts points at the brain's "
      'scripts/system directory.',
    );
  }

  final cognition = _loadCognition(options.cognitionDir, warn);
  final cognitionRoot =
      (options.cognitionDir != null && Directory(options.cognitionDir!).existsSync())
          ? Directory(options.cognitionDir!)
          : null;
  final runConfigRoot =
      (options.runConfigDir != null && Directory(options.runConfigDir!).existsSync())
          ? Directory(options.runConfigDir!)
          : null;

  final memory = await _connectMemory(
    options.memoryMcpUrl,
    bearerToken: options.memoryMcpToken,
    info: info,
    warn: warn,
  );

  final api = TrailReadApi(
    host: TrailHost.at(options.trailRoot),
    webRoot: webRoot.existsSync() ? webRoot : null,
    scriptRoot: scriptRoot.existsSync() ? scriptRoot : null,
    cognition: cognition,
    cognitionRoot: cognitionRoot,
    runConfigRoot: runConfigRoot,
    memory: memory,
    runtime: options.runtime,
  );

  final server = await shelf_io.serve(api.handler, options.host, options.port);
  return ObservatoryServer._(server);
}

/// Connects the Module-2 memory read surface (§ 8.4) when [memoryMcpUrl] points
/// at a running memory MCP server, or returns `null` (the `/api/memory/*` routes
/// then 503 "memory unavailable"). A connect / handshake failure is
/// environmental — it is narrated and the backend still boots, matching the
/// read-only-mirror posture.
Future<MemoryReadClient?> _connectMemory(
  String? memoryMcpUrl, {
  String? bearerToken,
  required ObservatoryLog info,
  required ObservatoryLog warn,
}) async {
  if (memoryMcpUrl == null || memoryMcpUrl.isEmpty) {
    warn(
      'no --memory-mcp-url — /api/memory/* will 503 "memory unavailable". Run '
      'tom_brain_memory/bin/memory_mcp_server.dart against the brain\'s run '
      'config and pass its http://127.0.0.1:<port>/mcp URL (§ 8.4).',
    );
    return null;
  }
  final Uri url;
  try {
    url = Uri.parse(memoryMcpUrl);
  } on FormatException catch (e) {
    warn(
      '--memory-mcp-url is not a valid URL ($memoryMcpUrl: ${e.message}) — '
      '/api/memory/* will 503 "memory unavailable".',
    );
    return null;
  }
  try {
    final connection =
        await HttpMcpReadConnection.connect(url, bearerToken: bearerToken);
    info('memory connector wired to $url.');
    return MemoryReadClient(connection);
  } on McpReadException catch (e) {
    warn(
      'could not reach the memory MCP server at $url (${e.message}) — '
      '/api/memory/* will 503 "memory unavailable". Is memory_mcp_server.dart '
      'running?',
    );
    return null;
  }
}

/// Loads the cognition config from [cognitionDir] for `GET /api/catalogue`, or
/// returns `null` when no root is configured or the config fails to parse (the
/// route then 503s "config unavailable"). The Observatory is a read-only mirror,
/// so a malformed cognition tree is narrated but never fatal.
CognitionConfig? _loadCognition(String? cognitionDir, ObservatoryLog warn) {
  if (cognitionDir == null) {
    warn(
      'no --cognition root — GET /api/catalogue will 503 "config unavailable" '
      "until it points at the brain's cognition root.",
    );
    return null;
  }
  if (!Directory(cognitionDir).existsSync()) {
    warn(
      'cognition root not found at $cognitionDir — GET /api/catalogue will 503 '
      '"config unavailable".',
    );
    return null;
  }
  try {
    return CognitionConfigLoader.loadFromDir(cognitionDir);
  } on CognitionConfigException catch (e) {
    warn(
      'cognition config at $cognitionDir failed to parse (${e.message}) — '
      'GET /api/catalogue will 503 "config unavailable".',
    );
    return null;
  }
}
