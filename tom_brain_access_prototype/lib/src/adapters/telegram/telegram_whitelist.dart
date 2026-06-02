// Telegram user-id whitelist — the edge auth gate for the Telegram channel
// (E.22).
//
// What this file owns (Plan § Phase E, substep E.22; proto spec § 6.4 / § 8):
//
//   * `TelegramWhitelist` — the pure, immutable policy object holding the
//     configured set of allowed Telegram user ids. Its single question,
//     `isAllowed(senderId)`, is the Telegram half of the edge "Auth" check
//     (proto spec § 8; the OpenAI half is bearer-token auth, E.28). This is
//     the policy *primitive*, symmetric with the inbound mapper
//     (`TelegramInboundMapping`, E.20) and the outbound consolidator
//     (`TelegramOutboundConsolidator`, E.21): a pure value object the
//     adapter consults, with no I/O of its own.
//   * `telegramNotAuthorisedMessage` — the graceful plain-text reply a
//     non-whitelisted sender receives (proto spec § 6.4 / § 14
//     `access.auth.failed` → "graceful message (Telegram)").
//
// Where the enforcement lives: `TelegramAdapter.authorizedInboundRequests`
// (telegram_adapter.dart) consults this whitelist *before* a request can
// become an `Access`. A non-whitelisted sender is rejected at the edge —
// the adapter sends `telegramNotAuthorisedMessage` back and drops the
// request; no `InboundRequest` surfaces, and so no `Access` is ever built
// (AC-3, AC-4; proto spec § 8 "before an `Access` is constructed").
//
// Empty-whitelist semantics (Q-E.22.1): an empty whitelist allows **no
// one** — it is a closed default, the security-safe reading of "anything
// else is rejected" (plan E.22). Boot (E.41+) supplies the configured set
// from `AccessConfig` (proto spec § 13.1); a deployment that wants an open
// channel must configure it explicitly, never get it by forgetting to set
// a whitelist.
//
// Scope discipline (per-substep posture carried from E.20 / E.21). E.22 is
// the whitelist policy + the adapter gate, nothing downstream:
//
//   * NO rate limiting / quota / anchor pre-check. Those are the remaining
//     edge-security checks (E.29 – E.31), and they live in `edge_security/`.
//   * NO identity / session / persona resolution (E.24 – E.27): the
//     whitelist decides *whether* a sender may proceed, not *who* the
//     resulting principal is.
//   * NO `Access` construction or dispatcher wiring (boot, E.41+): the gate
//     emits the authorised `InboundRequest`s; boot turns each into an
//     `Access`.

/// The graceful reply sent to a sender who is not on the Telegram
/// whitelist (proto spec § 6.4 / § 14 `access.auth.failed`).
///
/// Plain text — no `parseMode`, no buttons (Stage-1, def § Q13). It does not
/// leak whether the user, the chat, or the bot configuration is at fault;
/// the edge simply declines.
const String telegramNotAuthorisedMessage =
    'Sorry, you are not authorised to use this assistant.';

/// The configured set of Telegram user ids permitted at the edge.
///
/// Immutable policy value object. The Telegram half of the edge "Auth"
/// check (proto spec § 8): [isAllowed] answers whether a given sender id is
/// on the whitelist. A non-whitelisted sender is rejected before an
/// `Access` is constructed (AC-3, AC-4) — see
/// `TelegramAdapter.authorizedInboundRequests`.
///
/// An **empty** whitelist allows no one (a closed default; Q-E.22.1). Boot
/// supplies the real set from configuration (proto spec § 13.1).
final class TelegramWhitelist {
  /// The allowed Telegram user ids. Copied defensively into an unmodifiable
  /// set so the policy cannot be mutated after construction.
  final Set<String> _allowedUserIds;

  /// Builds a whitelist permitting exactly [allowedUserIds].
  ///
  /// The ids are matched against `ChatMessage.sender.id` (the Telegram user
  /// id as a string) — an exact, case-sensitive match, as Telegram ids are
  /// opaque numeric strings.
  TelegramWhitelist(Iterable<String> allowedUserIds)
      : _allowedUserIds = Set<String>.unmodifiable(allowedUserIds);

  /// A whitelist that permits no one (the closed default; Q-E.22.1).
  ///
  /// Used as the adapter's default so an unconfigured deployment is closed,
  /// not open. Boot replaces it with the configured set. `const` so it can
  /// serve as the adapter's compile-time default argument.
  const TelegramWhitelist.empty() : _allowedUserIds = const <String>{};

  /// The allowed ids, as an unmodifiable view (for observability / config
  /// round-trips).
  Set<String> get allowedUserIds => _allowedUserIds;

  /// Whether [senderId] is permitted at the edge.
  ///
  /// `true` only when [senderId] is one of the configured [allowedUserIds];
  /// an empty whitelist returns `false` for every sender (Q-E.22.1).
  bool isAllowed(String senderId) => _allowedUserIds.contains(senderId);
}
