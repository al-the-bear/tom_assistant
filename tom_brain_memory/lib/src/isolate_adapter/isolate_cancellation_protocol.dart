// Cancellation protocol for the isolate adapter (plan step A.81).
//
// Cancellation is a *protocol-level* concern at A.81: every long-running
// request envelope carries an optional `CancellationToken`; the in-isolate
// `CancellationRegistry` holds the cancelled-flag per token; the executor
// honors the flag at two well-defined checkpoints (before calling into
// the memory layer, after the call returns). True *mid-call* cancellation
// (interrupting an in-flight `memory.recall(...)` partway through)
// requires the memory layer's own methods to accept a cancellation
// token — that is a memory-API change owned by a later step.
//
// See Q-A.81.4 for the scope decision.
//
// Sendability:
//
//   `CancellationToken` is `int`-shaped (a single integer field) so it
//   crosses isolate boundaries trivially. The registry lives only inside
//   the executor's isolate; it never crosses.
//
// Lifecycle:
//
//   1. The client allocates a token (`CancellationTokenAllocator.next()`)
//      and includes it in a cancellable request envelope.
//   2. The executor reads the token from the envelope and registers it
//      with the in-isolate registry (`register(token)`) before invoking
//      the memory method.
//   3. If a `CancelRequest(token)` arrives on the dispatch channel, the
//      executor flips the registry's cancelled-flag for that token.
//   4. The executor checks the flag at the pre-call and post-call
//      checkpoints; on cancellation, it returns `CancellationException`
//      packed as `IsolateErrorResponse`.
//   5. Streaming requests check the flag between every chunk push.
//   6. The executor unregisters the token after the response is sent.
//
// The protocol carries the token through the envelope; the registry
// holds the state per token. Cancellation can be set before, during, or
// after the call — the executor honors whichever order it observes.

import 'isolate_messages.dart';

/// Opaque identifier for a cancellable request, sendable across an
/// isolate boundary.
///
/// Allocated by the client (`CancellationTokenAllocator`) and included
/// in the request envelope. The in-isolate `CancellationRegistry` keys
/// off the integer value; tokens are unique per host instance and not
/// recycled within a host lifetime.
///
/// The token is `int`-shaped (boxed) rather than a raw `int` so that
/// signatures stay readable (`recall(query, cancellation: token)` vs.
/// `recall(query, cancellation: 42)`) and so the host-side allocator
/// has a typed return value.
final class CancellationToken {
  /// Monotonic integer assigned by the client.
  final int id;

  const CancellationToken(this.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CancellationToken && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CancellationToken($id)';
}

/// Host-side counter that hands out unique [CancellationToken]s.
///
/// One allocator per `TomBrainMemoryIsolateClient`. Not thread-safe in
/// the cross-isolate sense (the allocator lives on the host side; each
/// allocation is on the host's isolate which is single-threaded by
/// definition).
final class CancellationTokenAllocator {
  int _next = 1;

  /// Returns a fresh [CancellationToken] and advances the counter.
  CancellationToken next() => CancellationToken(_next++);

  /// Visible for tests — returns the next id without advancing.
  int get peekNext => _next;
}

/// In-isolate registry of cancellation state per token.
///
/// One registry per `MemoryIsolateExecutor`. Tokens are registered on
/// envelope arrival, the cancelled-flag is flipped on `CancelRequest`
/// arrival, and the token is unregistered when the response is sent.
/// Unknown tokens (`register` not called, or already unregistered) are
/// silently no-op for `cancel(token)` — the protocol allows the cancel
/// to arrive *before* the open envelope or *after* the close, and we
/// treat both as benign (the future request will see the cancel; a
/// past request had nothing to cancel anyway).
///
/// **Late-cancel semantics**: when a `cancel(token)` arrives for a
/// token that has not yet been registered, the registry remembers the
/// cancellation in `_pendingCancellations` so the subsequent
/// `register(token)` sees the flag already raised. This handles the
/// natural race where the client sends `CancelRequest` immediately
/// after the open envelope, but the cancel arrives first because the
/// open envelope is still mid-dispatch.
final class CancellationRegistry {
  final Map<int, _RegistryEntry> _entries = <int, _RegistryEntry>{};
  final Set<int> _pendingCancellations = <int>{};

