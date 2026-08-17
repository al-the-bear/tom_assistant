// SubstrateWorkerContext — the `TomWorkerContext` subclass that boots a
// substrate-hosting isolate (Tom Brain completion-plan item #12).
//
// Sendability:
//
//   This object crosses an isolate boundary as the argument to
//   `Isolate.spawn` inside `TomWorker.spawn`. Its only field beyond the
//   inherited ones is the [SubstrateFactory] function reference —
//   sendable iff the function is top-level or static. The
//   `SubstrateFactory` typedef docs spell that constraint out.
//
// Initialization order (inherited from `TomWorker.startRemoteIsolate`):
//
//   1. The spawned isolate sends its receive port back to the creator.
//   2. `initializeIsolate()` runs here: build the client eagerly and
//      register the executor via `TomWorker.addExecutor`.
//   3. `_handleCommandsToIsolate` starts listening — the worker signals
//      ready to the creator.
//
// Unlike the memory boot context, the client is built **eagerly**:
// the substrate surface has no require-open gate (`complete` / `embed`
// work against a never-opened client), and the factory needs no config
// to construct, so deferring construction to a first `OpenSubstrateRequest`
// would buy nothing and would force every consumer to send an open
// envelope it does not otherwise need.

import 'package:tom_basics/tom_basics.dart' show TomEnvironment, TomPlatform;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomWorker, TomWorkerContext;

import 'substrate_factory.dart';
import 'substrate_isolate_executor.dart';

/// The isolate-side boot context for a substrate-hosting worker.
final class SubstrateWorkerContext extends TomWorkerContext {
  /// The factory the isolate calls once, during [initializeIsolate], to
  /// construct the held `TomBrainSubstrateClient`.
  ///
  /// **Must** be a top-level or static function reference; closures
  /// captured in the spawning isolate cannot cross the boundary.
  final SubstrateFactory factory;

  SubstrateWorkerContext({
    required this.factory,
    required TomEnvironment tomEnvironment,
    required TomPlatform tomPlatform,
    List<String> args = const <String>[],
    String namePrefix = 'TomBrainSubstrate',
  }) : super(tomEnvironment, tomPlatform, args, namePrefix);

  @override
  Future<void> initializeIsolate() async {
    final client = await factory();
    TomWorker.addExecutor(SubstrateIsolateExecutor(client));
  }
}
