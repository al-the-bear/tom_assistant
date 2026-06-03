// Typed request/response envelopes exchanged between the in-process
// `TomBrainMemoryIsolateHost` and the in-isolate executor.
//
// A.79 ships the **skeleton** of the protocol:
//
//   * Sealed-style base classes (`IsolateRequest`, `IsolateResponse`).
//   * Lifecycle envelopes (`PingRequest` / `PongResponse`,
//     `OpenMemoryRequest` / `OpenMemoryResponse`,
//     `CloseMemoryRequest` / `CloseMemoryResponse`).
//   * One dispatch-proof pair (`MemoryStatsRequest` /
//     `MemoryStatsResponse`) that touches a real `TomBrainMemory`
//     method, so the boundary can be exercised end-to-end before
//     A.80 lands the consumer-facing `TomBrainMemoryIsolateClient`.
//   * A generic `IsolateErrorResponse` for boundary-side failures.
//
// A.81 expands this catalogue to one envelope per primary method
// on `TomBrainMemoryClient` (with cancellation tokens for `recall`
// and `stream`, and backpressure tokens for `readTrail`). The base
// class chosen here is the seam A.81 builds onto.
//
// Sendability contract:
//
//   Every envelope crosses an isolate boundary. Fields must be
//   sendable (primitives, `Map`/`List` of sendable values,
//   `Duration`, package-internal value types whose fields recursively
//   honour this rule). Closures, streams, and isolate-bound
//   resources are forbidden. The base classes are deliberately
//   abstract — adding a non-sendable field anywhere in the
//   hierarchy is a programmer error that surfaces only at the
//   `send` call site, so envelope authors must keep this contract
//   in mind. A future test (A.82) drives every envelope through a
//   real isolate to enforce the contract dynamically.

import '../api/memory_stats.dart';
import '../config/memory_config.dart';

/// Marker base for every request sent from the host to the isolate.
///
/// Subclasses are value-shaped (no behaviour beyond construction);
/// the executor inside the isolate switches on runtime type.
abstract class IsolateRequest {
  const IsolateRequest();
}

/// Marker base for every response sent from the isolate back to
/// the host. The host's `send<R>(...)` casts to the expected
/// concrete response type; an `IsolateErrorResponse` returned in
/// place of the expected type is the boundary's failure signal.
abstract class IsolateResponse {
  const IsolateResponse();
}

// ─── Lifecycle ───────────────────────────────────────────────────

/// Sanity-ping the isolate. Replies with a [PongResponse] that
/// echoes the host timestamp so a future latency probe can land
/// without a protocol change.
final class PingRequest extends IsolateRequest {
  /// The host's wall-clock millisecond reading at send time. The
  /// isolate echoes this value back unchanged so the host can
  /// compute round-trip latency without re-reading its own clock.
  ///
  /// Wall-clock, not monotonic: the round-trip is measured against
  /// the *same* host clock at send and receive (see
  /// `TomBrainMemoryIsolateHost.ping`), so a non-monotonic source is
  /// acceptable for the round-trip delta. It must not be used for
  /// cross-process duration arithmetic.
  final int hostWallClockMs;

  const PingRequest({required this.hostWallClockMs});
}

/// Reply to a [PingRequest].
final class PongResponse extends IsolateResponse {
  /// The value originally provided in [PingRequest.hostWallClockMs].
  final int echoedHostWallClockMs;

  /// The isolate's wall-clock millisecond reading at reply time.
  /// Sequencing observation: the isolate's clock is the same wall
  /// clock as the host's, so the difference is dominated by the
  /// message-pump latency.
  final int isolateWallClockMs;

  const PongResponse({
    required this.echoedHostWallClockMs,
    required this.isolateWallClockMs,
  });
}

