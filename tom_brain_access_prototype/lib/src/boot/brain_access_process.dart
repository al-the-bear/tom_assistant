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
//   * the Telegram edge (E.45) — when a bot token is configured, a
//     long-polling adapter feeding the same admission core.
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

import '../adapters/telegram/telegram_adapter.dart';
import '../adapters/telegram/telegram_whitelist.dart';
import '../config/access_config.dart';
import '../edge_security/edge_security.dart' show BearerTokenAuthenticator;
import '../heuristic_classifier/heuristic_kind_hint_classifier.dart'
    show KindHintClassifier, KindHintEmbedder;
import 'brain_access_boot.dart';
import 'brain_provisioner.dart';
import 'graceful_shutdown.dart';
import 'health_check.dart';
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

  final GracefulShutdown _gracefulShutdown;
  final Future<void> Function() _teardown;

  BrainAccessProcess._({
    required this.port,
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
/// [kindHintClassifier], [clock]) are *not* configuration: they are the
/// substrate / memory edges (and the test clock) a higher assembly injects.
/// The CLI default leaves them `null` (no bearer pre-validation, no cheap
/// classifier — the dispatcher classifies every request). [shutdownSignals] and
/// [terminate] default to the real `SIGINT` / `SIGTERM` + `exit`; a test injects
/// controllers and a recorder.
Future<BrainAccessProcess> startBrainAccessProcess({
  required AccessConfig config,
  required ProvisionedBrain brain,
  AccessServeSeam serve = serveWithShelfIo,
  TelegramChatApiFactory telegramChatApiFactory = defaultTelegramChatApiFactory,
  BearerTokenAuthenticator? bearerAuthenticator,
  KindHintEmbedder? kindHintEmbedder,
  KindHintClassifier? kindHintClassifier,
  List<Stream<ProcessSignal>>? shutdownSignals,
  ProcessTerminator? terminate,
  DateTime Function()? clock,
}) async {
  // ── Phase 5a: compose the admission core over the booted dispatcher. ──
  final BootedAccessLayer booted = BrainAccessBoot.install(
    dispatcher: brain.dispatcher,
    config: _toBrainAccessConfig(
      config,
      bearerAuthenticator: bearerAuthenticator,
      kindHintEmbedder: kindHintEmbedder,
      kindHintClassifier: kindHintClassifier,
      clock: clock,
    ),
  );

  // ── Phase 5b: the live OpenAI + health socket (one Cascade, one port). ──
  final OpenAiAccessEdge openAiEdge = OpenAiAccessEdge(
    assembler: booted.assembler,
    basePath: config.openAiBasePath,
    models: config.personaVocabulary,
  );
  final HealthCheck healthCheck = HealthCheck(
    queueSnapshot: brain.queueSnapshot,
    clock: clock,
  );
  // Health answers `/healthz` and 404s the rest, cascading to the OpenAI edge
  // (which owns the OpenAI 404 envelope for any other unmatched route).
  final Handler handler = Cascade()
      .add(healthCheck.handler)
      .add(openAiEdge.handler)
      .handler;
  final AccessServer server = await serve(handler, config.openAiPort);

  // ── Phase 5c: the optional Telegram edge. ──
  TelegramAdapter? telegramAdapter;
  TelegramAccessEdge? telegramEdge;
  if (config.hasTelegram) {
    final ChatApi chatApi = telegramChatApiFactory(config.telegramBotToken!);
    telegramAdapter = TelegramAdapter(
      chatApi: chatApi,
      whitelist: TelegramWhitelist(config.telegramWhitelist),
    );
    await telegramAdapter.start();
    telegramEdge = TelegramAccessEdge(
      assembler: booted.assembler,
      chatApi: chatApi,
      authorizedInbound: telegramAdapter.authorizedInboundRequests,
    );
    telegramEdge.start();
  }

  // ── Phase 5d: the ordered teardown (idempotent — signal path and `stop`
  //    share it, and it must run at most once). Stop new work arriving first
  //    (channels), then dispose the access layer, then the cognition. ──
  bool tornDown = false;
  Future<void> teardown() async {
    if (tornDown) return;
    tornDown = true;
    await telegramEdge?.stop();
    await telegramAdapter?.stop();
    await server.close();
    await booted.shutdown();
    await brain.shutdown();
  }

  final GracefulShutdown gracefulShutdown = terminate == null
      ? GracefulShutdown.install(
          onShutdown: teardown,
          signals: shutdownSignals,
        )
      : GracefulShutdown.install(
          onShutdown: teardown,
          signals: shutdownSignals,
          terminate: terminate,
        );

  return BrainAccessProcess._(
    port: server.port,
    gracefulShutdown: gracefulShutdown,
    teardown: teardown,
  );
}

/// Maps the on-disk [AccessConfig] onto the [BrainAccessConfig] composition
/// inputs, injecting the runtime seams that are not configuration.
BrainAccessConfig _toBrainAccessConfig(
  AccessConfig config, {
  required BearerTokenAuthenticator? bearerAuthenticator,
  required KindHintEmbedder? kindHintEmbedder,
  required KindHintClassifier? kindHintClassifier,
  required DateTime Function()? clock,
}) =>
    BrainAccessConfig(
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
      sessionMaxWindowTurns: config.sessionMaxWindowTurns,
      clock: clock,
    );

/// The default [AccessServer]: an adapter over a bound `dart:io` [HttpServer].
class _HttpAccessServer implements AccessServer {
  final HttpServer _server;

  _HttpAccessServer(this._server);

  @override
  int get port => _server.port;

  @override
  Future<void> close() => _server.close(force: true);
}
