// BrainAccessProcess — the boot root that ties the running access process
// together (E.45; proto spec § 11 / § 12).
//
// ── What the running process is ──────────────────────────────────────
//
// The proto spec § 12 bring-up sequence is *substrate → memory → engine +
// dispatcher → access layer*. The first four phases produce a booted
// cognition; this file is phase 5 — the access layer wired to **live
// channels**. It takes an already-booted cognition (a [ProvisionedBrain],
// handed in through the [BrainProvisioner] seam so the access package never
// imports substrate / memory), composes the admission core over its
// `Dispatcher` (`BrainAccessBoot.install`, E.41), and stands up the live
// edges that drive that core:
//
//   * the OpenAI HTTP/SSE edge (E.45) — auth-gated `/v1/` routes;
//   * the `GET /healthz` endpoint (E.43) — mounted on the same port,
//     *outside* the `/v1/` base path, reporting on the whole process;
//   * the Ollama edge (plan-2 #30) — when an Ollama port is configured, an
//     auth-gated `/api/chat` + `/api/generate` socket on its own port;
//   * the Anthropic Messages edge (plan-2 #31) — when an Anthropic port is
//     configured, an auth-gated `/v1/messages` socket on its own port;
//   * the Telegram edge (E.45) — when a bot token is configured, a
//     long-polling adapter feeding the same admission core.
//
// The Ollama and Anthropic edges each own their whole port (their own 404
// envelope), so they bind directly through the serve seam — only the OpenAI
// edge shares its socket with `/healthz` via a `Cascade`. All three HTTP
// channels drive the *one* admission core, so a request authenticates against
// the same shared bearer-token bindings regardless of dialect.
//
// The OpenAI routes and the health route share one socket via a shelf
// `Cascade`: the health router answers `/healthz` and 404s everything else,
// cascading to the OpenAI edge (which owns the OpenAI 404 envelope for any
// unmatched route). A graceful-shutdown coordinator (E.42) ties `SIGINT` /
// `SIGTERM` to the ordered teardown.
//
// ── The seams ────────────────────────────────────────────────────────
//
// Two collaborators are injected as function seams so the whole process is
// testable without a socket or the Telegram network:
//
//   * [AccessServeSeam] — binds the composed handler to a port and returns an
//     [AccessServer] (port + close). The default ([serveWithShelfIo]) wraps
//     `shelf_io.serve`; a test passes an in-memory fake and drives the handler
//     directly.
//   * [TelegramChatApiFactory] — builds the `tom_chattools` `ChatApi` from the
//     bot token. The default ([defaultTelegramChatApiFactory]) builds the real
//     long-polling Telegram backend; a test injects a loopback double.
//
// The cognition itself arrives through the [BrainProvisioner] seam (the CLI
// default refuses — only a higher assembly can boot substrate + memory), so
// this file holds only a `Dispatcher`, a `QueueSnapshotSource`, and a
// teardown — never a substrate or memory type.

import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tom_chattools/tom_chattools.dart'
    show ChatApi, ChatSettings, TelegramChatConfig;

import '../adapters/openai_http_sse/openai_http_sse_adapter.dart'
    show EmbeddingSource;
import '../adapters/telegram/telegram_adapter.dart';
import '../adapters/telegram/telegram_whitelist.dart';
import '../config/access_config.dart';
import '../edge_security/edge_security.dart'
    show
        BearerTokenAuthenticator,
        EdgeStateStore,
        JsonFileEdgeStateStore,
        MapEdgeStateStore;
import '../identity/telegram_session_registry.dart'
    show TelegramSessionRegistry;
import '../heuristic_classifier/heuristic_kind_hint_classifier.dart'
    show KindHintClassifier, KindHintEmbedder;
import 'anthropic_access_edge.dart';
import 'brain_access_boot.dart';
import 'brain_provisioner.dart';
import 'graceful_shutdown.dart';
import 'health_check.dart';
import 'incoming_trail_record.dart' show IncomingTrailSink;
import 'ollama_access_edge.dart';
import 'openai_access_edge.dart';
import 'telegram_access_edge.dart';

