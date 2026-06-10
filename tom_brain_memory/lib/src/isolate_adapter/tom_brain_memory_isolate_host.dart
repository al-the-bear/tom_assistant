// TomBrainMemoryIsolateHost — host-side controller for a
// memory-hosting isolate (plan step A.79, extended in A.81).
//
// Owns the worker isolate's lifecycle (`spawn` / `shutdown`) and
// the host's outbound message dispatch (`send`). The thin client
// that consumers actually hold (`TomBrainMemoryIsolateClient`,
// plan A.80) is built on top of this host — every method on
// `TomBrainMemoryClient` translates to a single `host.send(...)`
// call.
//
// A.81 additions:
//
//   * Owns the host-side `IsolateCancellationTokenAllocator` and
//     `StreamIdAllocator` so every cancellable request /
//     stream-open carries a fresh id.
//   * Registers a creator-side `TomExecutor` (`_StreamRouter`) on
//     `TomWorker.executors` that intercepts
//     `StreamSideChannelMessage`s sent from the isolate via
//     `sendToCreator(...)` and forwards them to the right
//     `StreamController`.
//   * Exposes `openStream` / `closeStream` / `pullCredits` helpers
//     so the client can drive backpressure without learning the
//     router's internals.

import 'dart:async';

import 'package:tom_basics/tom_basics.dart'
    show TomEnvironment, TomPlatform, defaultTomEnvironment;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateCancellationToken, IsolateCancellationTokenAllocator;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomExecutor, TomWorker;

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryConfig;
import '../observability/memory_log.dart';
import 'isolate_boot.dart';
import 'isolate_cancellation_protocol.dart';
import 'isolate_envelopes_full.dart';
import 'isolate_messages.dart';
import 'isolate_stream_protocol.dart';
import 'memory_factory.dart';

/// Owns a single memory-hosting Dart isolate and provides the
/// host-side message dispatch.
///
/// Usage:
///
/// ```dart
/// final host = TomBrainMemoryIsolateHost(factory: myTopLevelFactory);
/// await host.spawn();
/// await host.openMemory(config);
/// // ... send envelopes via host.send<R>(req) ...
/// await host.shutdown();
/// ```
class TomBrainMemoryIsolateHost {
  /// The top-level/static factory that constructs the
  /// `TomBrainMemory` instance inside the spawned isolate. See
  /// the [MemoryFactory] typedef docs for the constraint
  /// rationale.
  final MemoryFactory factory;

  /// Forwarded into [MemoryWorkerContext] for `TomWorker`-level
  /// isolate naming. Defaults match `tom_core_kernel`'s example
  /// posture (linuxy, default env) so test wiring is one-line.
  final TomEnvironment environment;
  final TomPlatform platform;
  final String namePrefix;
  final List<String> args;

  /// The trail log root forwarded into [MemoryWorkerContext] so the spawned
  /// isolate installs a `FanoutLogOutput` on its own `tomLog`
  /// (`tom_brain_logging.md` §5.1 / §10 step #3). `null` (the default) leaves
  /// the isolate's logging at its console default.
  final String? logRootPath;

  /// A.81 — host-side allocators. Public-getter accessible so the
  /// client can mint tokens/ids without re-implementing the
  /// counter.
  final IsolateCancellationTokenAllocator _cancellationAllocator =
      IsolateCancellationTokenAllocator();
  final StreamIdAllocator _streamIdAllocator = StreamIdAllocator();

  /// A.81 — host-side stream sinks. Keyed by `streamId.id`. The
  /// `_StreamRouter` puts chunks here; the client consumes them
  /// from the per-stream `StreamController.stream`.
  final Map<int, _StreamSink> _streamSinks = <int, _StreamSink>{};

  TomWorker? _worker;
  _StreamRouter? _router;
  bool _spawnRequested = false;

  /// Completes when the first [spawn] settles. Concurrent / repeat
  /// callers await this instead of polling [_worker]; it carries the
  /// spawn error through to every waiter when the first attempt throws.
  final Completer<void> _spawnSettled = Completer<void>();
  bool _shutdownStarted = false;
  bool _shutdownComplete = false;
  bool _memoryOpen = false;

