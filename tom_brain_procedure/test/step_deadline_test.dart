// C.36 — the hard per-step wall-clock deadline (`StepDeadline`).
//
// These tests pin the deadline mechanism in isolation, off the engine
// step-runner (C.38) and off real wall-clock time. A `_FakeTimer` captures
// the scheduled callback so the test fires the deadline on demand — no
// sleeping for the real 60 s limit, fully deterministic.
//
// Covered: the default limit is 60 s; a non-positive limit is rejected;
// `start` arms exactly one timer and rejects a second call; the timer fires
// → `isExpired` and the `expired` future complete; `cancel` disarms a
// still-running timer so it can no longer fire; and `guard` reports
// `StepCompleted` (step wins, timer cancelled), `StepTruncated` (deadline
// wins), propagates a step error, and drops a step result that arrives after
// truncation. The integrated truncated-step *trail entry* belongs to C.37.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// A `Timer` test double: records the scheduled [callback] and the
/// [duration], tracks cancellation, and fires only when the test calls
/// [fire]. Lets `StepDeadline` be driven deterministically.
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

  /// Fires the scheduled callback as the real timer would on expiry.
  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

void main() {
  group('StepDeadline construction', () {
    test('defaults to the 60 s wall-clock cap', () {
      expect(defaultStepDeadline, const Duration(seconds: 60));
      expect(StepDeadline().limit, const Duration(seconds: 60));
    });

    test('honours an explicit limit', () {
      final deadline = StepDeadline(limit: const Duration(milliseconds: 250));
      expect(deadline.limit, const Duration(milliseconds: 250));
    });

    test('rejects a zero or negative limit', () {
      expect(() => StepDeadline(limit: Duration.zero), throwsArgumentError);
      expect(
        () => StepDeadline(limit: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('exposes the well-known truncated-step note category', () {
      expect(stepTruncatedNoteCategory, 'step_truncated');
    });
  });

  group('StepDeadline arming', () {
    test('start arms a single timer for the limit', () {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        limit: const Duration(seconds: 5),
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      expect(deadline.isArmed, isFalse);
      deadline.start();

      expect(deadline.isArmed, isTrue);
      expect(deadline.isExpired, isFalse);
      expect(scheduled.duration, const Duration(seconds: 5));
      expect(scheduled.isActive, isTrue);
    });

    test('start rejects a second call', () {
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) => _FakeTimer(duration, onExpire),
      )..start();

      expect(deadline.start, throwsStateError);
    });

    test('firing the timer expires the deadline and completes expired', () {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      )..start();

      final expiry = expectLater(deadline.expired, completes);
      scheduled.fire();

      expect(deadline.isExpired, isTrue);
      expect(deadline.isArmed, isFalse);
      return expiry;
    });

    test('cancel disarms a still-running timer so it can no longer fire', () {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      )..start();

      deadline.cancel();
      expect(scheduled.isActive, isFalse);
      expect(deadline.isArmed, isFalse);

      // A late fire after cancel is a no-op (real cancelled timers never
      // fire; this guards the _fire guard if a stale callback slips through).
      scheduled.fire();
      expect(deadline.isExpired, isTrue);
    });
  });

  group('StepDeadline.guard', () {
    test('returns StepCompleted and cancels the timer when the step wins',
        () async {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      final outcome = await deadline.guard<int>(Future<int>.value(42));

      expect(outcome, isA<StepCompleted<int>>());
      expect((outcome as StepCompleted<int>).value, 42);
      expect(scheduled.isActive, isFalse);
      expect(deadline.isExpired, isFalse);
    });

    test('returns StepTruncated carrying the limit when the deadline wins',
        () async {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        limit: const Duration(seconds: 7),
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      // A step that never completes within the test.
      final never = Completer<int>();
      final guarded = deadline.guard<int>(never.future);

      scheduled.fire();
      final outcome = await guarded;

      expect(outcome, isA<StepTruncated<int>>());
      expect((outcome as StepTruncated<int>).limit, const Duration(seconds: 7));
      expect(deadline.isExpired, isTrue);
    });

    test('propagates a step error raised before the deadline', () async {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      await expectLater(
        deadline.guard<int>(Future<int>.error(StateError('boom'))),
        throwsA(isA<StateError>()),
      );
      // The error short-circuited the race; the timer was cancelled.
      expect(scheduled.isActive, isFalse);
    });

    test('drops a step result that arrives after truncation', () async {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      final late = Completer<int>();
      final guarded = deadline.guard<int>(late.future);

      // Deadline wins first.
      scheduled.fire();
      final outcome = await guarded;
      expect(outcome, isA<StepTruncated<int>>());

      // The abandoned step completes afterwards; the result is dropped and
      // no late completion of the already-resolved outcome occurs.
      late.complete(99);
      await pumpEventQueue();
      expect(outcome, isA<StepTruncated<int>>());
    });

    test('drops a step error that arrives after truncation', () async {
      late _FakeTimer scheduled;
      final deadline = StepDeadline(
        timerFactory: (duration, onExpire) =>
            scheduled = _FakeTimer(duration, onExpire),
      );

      final late = Completer<int>();
      final guarded = deadline.guard<int>(late.future);

      scheduled.fire();
      await guarded;

      // A late error on the abandoned step must not surface as an unhandled
      // async error (the onError branch swallows it once truncated).
      late.completeError(StateError('late boom'));
      await pumpEventQueue();
    });
  });
}
