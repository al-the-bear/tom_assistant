// `Clock` — injectable time source for Tom Brain (Plan step A.15).
//
// The brain reads "now" in many places: ID generation, event timestamps,
// trail entries, stack ordering, deadline checks, dream-cycle pacing.
// Every one of those reads must go through this interface so tests can
// freeze and advance time without monkey-patching `DateTime.now`.
//
// What this module does NOT do:
//
//   * It does NOT expose a global / ambient clock. There is no
//     `Clock.system` static getter and no `currentClock` Zone variable.
//     Components receive their `Clock` by constructor injection. This is
//     the same rule the rest of `tom_brain_shared` follows for every
//     resource (no global LLM, no global store, no global logger) and is
//     the reason testability is structural, not configurable.
//   * It does NOT define wall-vs-monotonic split. Wall-clock UTC `DateTime`
//     is the only time the brain reads. Monotonic durations (e.g. for
//     wall-clock budgets) come from `Stopwatch` at the call site; mixing
//     them into [Clock] would invite consumers to confuse "time of day"
//     with "elapsed since start".
//   * It does NOT carry a time zone. All `now()` results are UTC. Local-
//     time presentation is a UI concern that belongs in the access layer.
//
// Production code uses [SystemClock]. Tests use [FixedClock] for a
// non-moving instant or [MutableTestClock] when the test needs to advance
// time explicitly.

import 'brain_time.dart';

/// Abstract source of "now" for any Tom Brain component.
///
/// Implementations must return UTC instants from [now] and matching
/// millisecond values from [nowMs]. The two getters must agree: for any
/// implementation `c`, `c.now().millisecondsSinceEpoch == c.nowMs()` must
/// hold when read in the same logical instant. The [SystemClock] reads the
/// wall clock once per call and therefore may drift between the two
/// getters across calls — that drift is acceptable (it is the same drift
/// any other reader of `DateTime.now()` sees) but consumers that need
/// agreement should read [nowBrainTime] which is atomic by construction.
abstract interface class Clock {
  /// Current UTC wall-clock time as a `DateTime`.
  ///
  /// Implementations MUST return UTC. [BrainTime.now] asserts this on the
  /// way through; tests should also rely on the assertion to catch local-
  /// time clocks slipping in.
  DateTime now();

  /// Current wall-clock time as integer milliseconds since the Unix epoch.
  ///
  /// Equivalent to `now().millisecondsSinceEpoch` but exposed separately so
  /// callers that only need the integer form (SQLite-indexed columns,
  /// ULID timestamp, monotonic-order keys) don't allocate a `DateTime`
  /// just to throw it away.
  int nowMs();

  /// Current time as a [BrainTime].
  ///
  /// The atomic form: a single read produces both the millisecond value
  /// and the `DateTime` view derived from it without any chance of drift
  /// between the two. Components that need both should prefer this over
  /// calling [now] and [nowMs] separately.
  ///
  /// Note: because `Clock` is an `abstract interface class`, every concrete
  /// implementer reaches this method via `implements` and therefore must
  /// supply its own override. The default body is kept as a readable
  /// reference implementation but is structurally never invoked at runtime;
  /// the coverage tool flags it as uncovered by design.
  // coverage:ignore-start
  BrainTime nowBrainTime() => BrainTime.fromMs(nowMs());
  // coverage:ignore-end
}

/// Production [Clock] backed by `DateTime.now()`.
///
/// Stateless and `const`-constructible so callers can write
/// `const SystemClock()` at injection sites without ceremony.
final class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  // Override the default [Clock.nowBrainTime] to make the atomic guarantee
  // explicit: a single `DateTime.now()` read drives both fields, so the
  // ms-int and the wrapped DateTime view cannot disagree even across the
  // jiffy boundary.
  @override
  BrainTime nowBrainTime() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    return BrainTime.fromMs(ms);
  }
}

/// Test [Clock] that always returns the same instant.
///
/// Construct with a [BrainTime]; every call to [now] / [nowMs] /
/// [nowBrainTime] returns that fixed value. Suitable for tests where the
/// passage of time should not matter and reproducing identical IDs and
/// timestamps across runs is desirable.
///
/// For tests that need to advance time, use [MutableTestClock] instead.
final class FixedClock implements Clock {
  final BrainTime _at;

  /// Creates a clock that always returns [at].
  const FixedClock(BrainTime at) : _at = at;

  @override
  DateTime now() => _at.toDateTime();

  @override
  int nowMs() => _at.toMs();

  @override
  BrainTime nowBrainTime() => _at;
}

/// Test [Clock] that can be advanced manually.
///
/// Backed by a mutable [BrainTime] field. Tests call [advance] to move
/// time forward by a [Duration], or [setTo] to jump to a specific
/// instant.
///
/// Time only moves under explicit control: every call to [now] / [nowMs] /
/// [nowBrainTime] returns the *current* fixed value until [advance] or
/// [setTo] is called. This is the only place in the codebase where time
/// is allowed to be mutable state, and even here it is gated by an
/// explicit method call — never an implicit "real time" leak.
final class MutableTestClock implements Clock {
  BrainTime _at;

  /// Creates a clock starting at [at].
  MutableTestClock(BrainTime at) : _at = at;

  /// The currently-set instant. Reading this getter does not advance time.
  BrainTime get currentTime => _at;

  /// Advances the clock by [delta].
  ///
  /// [delta] must be non-negative — time does not run backwards in the
  /// brain. If a test needs to jump backwards (e.g. simulating a recovered
  /// older event), use [setTo] explicitly so the intent is visible at the
  /// call site.
  void advance(Duration delta) {
    if (delta.isNegative) {
      throw ArgumentError.value(
        delta,
        'delta',
        'advance(delta) requires a non-negative duration; '
            'use setTo() to jump backwards explicitly',
      );
    }
    _at = _at.plus(delta);
  }

  /// Sets the clock to [at]. Backwards jumps are permitted but visible.
  void setTo(BrainTime at) {
    _at = at;
  }

  @override
  DateTime now() => _at.toDateTime();

  @override
  int nowMs() => _at.toMs();

  @override
  BrainTime nowBrainTime() => _at;
}