/// Binds the composed access handler to a port and returns the live server
/// (E.45).
///
/// The seam between the boot root (which composes the handler) and the actual
/// socket. The default ([serveWithShelfIo]) wraps `shelf_io.serve`; a test
/// passes a fake that records the handler and reports a synthetic port, so the
/// whole process can be exercised with no real socket.
typedef AccessServeSeam = Future<AccessServer> Function(
  Handler handler,
  int port,
);

/// A bound, listening access server — the boot root's view of the live socket
/// (E.45).
///
/// Carries only what the running process needs: the [port] it actually bound
/// (the requested port, or the OS-assigned one when `0` was requested) and a
/// [close] for the ordered teardown.
abstract interface class AccessServer {
  /// The port the server is listening on.
  int get port;

  /// Stops listening and releases the socket.
  Future<void> close();
}

/// Builds the `tom_chattools` [ChatApi] the Telegram channel drives, from the
/// configured bot token (E.45).
///
/// The default ([defaultTelegramChatApiFactory]) builds the real long-polling
/// Telegram backend; a test injects a loopback double so the Telegram edge can
/// be driven without the network.
typedef TelegramChatApiFactory = ChatApi Function(String botToken);

/// How long a graceful [AccessServer.close] waits for in-flight requests to
/// finish draining before it forces the socket shut (E.45 / G.3.2).
///
/// A streaming SSE answer that is mid-flight when shutdown begins is allowed to
/// run to its natural end within this window; only a request that is still open
/// past the deadline is severed. Sized to outlast a normal answer but bound the
/// teardown so a hung connection cannot block the process forever.
const Duration defaultShutdownDrainTimeout = Duration(seconds: 10);

/// Upper bound on the *whole* ordered teardown (E.45 / G.3.6).
///
/// The graceful-shutdown future ([BrainAccessProcess.completed]) only resolves
/// once the teardown has run, and the serve executor blocks on it. If a
/// teardown step hangs (a stuck cognition shutdown, a wedged channel), an
/// unbounded teardown would never resolve `completed` and the process would
/// hang on exit. Bounding the teardown here guarantees `completed` resolves —
/// cleanly when the drain finishes in time, or with an error after this
/// deadline forces the issue. Strictly larger than [defaultShutdownDrainTimeout]
/// so the socket drain has its full window inside the overall bound.
const Duration defaultShutdownDeadline = Duration(seconds: 30);

/// The default [AccessServeSeam]: bind the handler with `shelf_io.serve` on all
/// IPv4 interfaces (E.45).
Future<AccessServer> serveWithShelfIo(Handler handler, int port) async {
  final HttpServer server =
      await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  return _HttpAccessServer(server);
}

/// The default [TelegramChatApiFactory]: the package's real long-polling
/// Telegram `ChatApi` (mirrors `TelegramAdapter`'s production builder — the
/// direct `TelegramChatConfig.createApi` path with explicit polling).
ChatApi defaultTelegramChatApiFactory(String botToken) {
  final TelegramChatConfig config = TelegramChatConfig(token: botToken);
  return config.createApi(ChatSettings.telegram(botToken, usePolling: true));
}

/// The running access process (E.45).
///
/// Returned by [startBrainAccessProcess]. It is the live handle: [port] is the
/// bound socket; [completed] resolves with the process exit code once a
/// termination signal has driven the graceful teardown; [stop] tears the
/// process down programmatically (a test, or an embedding context that owns its
/// own lifecycle) without a signal.
final class BrainAccessProcess {
  /// The port the OpenAI + health socket is listening on.
  final int port;

  /// The port the Ollama socket is listening on, or `null` when no Ollama
  /// channel was configured.
  final int? ollamaPort;

  /// The port the Anthropic Messages socket is listening on, or `null` when no
  /// Anthropic channel was configured.
  final int? anthropicPort;

  final GracefulShutdown _gracefulShutdown;
  final Future<void> Function() _teardown;

  BrainAccessProcess._({
    required this.port,
    required this.ollamaPort,
    required this.anthropicPort,
    required GracefulShutdown gracefulShutdown,
    required Future<void> Function() teardown,
  })  : _gracefulShutdown = gracefulShutdown,
        _teardown = teardown;

