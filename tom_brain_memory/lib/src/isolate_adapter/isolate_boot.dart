// MemoryWorkerContext — the `TomWorkerContext` subclass that
// boots a memory-hosting isolate (plan step A.79).
//
// Sendability:
//
//   This object crosses an isolate boundary as the argument to
//   `Isolate.spawn` inside `TomWorker.spawn`. Its only field
//   beyond the inherited ones is the [MemoryFactory] function
//   reference — sendable iff the function is top-level or static.
//   The `MemoryFactory` typedef docs spell that constraint out and
//   the tests in `a79_isolate_host_test.dart` exercise it with a
//   top-level function.
//
// Initialization order (inherited from `TomWorker.startRemoteIsolate`):
//
//   1. The spawned isolate sends its receive port back to the
//      creator (this happens before `initializeIsolate` is called).
//   2. `initializeIsolate()` runs here: register the executor on
//      `TomWorker.executors` so subsequent envelopes have a
//      dispatch target.
//   3. `_handleCommandsToIsolate` starts listening — the worker
//      signals `readyMessage` to the creator at this point.
//
// We deliberately do *not* construct the memory in
// `initializeIsolate()`. The factory is invoked lazily, on the
// first `OpenMemoryRequest`. Two reasons:
//
//   * The construction-then-open lifecycle matches the in-process
//     contract (`MemoryConfig` arrives at `open()`, not at
//     construction).
//   * Eager construction would force every test that just wants
//     to ping the isolate to also wire a real memory factory.

import 'dart:io';

import 'package:tom_basics/tom_basics.dart'
    show TomEnvironment, TomPlatform, tomLog;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomWorker, TomWorkerContext;

import '../observability/fanout_log_output.dart';
import 'isolate_executor.dart';
import 'memory_factory.dart';

/// The isolate-side boot context for a memory-hosting worker.
///
/// Created on the host side, sent across the boundary, executed
/// inside the spawned isolate. The host never references the
/// in-isolate executor directly — it sends envelopes through
/// `worker.executeCommand` and the executor (registered here)
/// picks them up.
final class MemoryWorkerContext extends TomWorkerContext {
  /// The factory the isolate's executor will call when an
  /// `OpenMemoryRequest` arrives.
  ///
  /// **Must** be a top-level or static function reference;
  /// closures captured in the spawning isolate cannot cross the
  /// boundary.
  final MemoryFactory factory;

  /// Trail-log root for this isolate's own `tomLog`
  /// (`tom_brain_logging.md` §5.1 / §10 step #3).
  ///
  /// The memory isolate runs a *separate* `tomLog` instance from the
  /// host, so the host's [FanoutLogOutput] file sink does not reach
  /// it. When non-null, [initializeIsolate] installs a
  /// [FanoutLogOutput] rooted here so the isolate's
  /// `tom_brain.memory.*` lines land in the same `brain.log` +
  /// `components/memory.log`. `null` leaves the isolate at its
  /// console default — the path tests that do not exercise the file
  /// sink take.
  final String? logRootPath;

  MemoryWorkerContext({
    required this.factory,
    required TomEnvironment tomEnvironment,
    required TomPlatform tomPlatform,
    List<String> args = const <String>[],
    String namePrefix = 'TomBrainMemory',
    this.logRootPath,
  }) : super(tomEnvironment, tomPlatform, args, namePrefix);

  @override
  Future<void> initializeIsolate() async {
    // Install the component file sink before the executor registers, so
    // anything this isolate logs from boot onward reaches the same trail
    // surface as the host (§5.1 / §10 step #3). `FanoutLogOutput` tees to a
    // fresh console sink, so the existing isolate-stdout routing is preserved
    // — installing it only *adds* files, it never removes the console path.
    if (logRootPath != null) {
      tomLog.logOutput = FanoutLogOutput(logRoot: Directory(logRootPath!));
    }
    // Register the executor on the per-isolate static list. The
    // executor holds the factory; the factory is invoked lazily
    // when the first `OpenMemoryRequest` arrives. Construction
    // is intentionally separated from opening (see file-level
    // doc above).
    TomWorker.executors.add(MemoryIsolateExecutor(factory));
  }
}
