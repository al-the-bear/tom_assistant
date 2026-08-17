// TomBrainSubstrateIsolateHost — host-side controller for a
// substrate-hosting isolate (Tom Brain completion-plan item #12).
//
// Owns the worker isolate's lifecycle (`spawn` / `shutdown`), the
// host's outbound message dispatch (`send`), and the creator-side
// stream router that forwards `completeStream` / `events` chunks back
// to the proxy. Mirrors `TomBrainMemoryIsolateHost` substrate-locally;
// the cross-cutting flow-control primitives (`IsolateRequestGuard`,
// `IsolateExceptionRegistry`, `IsolateStreamCloseSignal`) come from
// `tom_core_agentic`.
//
// The proxy that consumers actually hold
// (`IsolateTomBrainSubstrateAdapter`) is built on top of this host:
// every `TomBrainSubstrateClient` method translates to a `host.send(...)`
// (unary) or `host.openStream(...)` (streaming) call.

import 'dart:async';
import 'dart:isolate';

import 'package:tom_basics/tom_basics.dart'
    show TomEnvironment, TomPlatform, defaultTomEnvironment;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show
        IsolateExceptionRegistry,
        IsolateRequestFailure,
        IsolateRequestGuard;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomExecutor, TomWorker;

import 'substrate_factory.dart';
import 'substrate_isolate_boot.dart';
import 'substrate_isolate_exceptions.dart';
import 'substrate_isolate_messages.dart';
import 'substrate_stream_protocol.dart';

/// Owns a single substrate-hosting Dart isolate and provides the
/// host-side message dispatch.
///
/// ```dart
/// final host = TomBrainSubstrateIsolateHost(factory: myTopLevelFactory);
/// await host.spawn();
/// // ... send envelopes via host.send<R>(req) / openStream(...) ...
/// await host.shutdown();
/// ```
class TomBrainSubstrateIsolateHost {
  /// The top-level/static factory that constructs the
  /// `TomBrainSubstrateClient` inside the spawned isolate.
  final SubstrateFactory factory;

  final TomEnvironment environment;
  final TomPlatform platform;
  final String namePrefix;
  final List<String> args;

  /// Per-request deadline applied to every host → isolate [send].
  /// `null` (the default) leaves sends unbounded; worker *death* is
  /// always bounded regardless via the isolate-exit listener.
  final Duration? requestTimeout;

  late final IsolateRequestGuard _requestGuard;
  RawReceivePort? _exitPort;

  final IsolateExceptionRegistry _exceptionRegistry =
      IsolateExceptionRegistry();

  final StreamIdAllocator _streamIdAllocator = StreamIdAllocator();
  final Map<int, _StreamSink> _streamSinks = <int, _StreamSink>{};

  TomWorker? _worker;
  _StreamRouter? _router;
  bool _spawnRequested = false;
  final Completer<void> _spawnSettled = Completer<void>();
  bool _shutdownStarted = false;
  bool _shutdownComplete = false;

  TomBrainSubstrateIsolateHost({
    required this.factory,
    this.environment = defaultTomEnvironment,
    TomPlatform? platform,
    this.namePrefix = 'TomBrainSubstrate',
    this.args = const <String>[],
    this.requestTimeout,
  }) : platform = platform ?? _detectPlatform() {
    _requestGuard = IsolateRequestGuard(defaultTimeout: requestTimeout);
    SubstrateIsolateExceptions.registerInto(_exceptionRegistry);
  }

  /// `true` once the spawned isolate has signalled ready.
  bool get isReady => _worker?.isReady ?? false;

  /// `true` once [shutdown] has run to completion. Single-use host.
  bool get isClosed => _shutdownComplete && (_worker?.isClosed ?? true);

  /// `true` once the worker isolate has been observed to die.
  bool get isWorkerDead => _requestGuard.isWorkerDead;

  /// Host-side stream-id allocator. Visible so the proxy can mint ids.
  StreamIdAllocator get streamIdAllocator => _streamIdAllocator;
  int get liveStreamCount => _streamSinks.length;

  /// The live worker isolate, or `null` before [spawn] / after
  /// [shutdown]. Visible to tests.
  Isolate? get workerIsolate => _worker?.isolate;

  // ─── Lifecycle ────────────────────────────────────────────────