  TomBrainMemoryIsolateHost({
    required this.factory,
    this.environment = defaultTomEnvironment,
    TomPlatform? platform,
    this.namePrefix = 'TomBrainMemory',
    this.args = const <String>[],
    this.logRootPath,
  }) : platform = platform ?? _detectPlatform();

  /// `true` once the spawned isolate has signalled ready and the
  /// host can send envelopes.
  bool get isReady => _worker?.isReady ?? false;

  /// `true` once [shutdown] has run to completion. The host is
  /// single-use — a closed host cannot be reopened. Construct a
  /// fresh host for a fresh isolate.
  bool get isClosed => _shutdownComplete && (_worker?.isClosed ?? true);

  /// Whether [openMemory] has succeeded without a subsequent
  /// successful [closeMemory]. Tracked host-side as a fast guard
  /// against caller error; the in-isolate executor is the
  /// authoritative source.
  bool get isMemoryOpen => _memoryOpen;

  /// A.81 — visible to tests.
  IsolateCancellationTokenAllocator get cancellationAllocator =>
      _cancellationAllocator;
  StreamIdAllocator get streamIdAllocator => _streamIdAllocator;
  int get liveStreamCount => _streamSinks.length;

  // ─── Lifecycle ────────────────────────────────────────────────

  /// Spawns the isolate and waits for it to signal ready.
  ///
  /// Idempotent within a single host instance: a second call
  /// returns the same future shape as the first (resolved once
  /// the worker is ready) but does not respawn.
  ///
  /// Throws [StateError] if called after [shutdown].
  Future<void> spawn() async {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainMemoryIsolateHost.spawn() called after shutdown(); '
        'hosts are single-use.',
      );
    }
    if (_spawnRequested) {
      // Await the in-flight (or completed) spawn rather than polling.
      // Propagates the spawn error to repeat callers too.
      return _spawnSettled.future;
    }
    _spawnRequested = true;
    try {
      final ctx = MemoryWorkerContext(
        factory: factory,
        tomEnvironment: environment,
        tomPlatform: platform,
        args: args,
        namePrefix: namePrefix,
        logRootPath: logRootPath,
      );
      _worker = await TomWorker.spawn(TomWorker.startRemoteIsolate, ctx);
      // A.81: install the creator-side router so the isolate can push
      // stream chunks back to us via `sendToCreator(...)`.
      _router = _StreamRouter(_streamSinks);
      TomWorker.executors.add(_router!);
      // A.84 — host spawn is a major lifecycle event; one `status`
      // line so operators see the boot in any log filter.
      MemoryLog.isolate.status(
        () => 'isolate host spawned (namePrefix=$namePrefix)',
      );
      _spawnSettled.complete();
    } catch (error, stack) {
      _spawnSettled.completeError(error, stack);
      rethrow;
    }
  }

  /// Shuts the isolate down cleanly.
  ///
  /// If the memory was opened, sends a [CloseMemoryRequest] first
  /// so writes are flushed and the WAL is checkpointed. After
  /// either branch completes, sends the worker its shutdown
  /// signal and marks the host closed.
  ///
  /// Idempotent. Safe to call from a `finally` block.
  Future<void> shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    final worker = _worker;
    if (worker == null) {
      _shutdownComplete = true;
      return;
    }
    if (_memoryOpen) {
      try {
        // Use the unguarded path: the public `send()` rejects calls
        // after shutdown has started, but the close envelope is
        // precisely the work `shutdown()` itself needs to dispatch.
        await _sendUnguarded<CloseMemoryResponse>(
          const CloseMemoryRequest(),
        );
        _memoryOpen = false;
      } on IsolateBoundaryException {
        // Already-closed memory is a no-op at the contract level;
        // any other boundary error during shutdown is non-fatal:
        // we still want to close the worker.
        _memoryOpen = false;
      }
    }
    // A.81: tear down live streams + remove the router.
    for (final sink in _streamSinks.values.toList()) {
      if (!sink.controller.isClosed) {
        await sink.controller.close();
      }
    }
    _streamSinks.clear();
    final router = _router;
    if (router != null) {
      TomWorker.executors.remove(router);
      _router = null;
    }
    worker.close();
    _shutdownComplete = true;
    // A.84 — matching `status` for clean shutdown so an operator can
    // confirm the worker stopped cleanly without inspecting state.
    MemoryLog.isolate.status('isolate host shut down');
  }

  // ─── Envelope dispatch ────────────────────────────────────────

  /// Sends [request] to the in-isolate executor and returns the
  /// typed [R] response.
  ///
  /// Throws [IsolateBoundaryException] when the executor returned
  /// an [IsolateErrorResponse]; throws [StateError] when the host
  /// is not yet ready or has been shut down; throws [TypeError]
  /// when the executor returned a response of the wrong type
  /// (i.e. a protocol mismatch between host and isolate).
  Future<R> send<R extends IsolateResponse>(IsolateRequest request) async {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainMemoryIsolateHost.send() called after shutdown().',
      );
    }
    return _sendUnguarded<R>(request);
  }

  /// Same as [send] but bypasses the shutdown-started guard.
  ///
  /// Reserved for [shutdown] itself, which has to send the
  /// `CloseMemoryRequest` envelope after marking the host as
  /// shutting-down (so a re-entrant `shutdown()` is a no-op).
  Future<R> _sendUnguarded<R extends IsolateResponse>(
    IsolateRequest request,
  ) async {
    final worker = _worker;
    if (worker == null) {
      throw StateError(
        'TomBrainMemoryIsolateHost.send() called before spawn().',
      );
    }
    if (!worker.isReady) {
      throw StateError(
        'TomBrainMemoryIsolateHost.send() called before worker '
        'reported ready.',
      );
    }
    final raw = await worker.executeCommand(request);
    if (raw is IsolateErrorResponse) {
      throw IsolateBoundaryException(raw.message, raw.exceptionType);
    }
    if (raw is! R) {
      throw StateError(
        'TomBrainMemoryIsolateHost.send() received '
        '${raw?.runtimeType} but expected $R for request '
        '${request.runtimeType}.',
      );
    }
    return raw;
  }

  // ─── A.81: streaming surface ─────────────────────────────────

  /// Opens a stream by sending [openRequest] and registering a
  /// host-side [StreamController] for chunks of type [T].
  ///
  /// [streamId] **must** be the same id carried inside
  /// [openRequest] (the request envelope carries it because the
  /// router needs it before the open envelope's reply has even
  /// been sent — chunks could arrive before the response).
  ///
  /// Returns the controller's stream. The caller is responsible
  /// for calling [closeStream] when done (or pausing the stream
  /// to trigger backpressure).
  Stream<T> openStream<T>(
    IsolateRequest openRequest, {
    required StreamId streamId,
    T Function(Object?)? payloadAdapter,
  }) {
    if (_shutdownStarted) {
      throw StateError(
        'TomBrainMemoryIsolateHost.openStream() called after shutdown().',
      );
    }
    // Pre-register the sink so any chunk that arrives before the
    // open response has a home.
    final controller = StreamController<T>();
    _streamSinks[streamId.id] = _StreamSink(
      controller: controller,
      adapter: payloadAdapter ?? ((Object? p) => p as T),
      onCancel: () => closeStream(streamId),
    );
    // Fire the open envelope. We do not await — the consumer can
    // start listening immediately, and any error in opening will
    // come back as a stream error.
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

  /// Tops up backpressure credits for [streamId].
  Future<void> pullCredits(StreamId streamId, int credits) async {
    await send<StreamPullResponse>(
      StreamPullRequest(streamId: streamId, credits: credits),
    );
  }

  /// Cancels an open token. The in-flight stream / recall will
  /// honour the cancellation at its next checkpoint.
  Future<void> cancel(IsolateCancellationToken token) async {
    await send<CancelResponse>(CancelRequest(token));
  }

  /// Closes an open stream from the host side. The executor stops
  /// the producer and the host-side sink is torn down.
  Future<void> closeStream(StreamId streamId) async {
    final sink = _streamSinks.remove(streamId.id);
    try {
      await send<StreamCloseResponse>(StreamCloseRequest(streamId));
    } on IsolateBoundaryException {
      // The producer may have already terminated; ignore.
    } on StateError {
      // The host may be mid-shutdown; ignore.
    }
    if (sink != null && !sink.controller.isClosed) {
      await sink.controller.close();
    }
  }

  // ─── Convenience wrappers ─────────────────────────────────────

  /// `send(PingRequest)` with a host-side wall-clock timestamp.
  ///
  /// Returns the round-trip latency in milliseconds. The latency is
  /// measured against the host's own clock at send and receive, so a
  /// wall-clock source is acceptable here (it is never compared
  /// against the isolate's clock). Used by tests; production callers
  /// would log the [PongResponse] directly.
  Future<int> ping() async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    await send<PongResponse>(PingRequest(hostWallClockMs: t0));
    return DateTime.now().millisecondsSinceEpoch - t0;
  }

  /// Drives `memory.open(config)` inside the isolate.
  ///
  /// Marks the host's `isMemoryOpen` once the response arrives so
  /// [shutdown] can decide whether to send a `CloseMemoryRequest`
  /// during shutdown.
  Future<void> openMemory(MemoryConfig config) async {
    await send<OpenMemoryResponse>(OpenMemoryRequest(config: config));
    _memoryOpen = true;
  }

  /// Drives `memory.close()` inside the isolate. The in-process
  /// contract is idempotent; this wrapper updates the host-side
  /// open-flag so a subsequent [shutdown] does not send a second
  /// close envelope.
  Future<void> closeMemory() async {
    await send<CloseMemoryResponse>(const CloseMemoryRequest());
    _memoryOpen = false;
  }

  // ─── Platform autodetect ──────────────────────────────────────
  //
  // The `tom_basics` constants `platformLinux`, `platformMacOS`,
  // `platformWindows` are workspace conventions; the host has no
  // reason to care about the difference at this layer, but the
  // `TomWorkerContext` constructor requires one. We pick the
  // current host's, defaulting to the linux constant on
  // unrecognised platforms because the worker is process-local
  // and the platform tag is metadata, not control flow.
  static TomPlatform _detectPlatform() {
    // Avoid pulling `dart:io.Platform` here — `tom_basics` already
    // ships a value for the workspace-default host that the
    // existing examples use. The example file
    // `01_worker_basics_example.dart` shows the canonical pattern
    // (`platformLinux`); we mirror it.
    return const TomPlatform('linux');
  }
}

