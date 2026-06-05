// E.45 — the boot root that ties the running access process together.
//
// `startBrainAccessProcess` composes the admission core (E.41) over an
// already-provisioned cognition, stands up the OpenAI + `/healthz` socket
// through the injectable `AccessServeSeam`, optionally stands up the Telegram
// edge through the `TelegramChatApiFactory` seam, and installs a graceful
// shutdown coordinator over the ordered teardown. These tests drive the whole
// process with a fake serve seam (capturing the composed handler, reporting a
// synthetic port — no socket), a fake Telegram factory (a `LoopbackChatApi` —
// no network), a `ProvisionedBrain` over a recording dispatcher, and injected
// signal controllers + a recording terminator.
//
// What is proven:
//   1. The composed handler answers `GET /healthz` (200) and cascades `/v1/*`
//      to the OpenAI edge (`GET /v1/models` → 200) on one port.
//   2. The bound port is the one the serve seam reported.
//   3. No Telegram channel is stood up when the config has no bot token; one
//      is when it does (the factory is invoked, the edge runs).
//   4. A termination signal drives the ordered teardown (server closed, access
//      layer shut down, cognition shut down) and resolves `completed` with the
//      clean exit code.
//   5. `stop()` runs the same teardown programmatically, exactly once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart' show ChatApi;

import '../_support/loopback_chat_api.dart';

DateTime _fixedNow() => DateTime.utc(2026, 6, 2, 12);

RateLimitPolicy _openPolicy() => RateLimitPolicy(
      capacity: 100,
      refillTokens: 100,
      refillPeriod: const Duration(seconds: 1),
    );

/// A fake `AccessServer` recording its close; no real socket is bound.
class _FakeAccessServer implements AccessServer {
  @override
  final int port;
  bool closed = false;
  _FakeAccessServer(this.port);

  @override
  Future<void> close() async => closed = true;
}

/// A capturing serve seam: records the composed handler and reports a
/// synthetic port (the requested port, or 4242 when 0 was requested).
class _CaptureServe {
  Handler? handler;
  _FakeAccessServer? server;

  Future<AccessServer> call(Handler handler, int port) async {
    this.handler = handler;
    final bound = _FakeAccessServer(port == 0 ? 4242 : port);
    server = bound;
    return bound;
  }
}

/// A serve seam that captures *every* socket the process stands up, keyed by
/// the port it bound. Lets a multi-channel process (OpenAI + Ollama +
/// Anthropic) be driven with no real sockets.
class _MultiCaptureServe {
  final Map<int, Handler> handlers = <int, Handler>{};
  final List<_FakeAccessServer> servers = <_FakeAccessServer>[];

  Future<AccessServer> call(Handler handler, int port) async {
    final bound = _FakeAccessServer(port == 0 ? 4242 : port);
    handlers[bound.port] = handler;
    servers.add(bound);
    return bound;
  }
}

QueueSnapshot _idleSnapshot() => QueueSnapshot(
      foregroundRunning: false,
      foregroundWaiting: 0,
      foregroundQueueDepth: 4,
      backgroundRunning: false,
      draining: false,
    );

/// A provisioned brain over a recording dispatcher, counting its shutdown.
({ProvisionedBrain brain, List<Access> routed, _ShutdownCounter shutdown})
    _provisionedBrain() {
  final routed = <Access>[];
  final counter = _ShutdownCounter();
  final dispatcher = Dispatcher(
    route: (access) async {
      routed.add(access);
      access.deliver(OutboundChunk(textDelta: 'answer', isFinal: true));
    },
  );
  final brain = ProvisionedBrain(
    dispatcher: dispatcher,
    queueSnapshot: _idleSnapshot,
    shutdown: counter.call,
  );
  return (brain: brain, routed: routed, shutdown: counter);
}

class _ShutdownCounter {
  int calls = 0;
  Future<void> call() async => calls++;
}