/// Drive `memory.open(config)` inside the isolate.
///
/// Calling [OpenMemoryRequest] twice is treated as repeat-open
/// (the underlying API is idempotent per its contract); the second
/// reply is identical.
final class OpenMemoryRequest extends IsolateRequest {
  /// The fully-typed config to hand to `memory.open()`. Memory
  /// itself never parses YAML; the caller has already validated.
  final MemoryConfig config;

  const OpenMemoryRequest({required this.config});
}

/// Reply to a successful [OpenMemoryRequest].
final class OpenMemoryResponse extends IsolateResponse {
  const OpenMemoryResponse();
}

/// Drive `memory.close()` inside the isolate. The host calls this
/// before shutting down the worker so writes are flushed and the
/// WAL is checkpointed. Calling [CloseMemoryRequest] against an
/// already-closed memory is a no-op (matching the in-process
/// contract).
final class CloseMemoryRequest extends IsolateRequest {
  const CloseMemoryRequest();
}

/// Reply to a [CloseMemoryRequest].
final class CloseMemoryResponse extends IsolateResponse {
  const CloseMemoryResponse();
}

// ─── Dispatch proof (`stats()`) ──────────────────────────────────
//
// A.79 wires one real `TomBrainMemoryClient` method through the
// boundary so the executor's dispatch table is exercised by tests
// before A.81 ships the full catalogue. `stats()` was chosen
// because:
//
//   * It is read-only (no budget-charging, no idempotency-key
//     plumbing required).
//   * Its return type `MemoryStats` is composed entirely of
//     sendable primitives.
//   * The in-memory contract test already exercises the
//     `MemoryStats.empty` value (api_shape_test.dart), so the
//     envelope is regression-proof from day one.

/// Drive `memory.stats()` inside the isolate.
final class MemoryStatsRequest extends IsolateRequest {
  const MemoryStatsRequest();
}

/// Reply to a [MemoryStatsRequest], carrying the snapshot.
final class MemoryStatsResponse extends IsolateResponse {
  final MemoryStats stats;
  const MemoryStatsResponse(this.stats);
}

// ─── Failure ─────────────────────────────────────────────────────

/// Boundary-side failure marker.
///
/// Returned by the in-isolate executor when:
///
///   * No dispatch handler exists for the incoming envelope (the
///     envelope type was added to the catalogue but not wired into
///     the executor — a coding error this response makes visible).
///   * The handler threw — the message and runtime-type-name of
///     the original exception are preserved in [message] and
///     [exceptionType]; the host re-raises as an
///     [IsolateBoundaryException] so consumer code never sees an
///     untyped `Object?` return.
///
/// The original exception's stack trace is *not* preserved across
/// the boundary — Dart's send rules forbid `StackTrace` instances
/// from crossing isolate boundaries unchanged. The trail subsystem
/// will land an isolate-side stack capture mechanism at A.84 (the
/// `tom_brain.memory.isolate` logger category in the plan).
final class IsolateErrorResponse extends IsolateResponse {
  /// Human-readable message, taken from `exception.toString()`.
  final String message;

  /// Runtime type name of the original exception, as a string.
  /// Lets the consumer side translate well-known classes back into
  /// their typed counterparts (e.g. `BudgetExceededError`,
  /// `EdgeNotPermitted`). A.81 lands the typed translation table.
  final String exceptionType;

  const IsolateErrorResponse({
    required this.message,
    required this.exceptionType,
  });
}

/// Thrown by [TomBrainMemoryIsolateHost.send] when the in-isolate
/// executor returned an [IsolateErrorResponse]. Carries the same
/// payload as the response so consumers never have to do their own
/// `is IsolateErrorResponse` check.
///
/// Declared here (and not in a separate `exceptions.dart`) because
/// it is the host-side counterpart of [IsolateErrorResponse] and
/// the two move in lockstep when the error catalogue grows.
final class IsolateBoundaryException implements Exception {
  final String message;
  final String exceptionType;

  IsolateBoundaryException(this.message, this.exceptionType);

  @override
  String toString() => 'IsolateBoundaryException($exceptionType: $message)';
}
