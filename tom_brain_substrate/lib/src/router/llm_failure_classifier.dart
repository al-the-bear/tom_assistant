// B.18 — `LlmFailureClassifier`.
//
// `substrate_specification.md` § 5.4 defines a closed taxonomy of LLM-call
// failure classes. The spec also says:
//
//   > Classification is centralised in `LlmFailureClassifier`. Provider
//   > implementations call it on every error response; they do not classify
//   > locally.
//
// The B.14 / B.15 providers ship with `classCode: 'unknown'` on every
// emitted `LlmFailure`, deferring to this step. B.18 keeps the deferral
// where it is — the router calls the classifier on the *caught* exception
// (or on the `LlmFailure` already attached to a `LlmStreamFailed.failure`)
// and re-labels it before deciding the next action. Providers continue to
// re-throw their wire exceptions; the classifier lives in `router/` and is
// only consumed by `LlmRouter`. That keeps the wire layer and the
// classification layer independently auditable.
//
// Why a separate file (not folded into `LlmRouter`):
//
//   - The taxonomy itself is data, not behaviour. A pure function from
//     (exception, optional body string) to `classCode` is testable without
//     constructing a router, without holding a clock, and without juggling
//     provider stubs.
//   - The router's responsibility is *action*, not classification. Splitting
//     the file makes "what does HTTP 429 mean?" answerable by reading 100
//     lines of code; the router file can then focus on "what does the
//     router do when classification yields `rate_limit`?".
//   - Spec § 5.4 calls out a "centralised" classifier — a single chokepoint
//     so adding a new error class is one change, not a survey across
//     providers.
//
// What this file does NOT do:
//
//   - It does not retry, cooldown, rotate, or wrap with [LlmFailure]. The
//     caller (the router) builds the [LlmFailure] envelope around the
//     classification result and decides the action via
//     [LlmFailureClass.routerAction].
//   - It does not interpret response bodies past a small set of substring
//     probes for `context`, `length`, `format`, `JSON`. Per spec § 5.4 the
//     400-class branch needs to distinguish "context overflow" (HTTP 400 +
//     context-length body) from "format" (HTTP 400 + format body); the
//     probe set is narrow and documented inline.
//   - It does not look at `LlmCallReport.notes` or `templateSha`. Those are
//     post-classification provenance; classification is body-only.

import 'dart:async' show TimeoutException;
import 'dart:io' show HandshakeException, SocketException, TlsException;

import '../api/llm_stream_event.dart' show LlmFailure;
import '../llm/wire_http_transport.dart' show WireHttpException;

/// Closed taxonomy of LLM-call failure classes (spec § 5.4).
///
/// Every enum value carries:
///
///   - [code] — the kebab-case discriminator written onto
///     [LlmFailure.classCode]. Identical to the spec's table.
///   - [routerAction] — what the router does on this class. Documented on
///     each enum value; the [LlmRouter] consumes it directly.
///
/// Adding a new class is a spec change (per spec § 1 invariant 6 "failover
/// classification is fixed"). The classifier returns `LlmFailureClass.unknown`
/// for anything that does not match a documented probe; the router treats
/// `unknown` as `overloaded`-for-routing per the spec's table footer.
enum LlmFailureClass {
  /// HTTP 429. Cooldown the credential, rotate to the next route entry.
  rateLimit('rate_limit', LlmRouterAction.cooldownAndRotate),

  /// HTTP 503. Short jittered backoff, retry on the same route N times
  /// before rotating. At B.18 the retry count is configurable on
  /// [LlmRouter] (default 1).
  overloaded('overloaded', LlmRouterAction.retryThenRotate),

  /// HTTP 402 / payment-required body. Long cooldown (24 h default),
  /// rotate.
  billing('billing', LlmRouterAction.cooldownAndRotate),

  /// Wall-clock cutoff hit (TimeoutException from the underlying
  /// transport, or the router's per-call timeout). Retry once with
  /// extended timeout, rotate on second timeout.
  timeout('timeout', LlmRouterAction.retryThenRotate),