  /// Resolves with the process exit code once a termination signal has driven
  /// the graceful teardown (E.42). Never resolves if the process is instead
  /// stopped programmatically through [stop].
  Future<int> get completed => _gracefulShutdown.completed;

  /// Whether a termination signal has begun the graceful shutdown.
  bool get isShutdownTriggered => _gracefulShutdown.isTriggered;

  /// Tears the process down programmatically: stop listening for signals, then
  /// run the ordered teardown (stop the channels, dispose the access layer,
  /// shut the cognition down). Idempotent with the signal path — the teardown
  /// runs at most once.
  Future<void> stop() async {
    await _gracefulShutdown.dispose();
    await _teardown();
  }
}

/// Boots and starts the running access process over an already-provisioned
/// cognition (E.45).
///
/// Maps [config] onto the access-layer composition inputs, composes the
/// admission core over [brain]'s `Dispatcher` (E.41), stands up the OpenAI +
/// health socket through [serve], optionally stands up the Telegram edge (when
/// [AccessConfig.hasTelegram]) through [telegramChatApiFactory], and installs a
/// graceful-shutdown coordinator over the ordered teardown.
///
/// The optional runtime seams ([bearerAuthenticator], [kindHintEmbedder],
/// [kindHintClassifier], [embeddingSource], [clock]) are *not* configuration:
/// they are the substrate / memory edges (and the test clock) a higher
/// assembly injects. The CLI default leaves them `null` (no bearer
/// pre-validation, no cheap classifier — the dispatcher classifies every
/// request — and the auth-gated `/v1/embeddings` route answers `501`, since the
/// embedding service lives in substrate). [shutdownSignals] and [terminate]
/// default to the real `SIGINT` / `SIGTERM` + `exit`; a test injects
/// controllers and a recorder.
///
/// [incomingTrailSink] is the optional §5.3 incoming-prompt trail sink
/// (`tom_brain_logging.md` §10 step #7) the admission core hands one
/// `IncomingTrailRecord` per admitted request, before dispatch. `null` (the
/// default) leaves the `incoming/` surface unwritten; a higher assembly
/// (`tom_brain_run`) binds an `IncomingTrailWriter.write` here in full-trail
/// mode.
Future<BrainAccessProcess> startBrainAccessProcess({
  required AccessConfig config,
  required ProvisionedBrain brain,
  AccessServeSeam serve = serveWithShelfIo,
  TelegramChatApiFactory telegramChatApiFactory = defaultTelegramChatApiFactory,
  BearerTokenAuthenticator? bearerAuthenticator,
  KindHintEmbedder? kindHintEmbedder,
  KindHintClassifier? kindHintClassifier,
  EmbeddingSource? embeddingSource,
  List<Stream<ProcessSignal>>? shutdownSignals,
  ProcessTerminator? terminate,
  Duration shutdownDeadline = defaultShutdownDeadline,
  DateTime Function()? clock,
  IncomingTrailSink? incomingTrailSink,
}) async {
  // The proto spec § 12 phase 5 sequence, one extracted step each:
  final BootedAccessLayer booted = _composeAccessLayer(
    brain: brain,
    config: config,
    bearerAuthenticator: bearerAuthenticator,
    kindHintEmbedder: kindHintEmbedder,
    kindHintClassifier: kindHintClassifier,
    clock: clock,
    incomingTrailSink: incomingTrailSink,
  );
  final AccessServer server = await _serveOpenAiAndHealth(
    booted: booted,
    brain: brain,
    config: config,
    serve: serve,
    embeddingSource: embeddingSource,
    clock: clock,
  );
  final AccessServer? ollamaServer = await _serveOllama(
    booted: booted,
    config: config,
    serve: serve,
  );
  final AccessServer? anthropicServer = await _serveAnthropic(
    booted: booted,
    config: config,
    serve: serve,
  );
  final _TelegramEdge telegram = await _startTelegram(
    booted: booted,
    config: config,
    telegramChatApiFactory: telegramChatApiFactory,
  );
  final List<AccessServer> servers = <AccessServer>[
    server,
    ?ollamaServer,
    ?anthropicServer,
  ];
  final (GracefulShutdown gracefulShutdown, Future<void> Function() teardown) =
      _installShutdown(
    servers: servers,
    booted: booted,
    brain: brain,
    telegram: telegram,
    shutdownSignals: shutdownSignals,
    terminate: terminate,
    shutdownDeadline: shutdownDeadline,
  );

  return BrainAccessProcess._(
    port: server.port,
    ollamaPort: ollamaServer?.port,
    anthropicPort: anthropicServer?.port,
    gracefulShutdown: gracefulShutdown,
    teardown: teardown,
  );
}

