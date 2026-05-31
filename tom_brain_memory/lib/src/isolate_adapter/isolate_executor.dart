// MemoryIsolateExecutor — the in-isolate `TomExecutor` that
// dispatches `IsolateRequest` envelopes to the held
// `TomBrainMemory` instance (plan step A.79).
//
// Constructed inside `MemoryWorkerContext.initializeIsolate` and
// registered onto `TomWorker.executors` (the per-isolate static
// list). One instance per isolate; lifetime equals isolate
// lifetime.
//
// Dispatch rules:
//
//   * The executor handles `IsolateRequest` envelopes only. Any
//     other command surfaces as `TomExecutor.noResult` so the
//     `TomWorker.executors` chain can pass it to the next handler
//     (e.g. logging instrumentation Phase D will wire in).
//   * `OpenMemoryRequest` is the only envelope that touches the
//     memory's lifecycle. Every other request requires memory to
//     be open already; calling them against an unopened memory
//     surfaces as `IsolateErrorResponse(StateError, "memory is
//     not open")`.
//   * Exceptions thrown by the memory layer are caught at this
//     boundary and packed into `IsolateErrorResponse`. The host
//     re-raises as `IsolateBoundaryException` (see
//     `isolate_messages.dart`).

import 'package:tom_core_kernel/tom_core_kernel.dart' show TomExecutor;

import '../api/memory_stats.dart';
import '../api/tom_brain_memory.dart';
import 'isolate_messages.dart';
import 'memory_factory.dart';

/// The executor that owns the in-isolate `TomBrainMemory`
/// instance and translates inbound envelopes into method calls
/// against it.
///
/// Not exported from the package barrel — the host owns its
/// construction and consumers never see this type. Visible to
/// `MemoryWorkerContext` (this folder) and to tests that exercise
/// the dispatch directly.
class MemoryIsolateExecutor extends TomExecutor {
  /// The factory the executor calls when an [OpenMemoryRequest]
  /// arrives and no memory has been constructed yet. Kept as a
  /// field rather than a constructor argument so that test
  /// harnesses can replace it after construction.
  final MemoryFactory factory;

  TomBrainMemory? _memory;

  /// `true` once [OpenMemoryRequest] has been honoured and the
  /// memory's `open()` has completed. Lifecycle marker only —
  /// the memory itself is the source of truth for downstream
  /// behaviour.
  bool _open = false;

  /// Visible to tests only. Production callers go through the
  /// envelope protocol.
  TomBrainMemory? get memoryForTesting => _memory;

  MemoryIsolateExecutor(this.factory);

  @override
  Object execute(Object command) {
    if (command is! IsolateRequest) {
      return TomExecutor.noResult;
    }
    return _dispatch(command);
  }

  Future<IsolateResponse> _dispatch(IsolateRequest req) async {
    try {
      switch (req) {
        case PingRequest(:final hostMonotonicMs):
          return PongResponse(
            echoedHostMonotonicMs: hostMonotonicMs,
            isolateMonotonicMs: _monotonicMs(),
          );

        case OpenMemoryRequest(:final config):
          _memory ??= await factory();
          await _memory!.open(config);
          _open = true;
          return const OpenMemoryResponse();

        case CloseMemoryRequest():
          if (_open) {
            await _memory!.close();
            _open = false;
          }
          return const CloseMemoryResponse();

        case MemoryStatsRequest():
          final memory = _requireOpenMemory();
          final MemoryStats stats = await memory.stats();
          return MemoryStatsResponse(stats);

        default:
          return IsolateErrorResponse(
            exceptionType: 'UnknownIsolateRequest',
            message:
                'No dispatch handler for ${req.runtimeType}. '
                'Was the envelope added to the catalogue but not '
                'wired into MemoryIsolateExecutor?',
          );
      }
    } catch (e) {
      return IsolateErrorResponse(
        exceptionType: e.runtimeType.toString(),
        message: e.toString(),
      );
    }
  }

  TomBrainMemory _requireOpenMemory() {
    if (!_open || _memory == null) {
      throw StateError(
        'Memory is not open. Send OpenMemoryRequest before any '
        'other envelope.',
      );
    }
    return _memory!;
  }

  static int _monotonicMs() => DateTime.now().millisecondsSinceEpoch;
}
