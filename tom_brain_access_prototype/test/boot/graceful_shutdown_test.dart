// E.42 — graceful shutdown coordinator.
//
// Plan step E.42 (verbatim): "Implement graceful shutdown via `tom_basics`'
// signal handling: stop accepting new connections, drain in-flight foreground,
// close memory cleanly."
//
// `GracefulShutdown` bridges an OS termination signal to the async process
// teardown (in production `BootedBrain.shutdown`, which does the stop → drain →
// close-memory → close-substrate sequence). These tests drive the coordinator
// with synthetic signal streams (a `StreamController<ProcessSignal>`) and a
// recording terminator, so the whole sequence runs deterministically with no
// real signal and no real `exit`. What is proven:
//
//   1. The first signal runs the teardown to completion, *then* terminates,
//      with the clean exit code — the drain finishes before the process exits.
//   2. The teardown runs exactly once; a second signal mid-drain is ignored.
//   3. Both SIGINT and SIGTERM trigger it.
//   4. A teardown that throws still terminates, with the error exit code.
//   5. `dispose()` stops listening, so a post-dispose signal does nothing.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';

void main() {
  group('E.42 GracefulShutdown', () {
    test(
        'first signal runs the teardown to completion, then terminates with '
        'the clean exit code', () async {
      final signals = StreamController<ProcessSignal>.broadcast();
      final order = <String>[];
      final exitCodes = <int>[];

      final shutdown = GracefulShutdown.install(
        onShutdown: () async {
          order.add('shutdown.start');
          // A real teardown is async (drain + memory flush); model that with a
          // microtask hop so "terminate after completion" is a real assertion.
          await Future<void>.delayed(Duration.zero);
          order.add('shutdown.end');
        },
        signals: [signals.stream],
        terminate: (code) {
          order.add('terminate');
          exitCodes.add(code);
        },
      );
      addTearDown(shutdown.dispose);

      expect(shutdown.isTriggered, isFalse);
      signals.add(ProcessSignal.sigint);

      final code = await shutdown.completed;

      expect(shutdown.isTriggered, isTrue);
      expect(code, shutdownExitOk);
      expect(exitCodes, [shutdownExitOk]);
      // Terminate happens strictly after the teardown completes.
      expect(order, ['shutdown.start', 'shutdown.end', 'terminate']);
    });

    test('teardown runs exactly once; a second signal mid-drain is ignored',
        () async {
      final signals = StreamController<ProcessSignal>.broadcast();
      final gate = Completer<void>();
      var shutdownCalls = 0;
      var terminateCalls = 0;

      final shutdown = GracefulShutdown.install(
        onShutdown: () async {
          shutdownCalls++;
          await gate.future; // hold the drain open across the second signal
        },
        signals: [signals.stream],
        terminate: (_) => terminateCalls++,
      );
      addTearDown(shutdown.dispose);

      signals.add(ProcessSignal.sigint);
      await pumpEventQueue();
      // The drain is in flight; a second signal must not re-enter it.
      signals.add(ProcessSignal.sigterm);
      await pumpEventQueue();
      expect(shutdownCalls, 1);
      expect(terminateCalls, 0); // still draining

      gate.complete();
      await shutdown.completed;
      expect(shutdownCalls, 1);
      expect(terminateCalls, 1);
    });

    test('SIGTERM triggers the teardown just as SIGINT does', () async {
      final signals = StreamController<ProcessSignal>.broadcast();
      var shutdownCalls = 0;

      final shutdown = GracefulShutdown.install(
        onShutdown: () async => shutdownCalls++,
        signals: [signals.stream],
        terminate: (_) {},
      );
      addTearDown(shutdown.dispose);

      signals.add(ProcessSignal.sigterm);
      final code = await shutdown.completed;

      expect(code, shutdownExitOk);
      expect(shutdownCalls, 1);
    });

    test('multiple signal sources each feed the one coordinator', () async {
      final sigint = StreamController<ProcessSignal>.broadcast();
      final sigterm = StreamController<ProcessSignal>.broadcast();
      var shutdownCalls = 0;

      final shutdown = GracefulShutdown.install(
        onShutdown: () async => shutdownCalls++,
        signals: [sigint.stream, sigterm.stream],
        terminate: (_) {},
      );
      addTearDown(shutdown.dispose);

      // Fire on the second source; the coordinator listens to both.
      sigterm.add(ProcessSignal.sigterm);
      await shutdown.completed;
      // A late signal on the first source is ignored (already triggered).
      sigint.add(ProcessSignal.sigint);
      await pumpEventQueue();

      expect(shutdownCalls, 1);
    });

    test('a teardown that throws still terminates, with the error exit code',
        () async {
      final signals = StreamController<ProcessSignal>.broadcast();
      final exitCodes = <int>[];

      final shutdown = GracefulShutdown.install(
        onShutdown: () async => throw StateError('memory close failed'),
        signals: [signals.stream],
        terminate: exitCodes.add,
      );
      addTearDown(shutdown.dispose);

      signals.add(ProcessSignal.sigint);
      final code = await shutdown.completed;

      expect(code, shutdownExitError);
      expect(exitCodes, [shutdownExitError]);
    });

    test('dispose stops listening; a post-dispose signal does nothing',
        () async {
      final signals = StreamController<ProcessSignal>.broadcast();
      var shutdownCalls = 0;

      final shutdown = GracefulShutdown.install(
        onShutdown: () async => shutdownCalls++,
        signals: [signals.stream],
        terminate: (_) {},
      );

      await shutdown.dispose();
      signals.add(ProcessSignal.sigint);
      await pumpEventQueue();

      expect(shutdown.isTriggered, isFalse);
      expect(shutdownCalls, 0);
    });
  });
}