/// Phase 5b-ii — stand up the optional Ollama socket on its own port (plan-2
/// #30). When [config] has an Ollama port, binds a fresh [OllamaAccessEdge]
/// driving the *same* admission core through the [serve] seam; otherwise
/// returns `null`. The Ollama edge owns the whole port (its own 404 envelope),
/// so — unlike the OpenAI + health pairing — there is no `Cascade` here.
Future<AccessServer?> _serveOllama({
  required BootedAccessLayer booted,
  required AccessConfig config,
  required AccessServeSeam serve,
}) async {
  if (!config.hasOllama) {
    return null;
  }
  final OllamaAccessEdge edge = OllamaAccessEdge(
    assembler: booted.assembler,
    basePath: config.ollamaBasePath,
  );
  return serve(edge.handler, config.ollamaPort!);
}

/// Phase 5b-iii — stand up the optional Anthropic Messages socket on its own
/// port (plan-2 #31). When [config] has an Anthropic port, binds a fresh
/// [AnthropicAccessEdge] driving the *same* admission core through the [serve]
/// seam; otherwise returns `null`. The Anthropic edge owns the whole port (its
/// own `not_found_error` 404), so there is no `Cascade` here.
Future<AccessServer?> _serveAnthropic({
  required BootedAccessLayer booted,
  required AccessConfig config,
  required AccessServeSeam serve,
}) async {
  if (!config.hasAnthropic) {
    return null;
  }
  final AnthropicAccessEdge edge = AnthropicAccessEdge(
    assembler: booted.assembler,
    basePath: config.anthropicBasePath,
  );
  return serve(edge.handler, config.anthropicPort!);
}

/// Phase 5a — compose the admission core over the already-booted dispatcher
/// (E.41). Maps [config] + the injected runtime seams onto the
/// [BrainAccessConfig] and installs the access layer over `brain.dispatcher`.
BootedAccessLayer _composeAccessLayer({
  required ProvisionedBrain brain,
  required AccessConfig config,
  required BearerTokenAuthenticator? bearerAuthenticator,
  required KindHintEmbedder? kindHintEmbedder,
  required KindHintClassifier? kindHintClassifier,
  required DateTime Function()? clock,
  required IncomingTrailSink? incomingTrailSink,
}) =>
    BrainAccessBoot.install(
      dispatcher: brain.dispatcher,
      config: _toBrainAccessConfig(
        config,
        bearerAuthenticator: bearerAuthenticator,
        kindHintEmbedder: kindHintEmbedder,
        kindHintClassifier: kindHintClassifier,
        clock: clock,
        incomingTrailSink: incomingTrailSink,
      ),
    );

/// Phase 5b — stand up the live OpenAI + health socket on one port (E.43 /
/// E.45). A shelf `Cascade` lets the health router answer `/healthz` and 404
/// the rest, cascading to the OpenAI edge (which owns the OpenAI 404 envelope
/// for any other unmatched route); the bound server is returned through the
/// [serve] seam.
Future<AccessServer> _serveOpenAiAndHealth({
  required BootedAccessLayer booted,
  required ProvisionedBrain brain,
  required AccessConfig config,
  required AccessServeSeam serve,
  required EmbeddingSource? embeddingSource,
  required DateTime Function()? clock,
}) async {
  final OpenAiAccessEdge openAiEdge = OpenAiAccessEdge(
    assembler: booted.assembler,
    basePath: config.openAiBasePath,
    models: config.personaVocabulary,
    embeddingSource: embeddingSource,
  );
  final HealthCheck healthCheck = HealthCheck(
    queueSnapshot: brain.queueSnapshot,
    clock: clock,
  );
  final Handler handler = Cascade()
      .add(healthCheck.handler)
      .add(openAiEdge.handler)
      .handler;
  return serve(handler, config.openAiPort);
}

