// C.39 — RunCancellation control unit suite.
//
// Plan step C.39 (verbatim): "Implement cancellation and timeout on the
// handle." `RunCancellation` is the mechanism behind `ProcedureRun.cancel`
// and `invoke(..., timeout: …)`. These tests pin the control object itself,
// independent of the engine: how the signal fires, how the timeout arms and
// fires over an injectable timer, and how `dispose` disarms it so a late
// cancel is dropped. The engine-level wiring (a cancelled run closes
// `aborted` with a `run_cancelled` / `run_timed_out` note) is covered in
// `procedure_engine_test.dart` groups C.39-1..3.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  group('a fresh control with no timeout', () {
    test('is not signalled and has no timeout budget', () {
      final control = RunCancellation();
      expect(control.isSignalled, isFalse);
      expect(control.isCancelled, isFalse);
      expect(control.isTimedOut, isFalse);
      expect(control.timeout, isNull);
    });
  });

  group('cancel()', () {
    test('fires the signal with the cancelled cause', () async {
      final control = RunCancellation();

      final cause = control.signal;
      control.cancel();

      expect(await cause, RunCancelCause.cancelled);
      expect(control.isSignalled, isTrue);
      expect(control.isCancelled, isTrue);
      expect(control.isTimedOut, isFalse);
    });

    test('is idempotent — a second cancel does not re-complete the signal',
        () async {
      final control = RunCancellation();

      control.cancel();
      // A second cancel must not throw (it would if it re-completed the
      // already-completed signal Completer).
      control.cancel();

      expect(await control.signal, RunCancelCause.cancelled);
    });
  });

  group('timeout', () {
    test('rejects a non-positive budget', () {
      expect(
        () => RunCancellation(timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => RunCancellation(timeout: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('arms a timer over the injectable factory and fires timedOut',
        () async {
      _FakeTimer? scheduled;
      final control = RunCancellation(
        timeout: const Duration(seconds: 5),
        timerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          return scheduled!;
        },
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.duration, const Duration(seconds: 5));
      expect(control.isSignalled, isFalse);

      scheduled!.fire();

      expect(await control.signal, RunCancelCause.timedOut);
      expect(control.isTimedOut, isTrue);
      expect(control.isCancelled, isFalse);
      expect(control.timeout, const Duration(seconds: 5));
    });

    test('an explicit cancel before the timeout disarms the timer', () async {
      _FakeTimer? scheduled;
      final control = RunCancellation(
        timeout: const Duration(seconds: 5),
        timerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          return scheduled!;
        },
      );

      control.cancel();

      expect(await control.signal, RunCancelCause.cancelled);
      // The pending timeout timer was cancelled by the cancel.
      expect(scheduled!.isActive, isFalse);
    });
  });

  group('dispose()', () {
    test('disarms a pending timeout timer', () {
      _FakeTimer? scheduled;
      final control = RunCancellation(
        timeout: const Duration(seconds: 5),
        timerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          return scheduled!;
        },
      );

      control.dispose();

      expect(scheduled!.isActive, isFalse);
      expect(control.isSignalled, isFalse);
    });

    test('makes a later cancel a no-op — the signal stays pending', () async {
      final control = RunCancellation();

      control.dispose();
      control.cancel();

      expect(control.isSignalled, isFalse);
      expect(control.isCancelled, isFalse);
      // The signal never completes after dispose — race it against a short
      // delay sentinel so the test does not hang if that contract regresses.
      final winner = await Future.any<String>(<Future<String>>[
        control.signal.then((_) => 'signalled'),
        Future<String>.delayed(
          const Duration(milliseconds: 50),
          () => 'pending',
        ),
      ]);
      expect(winner, 'pending');
    });

    test('is idempotent', () {
      final control = RunCancellation();
      control.dispose();
      // A second dispose must not throw.
      control.dispose();
      expect(control.isSignalled, isFalse);
    });
  });
}

// ── A `Timer` test double ───────────────────────────────────────────
//
// Captures the scheduled timeout callback and fires it on demand so the
// `RunCancellation` timeout is driven deterministically (mirrors the
// step-deadline and engine suites).
final class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;

  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}