/// Per-open-stream host-side state.
class _StreamSink {
  final StreamController<dynamic> controller;
  final dynamic Function(Object?) adapter;
  final Future<void> Function() onCancel;

  _StreamSink({
    required this.controller,
    required this.adapter,
    required this.onCancel,
  });
}

/// Creator-side executor that picks up [StreamSideChannelMessage]
/// instances sent from the isolate via `TomWorker.sendToCreator`
/// and routes them to the appropriate host-side [StreamController].
///
/// One router per [TomBrainMemoryIsolateHost]. Messages whose
/// `streamId` is not registered are silently dropped — they belong
/// to another host that shares the static `TomWorker.executors`
/// list. Returning [TomExecutor.noResult] would not be right here
/// because the message is no-one else's either; we just drop it
/// without emitting a "no result" cascade.
class _StreamRouter extends TomExecutor {
  final Map<int, _StreamSink> sinks;

  _StreamRouter(this.sinks);

  @override
  Object execute(Object command) {
    if (command is! StreamSideChannelMessage) {
      return TomExecutor.noResult;
    }
    final sink = sinks[command.streamId.id];
    if (sink == null) {
      // Belongs to another host (or already torn down). Claim it —
      // returning noResult would let it cascade through other
      // executors, which is wrong because the message is a
      // stream-side-channel envelope and only routers handle them.
      return _routerHandled;
    }
    if (command is StreamChunkEnvelope) {
      if (!sink.controller.isClosed) {
        sink.controller.add(sink.adapter(command.payload));
      }
    } else if (command is StreamCompleteEnvelope) {
      sinks.remove(command.streamId.id);
      if (!sink.controller.isClosed) {
        // Detach the close call from the executor's synchronous
        // path so the executor can return immediately.
        unawaited(sink.controller.close());
      }
    } else if (command is StreamErrorEnvelope) {
      sinks.remove(command.streamId.id);
      if (!sink.controller.isClosed) {
        sink.controller.addError(
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

  /// Distinct sentinel object so the executor framework does not
  /// confuse "I handled it" with "no result".
  static const Object _routerHandled = Object();
}