/// Phase 5c — stand up the optional Telegram edge (E.45). When [config] has a
/// bot token, builds the `ChatApi` through [telegramChatApiFactory], starts
/// the long-polling adapter, and wires the edge that feeds the admission core;
/// otherwise returns [_TelegramEdge.none].
Future<_TelegramEdge> _startTelegram({
  required BootedAccessLayer booted,
  required AccessConfig config,
  required TelegramChatApiFactory telegramChatApiFactory,
}) async {
  if (!config.hasTelegram) {
    return _TelegramEdge.none;
  }
  final ChatApi chatApi = telegramChatApiFactory(config.telegramBotToken!);
  final TelegramAdapter adapter = TelegramAdapter(
    chatApi: chatApi,
    whitelist: TelegramWhitelist(config.telegramWhitelist),
  );
  await adapter.start();
  // Per-user session continuity (§ 6.5): persisted alongside the edge limiter
  // state when a state directory is configured, in memory otherwise. The
  // registry adopts every minted id into the SessionManager so the dispatcher
  // resolves it as a known dedicated session.
  final EdgeStateStore sessionStore = config.edgeStateDirectory == null
      ? MapEdgeStateStore()
      : JsonFileEdgeStateStore(
          _edgeStatePath(config.edgeStateDirectory!, _telegramSessionsFile),
        );
  final TelegramSessionRegistry sessionRegistry = TelegramSessionRegistry(
    store: sessionStore,
    adoptSession: booted.assembler.sessionManager.ensureSession,
  );
  final TelegramAccessEdge edge = TelegramAccessEdge(
    assembler: booted.assembler,
    chatApi: chatApi,
    authorizedInbound: adapter.authorizedInboundRequests,
    sessionRegistry: sessionRegistry,
  );
  edge.start();
  // Ping each whitelisted owner that the link is live, naming the host this
  // brain is running on (best-effort — a send failure never blocks bring-up).
  await edge.announceStartup(
    recipientUserIds: config.telegramWhitelist,
    host: Platform.localHostname,
  );
  return _TelegramEdge(adapter, edge);
}

/// Phase 5d — build the ordered, idempotent teardown and install the
/// graceful-shutdown coordinator over it (E.42 / G.3.6).
///
/// The teardown stops new work arriving first (the channels), then disposes
/// the access layer, then the cognition; it runs at most once (the signal path
/// and [BrainAccessProcess.stop] share it). The whole teardown is bounded by
/// [shutdownDeadline]: a hung step otherwise leaves [BrainAccessProcess.completed]
/// unresolved and the serve executor blocked on exit. On the deadline a
/// `TimeoutException` propagates; the coordinator catches it and terminates
/// with the error exit code, so the process exits either way. Returns the
/// coordinator and the bounded teardown (the process handle needs both).
(GracefulShutdown, Future<void> Function()) _installShutdown({
  required List<AccessServer> servers,
  required BootedAccessLayer booted,
  required ProvisionedBrain brain,
  required _TelegramEdge telegram,
  required List<Stream<ProcessSignal>>? shutdownSignals,
  required ProcessTerminator? terminate,
  required Duration shutdownDeadline,
}) {
  bool tornDown = false;
  Future<void> teardown() async {
    if (tornDown) return;
    tornDown = true;
    await telegram.stop();
    for (final AccessServer server in servers) {
      await server.close();
    }
    await booted.shutdown();
    await brain.shutdown();
  }

  Future<void> boundedTeardown() => teardown().timeout(shutdownDeadline);

  final GracefulShutdown gracefulShutdown = terminate == null
      ? GracefulShutdown.install(
          onShutdown: boundedTeardown,
          signals: shutdownSignals,
        )
      : GracefulShutdown.install(
          onShutdown: boundedTeardown,
          signals: shutdownSignals,
          terminate: terminate,
        );

  return (gracefulShutdown, boundedTeardown);
}

/// The optional Telegram edge the process stands up (E.45 phase 5c): the
/// long-polling [adapter] and the [edge] that feeds the admission core. Both
/// are `null` when no bot token is configured ([none]). Bundled so phase 5c
/// can return the pair and the teardown can stop them in order through one
/// [stop].
final class _TelegramEdge {
  final TelegramAdapter? adapter;
  final TelegramAccessEdge? edge;