  /// Registers [token] as in-flight. The returned [_RegistryEntry] is
  /// the handle the executor uses to read [isCancelled] and to
  /// complete the registration.
  ///
  /// If the token has a pending cancel (a `CancelRequest` arrived
  /// before `register`), the returned entry is already cancelled.
  CancellationHandle register(CancellationToken token) {
    final wasPending = _pendingCancellations.remove(token.id);
    final entry = _RegistryEntry(cancelled: wasPending);
    _entries[token.id] = entry;
    return CancellationHandle._(token, entry, this);
  }

  /// Flips the cancelled-flag for [token].
  ///
  /// If the token is not yet registered, the cancellation is remembered
  /// so the eventual `register(token)` returns an already-cancelled
  /// handle.
  void cancel(CancellationToken token) {
    final entry = _entries[token.id];
    if (entry != null) {
      entry._cancelled = true;
    } else {
      _pendingCancellations.add(token.id);
    }
  }

  /// Whether [token] has been cancelled — independent of whether it is
  /// currently registered.
  bool isCancelled(CancellationToken token) {
    final entry = _entries[token.id];
    if (entry != null) return entry._cancelled;
    return _pendingCancellations.contains(token.id);
  }

  /// Number of currently registered (in-flight) tokens. Visible for
  /// tests.
  int get inFlightCount => _entries.length;

  /// Number of remembered pending cancellations. Visible for tests.
  int get pendingCancelCount => _pendingCancellations.length;

  void _unregister(int id) {
    _entries.remove(id);
  }
}

class _RegistryEntry {
  bool _cancelled;
  _RegistryEntry({required bool cancelled}) : _cancelled = cancelled;
}

/// Per-request cancellation handle returned by `register()`.
///
/// The executor reads [isCancelled] at the well-defined checkpoints
/// (before the memory call, between chunks for streams, after the
/// memory call). Calling [dispose] removes the registration; idempotent.
final class CancellationHandle {
  final CancellationToken token;
  final _RegistryEntry _entry;
  final CancellationRegistry _owner;
  bool _disposed = false;

  CancellationHandle._(this.token, this._entry, this._owner);

  /// Whether the request has been cancelled (either pre- or post-call).
  bool get isCancelled => _entry._cancelled;

  /// Throws [CancellationException] when cancelled. Convenience for
  /// pre-call and post-call checkpoints.
  void throwIfCancelled() {
    if (_entry._cancelled) {
      throw CancellationException(token);
    }
  }

  /// Unregister this handle. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner._unregister(token.id);
  }
}

/// Thrown by the executor when a cancellable request is cancelled at
/// (or after) a checkpoint. The host re-raises as an
/// `IsolateBoundaryException` with `exceptionType = 'CancellationException'`,
/// which the client translates back to this typed class for the caller.
final class CancellationException implements Exception {
  /// The token that was cancelled.
  final CancellationToken token;

  CancellationException(this.token);

  @override
  String toString() => 'CancellationException(token=${token.id})';
}

/// Cancellation envelope — flips the cancelled-flag for [token] inside
/// the in-isolate `CancellationRegistry`. Returned response is a
/// [CancelResponse] regardless of whether the token was known
/// (cancellation is best-effort by contract — see the registry doc).
final class CancelRequest extends IsolateRequest {
  final CancellationToken token;
  const CancelRequest(this.token);
}

/// Acknowledgement of a [CancelRequest]. The body is intentionally
/// empty — the cancellation is asynchronous and the in-flight request
/// will surface its own [CancellationException] when it next reaches a
/// checkpoint.
final class CancelResponse extends IsolateResponse {
  const CancelResponse();
}