  /// HTTP 401. OAuth is not supported in v1; treat as `authPermanent`
  /// per spec § 5.4. The classifier returns `auth` for visibility; the
  /// router maps it onto the `authPermanent` action.
  auth('auth', LlmRouterAction.removeCredential),

  /// HTTP 403. Remove credential from the route chain until
  /// reconfigured. Modelled as an effectively-permanent cooldown.
  authPermanent('auth_permanent', LlmRouterAction.removeCredential),

  /// HTTP 404 + model id in body. Drop `(provider, model)` from this
  /// session's chain. Modelled as a permanent cooldown keyed on
  /// `<providerId>:<modelId>`.
  modelNotFound('model_not_found', LlmRouterAction.removeRoute),

  /// HTTP 400 + context-length body. Surface to caller — the caller (a
  /// procedure / dispatcher) decides whether to compact and retry.
  /// Substrate does not silently truncate role prompts.
  contextOverflow('context_overflow', LlmRouterAction.surfaceToCaller),

  /// HTTP 400 + format body. Re-emit with the strict-format adapter
  /// (`StrictFormatAdapter`) for a single retry, then rotate. Distinct
  /// from `retryThenRotate` because the prompt is *adapted* (a strict-
  /// format reinforcement block is appended) before the re-emit and the
  /// retry budget is fixed at one, independent of
  /// `RouterPolicy.retriesPerClass`. Landed at B.43 (Q-B.43.2).
  format('format', LlmRouterAction.reformatThenRotate),

  /// DNS, connection-refused, TLS. Single retry, rotate on second
  /// failure.
  network('network', LlmRouterAction.retryThenRotate),

  /// Consumer cancelled the call. Propagate cancellation; no rotate.
  cancelledByConsumer(
    'cancelled_by_consumer',
    LlmRouterAction.surfaceToCaller,
  ),

  /// Any error the classifier did not recognise. Per spec § 5.4 footer,
  /// the router treats this as `overloaded`-for-routing (retry once,
  /// rotate).
  unknown('unknown', LlmRouterAction.retryThenRotate);

  /// Kebab-case discriminator written onto [LlmFailure.classCode].
  final String code;

  /// What the router does on this class.
  final LlmRouterAction routerAction;

  const LlmFailureClass(this.code, this.routerAction);

  /// Lookup by [code]. Returns `null` for unknown codes; the router uses
  /// this to honour a `LlmFailure.classCode` that a provider supplied
  /// directly (e.g. the stub's `cancelled_by_consumer` synth) without
  /// re-classifying.
  static LlmFailureClass? fromCode(String code) {
    for (final cls in LlmFailureClass.values) {
      if (cls.code == code) return cls;
    }
    return null;
  }
}

/// Routing decision attached to a [LlmFailureClass].
///
/// The router consumes the action; the action is a small enum so the
/// router's failure-handling can be a single `switch` with analyzer-enforced
/// exhaustiveness.
enum LlmRouterAction {
  /// Park the current route under a per-class cooldown window, then try
  /// the next route entry. Used for `rateLimit` and `billing`.
  cooldownAndRotate,

  /// Retry the current route up to [LlmRouter.retriesPerClass] times;
  /// rotate to the next entry after the retry budget is exhausted. Used
  /// for `overloaded`, `timeout`, `network`, `unknown`.
  retryThenRotate,

  /// Re-emit the prompt once through `StrictFormatAdapter` (appending a
  /// strict-format reinforcement block), then rotate if the adapted
  /// re-emit also fails. Used only for `format`. The retry budget is
  /// fixed at one (the spec's "single retry"), independent of
  /// [LlmRouter.retriesPerClass]; the route carries no cooldown on
  /// rotation (a format failure is prompt-related, not credential-
  /// related, so the route stays dispatchable).
  reformatThenRotate,

  /// Remove the credential for the current route from the session for an
  /// effectively-permanent cooldown. Used for `auth` and `authPermanent`.
  removeCredential,

  /// Remove the `(providerId, modelId)` pair from the session. Used for
  /// `modelNotFound`.
  removeRoute,

