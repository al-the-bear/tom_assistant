// Cancellation primitive for substrate calls.
//
// `LlmCall.cancellationToken` (substrate_specification.md § 3.1) is the
// consumer-side seam through which a caller aborts an in-flight LLM
// call. The router and provider implementations check the token at
// every await point; on cancellation the provider abandons the HTTP
// response and the surface emits
// `LlmEvent.failed(CancelledByConsumer, ...)`.
//
// The primitive itself is domain-free, so it now lives in
// `tom_core_agentic` (prototype review B.1). This file re-exports the
// canonical types so the substrate's curated api/ surface — and every
// consumer that reaches them through `LlmCall.cancellationToken` —
// keeps a stable import path. There is exactly one definition; this is
// the surface, not a second copy.

export 'package:tom_core_agentic/tom_core_agentic.dart'
    show CancellationToken, CancellationTokenSource, OperationCancelled;
