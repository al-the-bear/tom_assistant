// Barrel for the `time/` module (Plan step A.15).
//
// Module surface:
//
//   * `BrainTime`        — canonical UTC timestamp value type, stored as
//                          integer milliseconds and projecting both the
//                          ms-int and `DateTime` views on demand. Total
//                          ordering, plus/minus Duration, parse/format.
//   * `Clock`            — abstract injectable time source. Required for
//                          every component that reads "now"; no global
//                          / ambient clock exists.
//   * `SystemClock`      — production [Clock] backed by `DateTime.now()`.
//                          `const`-constructible.
//   * `FixedClock`       — test [Clock] returning a fixed instant.
//   * `MutableTestClock` — test [Clock] that advances under explicit
//                          control (`advance(Duration)` / `setTo(BrainTime)`).
//
// What is deliberately NOT here:
//
//   * No global / Zone-bound clock. Components are injected with a
//     [Clock] at construction; tests freeze time by passing the test
//     variants. This mirrors the `tom_brain_shared` rule that no global
//     I/O, no global LLM, no global store, no global logger exists at
//     this layer.
//   * No sub-millisecond resolution. Memory's storage and ULID's
//     timestamp prefix are millisecond-grained; sub-ms precision would
//     grow indexed columns without a consumer asking for it.
//   * No time-zone metadata. All [BrainTime] values are UTC by
//     construction. Local-time presentation belongs in the access layer.
//   * No monotonic-clock split. Wall-clock UTC is what the brain reads.
//     Code measuring "elapsed since start" (wall-clock budgets) uses
//     `Stopwatch` at the call site; mixing it into [Clock] would invite
//     confusion between "time of day" and "elapsed since start".

export 'brain_time.dart' show BrainTime;
export 'clock.dart' show Clock, FixedClock, MutableTestClock, SystemClock;