  /// Surface the failure to the caller without rotating. Used for
  /// `contextOverflow` (caller decides compaction) and
  /// `cancelledByConsumer` (caller already aborted).
  surfaceToCaller,
}

/// Maps caught exceptions and provider-supplied [LlmFailure] envelopes
/// into the closed taxonomy.
///
/// Stateless — every method is pure. Construct once at substrate
/// `open()` (or use [LlmFailureClassifier.shared]) and inject into
/// [LlmRouter].
class LlmFailureClassifier {
  /// Shared instance. The classifier is stateless and trivially shareable.
  static const LlmFailureClassifier shared = LlmFailureClassifier();

  const LlmFailureClassifier();

  /// Classify a caught [exception]. Returns the matching class.
  ///
  /// If the exception is a [LlmFailure] whose `classCode` already
  /// matches a known [LlmFailureClass.code], that class is returned
  /// verbatim — the router honours provider-supplied classifications
  /// when they are already in the closed taxonomy.
  LlmFailureClass classify(Object exception) {
    if (exception is LlmFailure) {
      final preserved = LlmFailureClass.fromCode(exception.classCode);
      // `unknown` is the provider's "I did not classify" sentinel — every
      // B.14 / B.15 provider stamps it on caught exceptions before
      // re-throwing. Treat it as a request for router-side classification,
      // not as a definitive answer. Every other taxonomy code is
      // preserved verbatim (e.g. the stub's deliberate
      // `cancelled_by_consumer`, or a future provider that maps its own
      // 429 directly).
      if (preserved != null && preserved != LlmFailureClass.unknown) {
        return preserved;
      }
      return classify(exception.cause ?? Exception(exception.message));
    }
    if (exception is WireHttpException) {
      // Both backend-family subtypes (`OllamaHttpException` /
      // `OpenAiHttpException`) map identically — status + body decide
      // the class, not which wire layer threw.
      return _fromStatus(exception.statusCode, exception.body);
    }
    if (exception is TimeoutException) return LlmFailureClass.timeout;
    if (exception is SocketException) return LlmFailureClass.network;
    if (exception is HandshakeException) return LlmFailureClass.network;
    if (exception is TlsException) return LlmFailureClass.network;
    return LlmFailureClass.unknown;
  }

  /// Wrap [exception] into a typed [LlmFailure] with the resolved
  /// `classCode`. Used by the router to re-label provider exceptions
  /// before re-throwing or re-emitting.
  LlmFailure wrap(Object exception, {String? messageOverride}) {
    final cls = classify(exception);
    return LlmFailure(
      classCode: cls.code,
      message: messageOverride ?? exception.toString(),
      cause: exception,
    );
  }

  /// Map an HTTP status + response body into a [LlmFailureClass].
  ///
  /// The body probes are deliberately narrow — they only fire for the
  /// 400-class branch where the spec requires distinguishing
  /// `context_overflow` from `format`, and for the 402 / 503 branches
  /// where the body confirms the status code's intent without
  /// ambiguity.
  LlmFailureClass _fromStatus(int statusCode, String body) {
    switch (statusCode) {
      case 400:
        final lower = body.toLowerCase();
        if (lower.contains('context') ||
            lower.contains('maximum context length') ||
            lower.contains('token limit')) {
          return LlmFailureClass.contextOverflow;
        }
        if (lower.contains('format') ||
            lower.contains('json') ||
            lower.contains('schema')) {
          return LlmFailureClass.format;
        }
        return LlmFailureClass.unknown;
      case 401:
        return LlmFailureClass.auth;
      case 402:
        return LlmFailureClass.billing;
      case 403:
        return LlmFailureClass.authPermanent;
      case 404:
        return LlmFailureClass.modelNotFound;
      case 408:
        return LlmFailureClass.timeout;
      case 413:
        return LlmFailureClass.contextOverflow;
      case 429:
        return LlmFailureClass.rateLimit;
      case 503:
        return LlmFailureClass.overloaded;
      case 504:
        return LlmFailureClass.timeout;
      default:
        if (statusCode >= 500 && statusCode < 600) {
          return LlmFailureClass.overloaded;
        }
        return LlmFailureClass.unknown;
    }
  }
}