  const _TelegramEdge(this.adapter, this.edge);

  /// The no-Telegram case: both halves absent, [stop] a no-op.
  static const _TelegramEdge none = _TelegramEdge(null, null);

  /// Stops the edge then the adapter (stop feeding the core before stopping
  /// the poll); each half is a no-op when absent.
  Future<void> stop() async {
    await edge?.stop();
    await adapter?.stop();
  }
}

/// Maps the on-disk [AccessConfig] onto the [BrainAccessConfig] composition
/// inputs, injecting the runtime seams that are not configuration.
///
/// When [AccessConfig.edgeStateDirectory] is set, builds one
/// [JsonFileEdgeStateStore] per edge limiter under that directory so the
/// rate-limit buckets (E.29) and the daily-quota counters (E.30) survive a
/// process restart (P1.4). When it is `null` both stores are `null` and the
/// limiters keep their state in process only.
BrainAccessConfig _toBrainAccessConfig(
  AccessConfig config, {
  required BearerTokenAuthenticator? bearerAuthenticator,
  required KindHintEmbedder? kindHintEmbedder,
  required KindHintClassifier? kindHintClassifier,
  required DateTime Function()? clock,
  required IncomingTrailSink? incomingTrailSink,
}) {
  final EdgeStateStore? rateLimitStore;
  final EdgeStateStore? quotaStore;
  final dir = config.edgeStateDirectory;
  if (dir == null) {
    rateLimitStore = null;
    quotaStore = null;
  } else {
    rateLimitStore = JsonFileEdgeStateStore(_edgeStatePath(dir, _rateLimitStateFile));
    quotaStore = JsonFileEdgeStateStore(_edgeStatePath(dir, _quotaStateFile));
  }

  return BrainAccessConfig(
    rateLimitPolicy: config.rateLimitPolicy,
    dailyQuotaPolicy: config.dailyQuotaPolicy,
    anchorPolicy: config.anchorPolicy,
    bearerTokenBindings: config.bearerTokenBindings,
    telegramUserIdBindings: config.telegramUserIdBindings,
    personaVocabulary: config.personaVocabulary,
    bearerAuthenticator: bearerAuthenticator,
    kindHintEmbedder: kindHintEmbedder,
    kindHintClassifier: kindHintClassifier,
    embeddingCacheTtl: config.embeddingCacheTtl,
    clock: clock,
    rateLimitStore: rateLimitStore,
    quotaStore: quotaStore,
    incomingTrailSink: incomingTrailSink,
  );
}

/// The per-limiter state file names under [AccessConfig.edgeStateDirectory].
const String _rateLimitStateFile = 'rate_limit_state.json';
const String _quotaStateFile = 'quota_state.json';

/// The Telegram per-user session registry file under
/// [AccessConfig.edgeStateDirectory] (§ 6.5).
const String _telegramSessionsFile = 'telegram_sessions.json';

/// Joins an edge-state [directory] and [fileName], tolerating a trailing
/// separator on the directory. Forward slashes work across the prototype's
/// supported hosts (Linux / macOS) and `dart:io` accepts them everywhere.
String _edgeStatePath(String directory, String fileName) {
  final trimmed = directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  return '$trimmed/$fileName';
}

/// The default [AccessServer]: an adapter over a bound `dart:io` [HttpServer].
class _HttpAccessServer implements AccessServer {
  final HttpServer _server;
  final Duration _drainTimeout;

  _HttpAccessServer(
    this._server, {
    Duration drainTimeout = defaultShutdownDrainTimeout,
  }) : _drainTimeout = drainTimeout;

  @override
  int get port => _server.port;

  /// Graceful close (G.3.2): first stop accepting new connections and let
  /// in-flight requests (including streaming SSE answers) drain, bounded by
  /// [_drainTimeout]. Only if a request is still open past the deadline does
  /// it fall back to `force: true` — so a normal answer completes, but a hung
  /// connection cannot hold the teardown open indefinitely.
  @override
  Future<void> close() async {
    try {
      await _server.close().timeout(_drainTimeout);
    } on TimeoutException {
      await _server.close(force: true);
    }
  }
}
