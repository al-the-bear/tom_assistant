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

AccessConfig _config({bool telegram = false}) => AccessConfig(
      openAiPort: 7654,
      rateLimitPolicy: _openPolicy(),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      telegramBotToken: telegram ? 'bot-token:abc' : null,
      telegramUserIdBindings: telegram
          ? {'tg-42': IdentityBinding(principalId: 'principal-1')}
          : const {},
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
