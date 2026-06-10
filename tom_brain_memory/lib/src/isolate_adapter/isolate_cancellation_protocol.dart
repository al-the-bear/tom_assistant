// Cancellation message envelopes for the memory isolate adapter
// (plan step A.81).
//
// The generic cancellation machinery — `IsolateCancellationToken`, its
// allocator, the in-isolate `IsolateCancellationRegistry`, the
// per-request `IsolateCancellationHandle`, and the typed
// `IsolateCancellationException` — was promoted to `tom_core_agentic`
// (`isolate_streaming/`) by Tom Brain completion-plan item 7. This file
// keeps only the two message envelopes that couple to the memory message
// catalogue (they extend `IsolateRequest` / `IsolateResponse`).
//
// Cancellation is a *protocol-level* concern at A.81: every long-running
// request envelope carries an optional `IsolateCancellationToken`; the
// in-isolate `IsolateCancellationRegistry` holds the cancelled-flag per
// token; the executor honors the flag at two well-defined checkpoints
// (before calling into the memory layer, after the call returns). True
// *mid-call* cancellation (interrupting an in-flight `memory.recall(...)`
// partway through) requires the memory layer's own methods to accept a
// cancellation token — that is a memory-API change owned by a later step.
//
// See Q-A.81.4 for the scope decision.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateCancellationToken;

import 'isolate_messages.dart';

/// Cancellation envelope — flips the cancelled-flag for [token] inside
/// the in-isolate `IsolateCancellationRegistry`. Returned response is a
/// [CancelResponse] regardless of whether the token was known
/// (cancellation is best-effort by contract — see the registry doc in
/// `tom_core_agentic`).
final class CancelRequest extends IsolateRequest {
  final IsolateCancellationToken token;
  const CancelRequest(this.token);
}

/// Acknowledgement of a [CancelRequest]. The body is intentionally
/// empty — the cancellation is asynchronous and the in-flight request
/// will surface its own `IsolateCancellationException` when it next
/// reaches a checkpoint.
final class CancelResponse extends IsolateResponse {
  const CancelResponse();
}