  /// Spawns the isolate and waits for it to signal ready. Idempotent
  /// within a single host instance. Throws [StateError] after
  /// [shutdown].
  Future<void> spawn() async {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.spawn() called after shutdown(); '
        'hosts are single-use.',
      );
    }
    if (_spawnRequested) {
      return _spawnSettled.future;
    }
    _spawnRequested = true;
    try {
      final ctx = SubstrateWorkerContext(
        factory: factory,
        tomEnvironment: environment,
        tomPlatform: platform,
        args: args,
        namePrefix: namePrefix,
      );
      _worker = await TomWorker.spawn(TomWorker.startRemoteIsolate, ctx);
      _exitPort = RawReceivePort((Object? _) {
        _requestGuard.markWorkerDead('worker isolate exited');
      });
      _worker!.isolate.addOnExitListener(_exitPort!.sendPort);
      _router = _StreamRouter(_streamSinks, _exceptionRegistry);
      TomWorker.addExecutor(_router!);
      _spawnSettled.complete();
    } catch (error, stack) {
      _spawnSettled.completeError(error, stack);
      rethrow;
    }
  }

  /// Shuts the isolate down cleanly. Idempotent; safe in a `finally`.
  ///
  /// The substrate worker holds no durable state to flush (unlike the
  /// memory store's WAL), so shutdown tears down live streams, removes
  /// the router, and closes the worker directly.
  Future<void> shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final worker = _worker;
    if (worker == null) {
      _shutdownComplete = true;
      return;
    }
    for (final sink in _streamSinks.values.toList()) {
      if (!sink.controller.isClosed) {
        await sink.controller.close();
      }
    }
    _streamSinks.clear();
    final router = _router;
    if (router != null) {
      TomWorker.removeExecutor(router);
      _router = null;
    }
    _exitPort?.close();
    _exitPort = null;
    worker.close();
    _shutdownComplete = true;
  }

  // ─── Envelope dispatch ────────────────────────────────────────

  /// Sends [request] to the in-isolate executor and returns the typed
  /// [R] response.
  ///
  /// Throws the reconstructed typed exception (or
  /// [IsolateBoundaryException]) when the executor returned an
  /// [IsolateErrorResponse]; throws [StateError] when the host is not
  /// ready / shut down or the response type does not match [R].
  Future<R> send<R extends IsolateResponse>(IsolateRequest request) async {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.send() called after shutdown().',
      );
    }
    final worker = _worker;
    if (worker == null) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.send() called before spawn().',
      );
    }
    if (!worker.isReady) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.send() called before worker '
        'reported ready.',
      );
    }
    final raw = await _requestGuard.guard(
      worker.executeCommand(request),
      operation: request.runtimeType.toString(),
    );
    if (raw is IsolateErrorResponse) {
      final translated = _exceptionRegistry.reconstruct(
        raw.exceptionType,
        raw.message,
        raw.details,
      );
      throw translated ??
          IsolateBoundaryException(raw.message, raw.exceptionType);
    }
    if (raw is! R) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.send() received ${raw?.runtimeType} '
        'but expected $R for request ${request.runtimeType}.',
      );
    }
    return raw;
  }

  // ─── Streaming surface ───────────────────────────────────────

  /// Opens a stream by sending [openRequest] and registering a
  /// host-side [StreamController] for chunks of type [T].
  ///
  /// [streamId] **must** be the id carried inside [openRequest] — the
  /// router needs it before the open reply arrives, since chunks can
  /// land first. Returns the controller's stream.
  Stream<T> openStream<T>(
    IsolateRequest openRequest, {
    required StreamId streamId,
    T Function(Object?)? payloadAdapter,
  }) {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainSubstrateIsolateHost.openStream() called after shutdown().',
      );
    }
    final controller = StreamController<T>();
    _streamSinks[streamId.id] = _StreamSink(
      controller: controller,
      adapter: payloadAdapter ?? ((Object? p) => p as T),
    );
    () async {
      try {
        await send<StreamOpenedResponse>(openRequest);
      } catch (e, st) {
        final sink = _streamSinks.remove(streamId.id);
        if (sink != null && !sink.controller.isClosed) {
          sink.controller.addError(e, st);
          await sink.controller.close();
        }
      }
    }();
    return controller.stream;
  }

  /// Closes an open stream from the host side. The executor stops the
  /// producer and the host-side sink is torn down.
  Future<void> closeStream(StreamId streamId) async {
    final sink = _streamSinks.remove(streamId.id);
    try {
      await send<StreamCloseResponse>(StreamCloseRequest(streamId));
    } on IsolateBoundaryException {
      // The producer may have already terminated; ignore.
    } on StateError {
      // The host may be mid-shutdown; ignore.
    } on IsolateRequestFailure {
      // The worker died / timed out: the producer is already gone.
    }
    if (sink != null && !sink.controller.isClosed) {
      await sink.controller.close();
    }
  }

  // ─── Platform autodetect ──────────────────────────────────────

  static TomPlatform _detectPlatform() => const TomPlatform('linux');
}

/// Per-open-stream host-side state.
class _StreamSink {
  final StreamController<dynamic> controller;
  final dynamic Function(Object?) adapter;

  _StreamSink({required this.controller, required this.adapter});
}

/// Creator-side executor that picks up [StreamSideChannelMessage]
/// instances sent from the isolate via `TomWorker.sendToCreator` and
/// routes them to the appropriate host-side [StreamController].
///
/// One router per host. Messages whose `streamId` is not registered are
/// claimed (and dropped) rather than cascaded — they belong to another
/// host that shares the static `TomWorker.executors` registry, and a
/// side-channel envelope is no other executor's business.
class _StreamRouter extends TomExecutor {
  final Map<int, _StreamSink> sinks;
  final IsolateExceptionRegistry exceptionRegistry;

  _StreamRouter(this.sinks, this.exceptionRegistry);

  @override
  Object execute(Object command) {
    if (command is! StreamSideChannelMessage) {
      return TomExecutor.noResult;
    }
    final sink = sinks[command.streamId.id];
    if (sink == null) {
      return _routerHandled;
    }
    if (command is StreamChunkEnvelope) {
      if (!sink.controller.isClosed) {
        sink.controller.add(sink.adapter(command.payload));
      }
    } else if (command is StreamCompleteEnvelope) {
      sinks.remove(command.streamId.id);
      if (!sink.controller.isClosed) {
        unawaited(sink.controller.close());
      }
    } else if (command is StreamErrorEnvelope) {
      sinks.remove(command.streamId.id);
      if (!sink.controller.isClosed) {
        final translated = exceptionRegistry.reconstruct(
          command.exceptionType,
          command.message,
          command.details,
        );
        sink.controller.addError(
          translated ??
              IsolateBoundaryException(command.message, command.exceptionType),
        );
        unawaited(sink.controller.close());
      }
    } else if (command is StreamCancelledEnvelope) {
      sinks.remove(command.streamId.id);
      if (!sink.controller.isClosed) {
        unawaited(sink.controller.close());
      }
    }
    return _routerHandled;
  }

  static const Object _routerHandled = Object();
}