AccessConfig _config({
  bool telegram = false,
  bool bearer = false,
  String? edgeStateDir,
  int? ollamaPort,
  int? anthropicPort,
}) =>
    AccessConfig(
      openAiPort: 7654,
      ollamaPort: ollamaPort,
      anthropicPort: anthropicPort,
      rateLimitPolicy: _openPolicy(),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      telegramBotToken: telegram ? 'bot-token:abc' : null,
      telegramUserIdBindings: telegram
          ? {'tg-42': IdentityBinding(principalId: 'principal-1')}
          : const {},
      bearerTokenBindings: bearer
          ? {'secret-token': IdentityBinding(principalId: 'principal-1')}
          : const {},
      edgeStateDirectory: edgeStateDir,
    );

Future<Response> _post(Handler handler, String path, String body) async =>
    await handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        headers: const <String, String>{
          'content-type': 'application/json',
          'authorization': 'Bearer secret-token',
        },
        body: body,
      ),
    );

Future<Response> _get(Handler handler, String path) async =>
    await handler(Request('GET', Uri.parse('http://localhost$path')));

void main() {
  group('startBrainAccessProcess — composed socket', () {
    test('the handler answers /healthz and cascades /v1/models on one port',
        () async {
      final serve = _CaptureServe();
      final pb = _provisionedBrain();
      final process = await startBrainAccessProcess(
        config: _config(),
        brain: pb.brain,
        serve: serve.call,
        clock: _fixedNow,
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      // The serve seam reported the requested port (config.openAiPort).
      expect(process.port, 7654);

      final health = await _get(serve.handler!, '/healthz');
      expect(health.statusCode, 200);
      final healthBody =
          jsonDecode(await health.readAsString()) as Map<String, Object?>;
      expect(healthBody['status'], HealthCheck.statusOk);

      // /v1/* cascades past the health router to the OpenAI edge.
      final models = await _get(serve.handler!, '/v1/models');
      expect(models.statusCode, 200);

      // An unknown route falls through to the OpenAI 404 envelope.
      final unknown = await _get(serve.handler!, '/nope');
      expect(unknown.statusCode, 404);
    });
  });

  group('startBrainAccessProcess — edge-state persistence (P1.4)', () {
    test('a configured edgeState directory persists limiter state to JSON files',
        () async {
      final dir = Directory.systemTemp.createTempSync('edge_proc_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final serve = _CaptureServe();
      final process = await startBrainAccessProcess(
        config: _config(bearer: true, edgeStateDir: dir.path),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        clock: _fixedNow,
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      // One admitted chat completion spends a rate-limit token and a quota
      // call, each of which the file stores persist.
      final response = await serve.handler!(
        Request(
          'POST',
          Uri.parse('http://localhost/v1/chat/completions'),
          headers: const <String, String>{
            'content-type': 'application/json',
            'authorization': 'Bearer secret-token',
          },
          body: jsonEncode(<String, Object?>{
            'model': 'tom-assistant',
            'stream': false,
            'messages': <Object?>[
              <String, Object?>{'role': 'user', 'content': 'hi'},
            ],
          }),
        ),
      );
      await pumpEventQueue();

      expect(response.statusCode, 200);
      expect(File('${dir.path}/quota_state.json').existsSync(), isTrue,
          reason: 'daily-quota counter should be persisted');
      expect(File('${dir.path}/rate_limit_state.json').existsSync(), isTrue,
          reason: 'rate-limit bucket should be persisted');
    });
  });

  group('startBrainAccessProcess — Telegram channel', () {
    test('no Telegram channel is stood up without a bot token', () async {
      final serve = _CaptureServe();
      var factoryCalls = 0;
      final process = await startBrainAccessProcess(
        config: _config(),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        telegramChatApiFactory: (token) {
          factoryCalls++;
          return LoopbackChatApi();
        },
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      expect(factoryCalls, 0);
    });

    test('a configured bot token stands up the Telegram edge', () async {
      final serve = _CaptureServe();
      LoopbackChatApi? built;
      ChatApi factory(String token) {
        built = LoopbackChatApi();
        return built!;
      }

      final process = await startBrainAccessProcess(
        config: _config(telegram: true),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        telegramChatApiFactory: factory,
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      expect(built, isNotNull);
      // The adapter initialised the channel (it drives its long-poll loop).
      expect(built!.initializeCount, greaterThanOrEqualTo(1));
    });
  });

  group('startBrainAccessProcess — Ollama + Anthropic channels', () {
    test('no extra socket is stood up when no Ollama / Anthropic port is set',
        () async {
      final serve = _MultiCaptureServe();
      final process = await startBrainAccessProcess(
        config: _config(),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        clock: _fixedNow,
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      expect(process.ollamaPort, isNull);
      expect(process.anthropicPort, isNull);
      // Only the OpenAI + health socket was bound.
      expect(serve.servers.map((s) => s.port), [7654]);
    });

    test('configured Ollama + Anthropic ports each stand up their own socket '
        'driving the shared admission core', () async {
      final serve = _MultiCaptureServe();
      final process = await startBrainAccessProcess(
        config: _config(bearer: true, ollamaPort: 8081, anthropicPort: 8082),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        clock: _fixedNow,
        shutdownSignals: const [],
        terminate: (_) {},
      );
      addTearDown(process.stop);

      expect(process.port, 7654);
      expect(process.ollamaPort, 8081);
      expect(process.anthropicPort, 8082);
      expect(serve.servers.map((s) => s.port).toSet(), {7654, 8081, 8082});

      // The Ollama socket answers /api/chat against the shared bearer binding.
      final ollama = await _post(
        serve.handlers[8081]!,
        '/api/chat',
        jsonEncode(<String, Object?>{
          'model': 'tom-assistant',
          'stream': false,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(ollama.statusCode, 200);

      // The Anthropic socket answers /v1/messages against the same binding.
      final anthropic = await _post(
        serve.handlers[8082]!,
        '/v1/messages',
        jsonEncode(<String, Object?>{
          'model': 'tom-assistant',
          'max_tokens': 1024,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(anthropic.statusCode, 200);
      final anthropicBody =
          jsonDecode(await anthropic.readAsString()) as Map<String, Object?>;
      expect(anthropicBody['type'], 'message');
    });

    test('teardown closes every stood-up socket', () async {
      final serve = _MultiCaptureServe();
      final process = await startBrainAccessProcess(
        config: _config(bearer: true, ollamaPort: 8081, anthropicPort: 8082),
        brain: _provisionedBrain().brain,
        serve: serve.call,
        shutdownSignals: const [],
        terminate: (_) {},
      );

      await process.stop();

      expect(serve.servers.length, 3);
      expect(serve.servers.every((s) => s.closed), isTrue);
    });
  });

  group('startBrainAccessProcess — graceful shutdown', () {
    test('a termination signal runs the ordered teardown and exits cleanly',
        () async {
      final serve = _CaptureServe();
      final pb = _provisionedBrain();
      final signals = StreamController<ProcessSignal>.broadcast();
      final exitCodes = <int>[];

      final process = await startBrainAccessProcess(
        config: _config(),
        brain: pb.brain,
        serve: serve.call,
        shutdownSignals: [signals.stream],
        terminate: exitCodes.add,
      );

      expect(process.isShutdownTriggered, isFalse);
      signals.add(ProcessSignal.sigint);
      final code = await process.completed;

      expect(code, shutdownExitOk);
      expect(exitCodes, [shutdownExitOk]);
      // The teardown ran: socket closed, cognition shut down.
      expect(serve.server!.closed, isTrue);
      expect(pb.shutdown.calls, 1);
    });

    test('stop() runs the teardown programmatically, exactly once', () async {
      final serve = _CaptureServe();
      final pb = _provisionedBrain();
      final process = await startBrainAccessProcess(
        config: _config(),
        brain: pb.brain,
        serve: serve.call,
        shutdownSignals: const [],
        terminate: (_) {},
      );

      await process.stop();
      await process.stop(); // idempotent

      expect(serve.server!.closed, isTrue);
      expect(pb.shutdown.calls, 1);
    });
  });
}
