// B.9 — Minimal cancellation primitive for substrate calls.
//
// `LlmCall.cancellationToken` (substrate_specification.md § 3.1) is
// the only consumer-side seam through which a caller can abort an
// in-flight LLM call. The router and provider implementations check
// the token at every await point; on cancellation the provider closes
// the HTTP connection and the surface emits
// `LlmStreamEvent.failed(CancelledByConsumer, ...)`.
//
// Why this lives in the api/ surface — and why it is intentionally
// minimal:
//
//   - `tom_basics` and `tom_core_kernel` do not (yet) ship a
//     cancellation primitive. Defining one in the substrate's api/
//     surface keeps the consumer-facing contract self-contained;
//     B.11+ (LLM providers) will consume the same type internally.
//   - The interface is deliberately the smallest surface that the
//     substrate needs: a `Future<void> get whenCancelled` for the
//     async-wait path and a `bool get isCancelled` for the
//     fast-check path. If a richer primitive lands in
//     `tom_brain_shared` later (Q-B.9.4), this file shrinks to a
//     re-export and the call-site contracts do not change.
//   - The concrete `CancellationTokenSource` lives next to the
//     interface so tests and the (future) router implementation can
//     produce tokens without depending on a private constructor.
//
// What this is NOT:
//
//   - Not a substitute for the larger procedure-level cancellation
//     story (`procedure_specification.md` § 13). The procedure
//     runtime cancels the procedure; the procedure relays
//     cancellation to the substrate by signalling the token it owns.
//   - Not a timer. A wall-clock budget is enforced separately by
//     the router; the token does not auto-fire on timeout. Compose
//     `CancellationTokenSource` with a `Timer` at the call site if
//     timeout-driven cancellation is wanted.

import 'dart:async';

/// Read-only side of a cancellation channel.
///
/// Consumers receive a token and either await [whenCancelled] (for
/// async paths that want to race cancellation against another
/// operation) or poll [isCancelled] (for synchronous fast-checks at
/// the start of a critical section).
///
/// A token never "un-cancels": once signalled it stays signalled and
/// [whenCancelled] resolves exactly once.
abstract class CancellationToken {
  /// `true` once the source has been cancelled.
  ///
  /// Cheap to call repeatedly — providers check it before issuing
  /// the next chunk of work.
  bool get isCancelled;

  /// Completes (with `void`) the first time the source is cancelled.
  ///
  /// Never throws. Awaiting an already-cancelled token returns
  /// immediately. Awaiting a never-cancelled token blocks until the
  /// source either cancels or is garbage-collected (callers are
  /// responsible for not holding onto a token whose source has been
  /// abandoned).
  Future<void> get whenCancelled;

  /// A token that is permanently uncancelled. Useful as a default
  /// when a caller does not need cancellation.
  static const CancellationToken none = _NeverCancelled();
}

/// Writable side of a cancellation channel.
///
/// Owners of a [CancellationTokenSource] hand the [token] to a
/// downstream call and call [cancel] when they want the downstream
/// work to stop. Calling [cancel] a second time is a no-op.
class CancellationTokenSource {
  final Completer<void> _completer = Completer<void>();
  late final _Token _token = _Token(_completer);

  /// The read-only token that observers hold.
  CancellationToken get token => _token;

  /// `true` once [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// Signals cancellation. Idempotent.
  void cancel() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }
}

class _Token implements CancellationToken {
  final Completer<void> _completer;
  const _Token(this._completer);

  @override
  bool get isCancelled => _completer.isCompleted;

  @override
  Future<void> get whenCancelled => _completer.future;
}

/// Thrown by an operation that was racing a [CancellationToken] when
/// the token signalled before the operation completed.
///
/// The underlying work (e.g. an in-flight HTTP POST) may still be
/// running — `package:http`'s standard `Client` has no per-request
/// abort handle — but its result is abandoned: the caller observes this
/// exception instead. Used by [OllamaLlmProvider.embedRaw] so a batch
/// that hit a failure on one input stops issuing / awaiting work on the
/// others cleanly rather than running every remaining call to
/// completion and discarding the results.
class OperationCancelled implements Exception {
  /// Optional human-readable label of the cancelled operation.
  final String? operation;

  const OperationCancelled([this.operation]);

  @override
  String toString() => operation == null
      ? 'OperationCancelled'
      : 'OperationCancelled($operation)';
}

class _NeverCancelled implements CancellationToken {
  const _NeverCancelled();

  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => _neverFuture;
}

// A future that never completes. Cached so `CancellationToken.none`
// does not allocate per call.
final Future<void> _neverFuture = Completer<void>().future;
