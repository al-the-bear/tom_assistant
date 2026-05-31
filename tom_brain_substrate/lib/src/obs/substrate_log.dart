// SubstrateLog — category-tagged wrapper over `tomLog` (plan step B.37).
//
// Plan step B.37 (verbatim):
//   "Wire `TomLogger`: categories `tom_brain.substrate.llm`, `…roles`,
//    `…embed`, `…web`, `…mcp`."
//
// Spec § 10.1 (authoritative) lists the same five plus a sixth:
//
//   | Category                       | What lands here |
//   |--------------------------------|-----------------|
//   | `tom_brain.substrate.llm`      | Provider calls, retries, classification decisions. |
//   | `tom_brain.substrate.roles`    | Template assembly, anchor hash mismatches, schema rejections. |
//   | `tom_brain.substrate.embed`    | Embedding calls, batch fan-out, identity reports. |
//   | `tom_brain.substrate.web`      | Search, fetch, truncation, robots-decisions. |
//   | `tom_brain.substrate.mcp`      | Outbound MCP handshake, tool calls, reconnects. |
//   | `tom_brain.substrate.router`   | Route selection, cooldown transitions, failover. |
//
// The spec's `router` category is present because by B.18+ the router
// is a substantial subsystem with first-class lifecycle events
// (cooldown enter / exit, failover, role miss) that operators will
// want to filter on independently of the per-provider noise that
// fills `…llm`. Plan step B.37's text predates the B.18 / B.19 router
// surface and was not updated. Spec wins per the substrate
// development-rule pattern set at B.7 / B.34 / B.36 — see
// Q-B.37.1 in `prototype_implementation_questions.md` for the audit
// trail.
//
// What this file delivers:
//
//   - [SubstrateLogCategory] — the closed enumeration of the six wiring
//     categories named in spec § 10.1, each carrying its canonical
//     `tom_brain.substrate.<area>` string identifier. The enum is closed:
//     adding a category is a deliberate edit here, not a stringly-typed
//     accident at a call site.
//
//   - [SubstrateLog] — a thin value type that pairs a category with the
//     standard log methods (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`). Each method prepends
//     `'[<category>] '` to the message and forwards to the global
//     `tomLog` instance from `tom_basics`.
//
//   - Six const instances (`SubstrateLog.llm`, `…roles`, `…embed`,
//     `…web`, `…mcp`, `…router`) so call sites read like
//     `SubstrateLog.llm.info(...)` with no allocation per call.
//
// Why a wrapper and not raw `tomLog`:
//
//   `TomLogger` itself has no first-class "category" concept (it filters
//   on stack-frame-derived class names). Prepending a stable
//   `'[tom_brain.substrate.<area>]'` tag at this layer:
//
//     * Lets operators grep for one area without depending on which
//       internal class produced the line.
//     * Lets tests assert "this lifecycle event emitted under the
//       expected category" without inspecting Dart's stack analysis.
//     * Keeps the package's public log surface deliberately small (six
//       instances) so a code reviewer can see at a glance which module
//       is logging something.
//
// Mirrors `MemoryLog` (memory plan step A.84) exactly in shape — the
// same wrapper pattern, the same lazy-evaluation contract, the same
// closed-enum + const-statics surface. The two packages diverge only
// on the category list (memory has six store-flavoured categories;
// substrate has six provider-flavoured categories).
//
// Why `SubstrateLog` is not a singleton service:
//
//   `tomLog` is already a singleton (the global instance). Wrapping it
//   in another singleton would add no value and would make tests harder
//   to drive (every test would have to reset the wrapper as well as
//   `tomLog.logOutput`). The wrapper is a `const` value type; its only
//   state is its category.
//
// Why lazy-evaluated messages are preserved:
//
//   `tomLog` honours the `() => String` pattern for expensive messages
//   (the function is only invoked when the level is enabled). Each
//   method below checks whether the supplied object is a `Function` and,
//   if so, wraps it so the category prefix is added lazily too —
//   otherwise we would defeat the lazy contract by stringifying the
//   message eagerly to attach the tag.
//
// Categories not on the spec's list:
//
//   Spec § 10.1 names six categories. Other internals (config loader,
//   anchor registry, MCP-auth resolver) do not yet have a category —
//   they keep using `tomLog` directly when they need to log at all.
//   New categories should be added by extending [SubstrateLogCategory]
//   and the corresponding `SubstrateLog.<area>` instance below; ad-hoc
//   string categories are not supported on purpose.

import 'package:tom_basics/tom_basics.dart';

/// Closed enumeration of the six logging categories the
/// `tom_brain_substrate` package emits under.
///
/// The `name` field carries the canonical string identifier used as
/// the log-line prefix. Adding a new category is a deliberate edit
/// of this enum and the matching [SubstrateLog] static — there is no
/// way to construct an ad-hoc category from a string.
enum SubstrateLogCategory {
  /// LLM provider layer: provider calls, retries, failure
  /// classification decisions (spec § 10.1). The router's per-attempt
  /// log lines (`…router` below) link to the corresponding `…llm`
  /// line by call id.
  llm('tom_brain.substrate.llm'),

  /// Role registry and anchor assembly: template assembly, anchor
  /// hash mismatches, schema rejections (spec § 10.1).
  roles('tom_brain.substrate.roles'),

  /// Embedding service: per-call embeddings, batch fan-out
  /// concurrency, identity probe results (spec § 10.1).
  embed('tom_brain.substrate.embed'),

  /// Web tools: search, fetch, truncation, robots-decisions
  /// (spec § 10.1).
  web('tom_brain.substrate.web'),

  /// Outbound MCP client: handshake, tool calls, reconnects, auth
  /// failures (spec § 10.1).
  mcp('tom_brain.substrate.mcp'),

  /// Router lifecycle: route selection, cooldown transitions,
  /// failover (spec § 10.1). Not present in the older plan-step
  /// B.37 text — included per spec § 10.1, which is authoritative.
  /// See Q-B.37.1.
  router('tom_brain.substrate.router');

  const SubstrateLogCategory(this.name);

  /// Canonical string identifier for this category, used as the log
  /// prefix and as the operator-facing name (e.g. in filter rules).
  final String name;
}

/// A thin, category-tagged facade over the global [tomLog] instance.
///
/// Construct via the six const statics ([llm], [roles], [embed],
/// [web], [mcp], [router]) — those are the only legal categories.
/// Each method prepends `'[<category>] '` to the message before
/// forwarding to the matching `tomLog` method, preserving the lazy
/// `() => String` contract.
class SubstrateLog {
  /// The category this logger emits under. Read-only and final.
  final SubstrateLogCategory category;

  /// Internal: constructs a logger for [category]. Not exposed; the
  /// six static instances below are the public surface.
  const SubstrateLog._(this.category);

  /// LLM-provider logger. See [SubstrateLogCategory.llm].
  static const SubstrateLog llm = SubstrateLog._(SubstrateLogCategory.llm);

  /// Role-registry / anchor-assembly logger. See
  /// [SubstrateLogCategory.roles].
  static const SubstrateLog roles =
      SubstrateLog._(SubstrateLogCategory.roles);

  /// Embedding-service logger. See [SubstrateLogCategory.embed].
  static const SubstrateLog embed =
      SubstrateLog._(SubstrateLogCategory.embed);

  /// Web-tools logger. See [SubstrateLogCategory.web].
  static const SubstrateLog web = SubstrateLog._(SubstrateLogCategory.web);

  /// Outbound-MCP-client logger. See [SubstrateLogCategory.mcp].
  static const SubstrateLog mcp = SubstrateLog._(SubstrateLogCategory.mcp);

  /// Router-lifecycle logger. See [SubstrateLogCategory.router].
  static const SubstrateLog router =
      SubstrateLog._(SubstrateLogCategory.router);

  /// All six loggers in the order they appear on
  /// [SubstrateLogCategory.values]. Convenience for tests and for
  /// operator-facing tools that want to enumerate the surface.
  static const List<SubstrateLog> all = <SubstrateLog>[
    llm,
    roles,
    embed,
    web,
    mcp,
    router,
  ];

  /// Most-verbose level. Use for entering / leaving inner methods and
  /// for argument dumps that would be too noisy at `debug`.
  void trace(Object message) => tomLog.trace(_tag(message));

  /// Detailed debugging information. Filtered out at production level.
  void debug(Object message) => tomLog.debug(_tag(message));

  /// Network / data-flow logging. Substrate uses this for raw provider
  /// request / response bodies (when configured noisy enough).
  void traffic(Object message) => tomLog.traffic(_tag(message));

  /// General runtime information.
  void info(Object message) => tomLog.info(_tag(message));

  /// Potentially problematic situation that did not prevent operation
  /// (e.g. fell back to a secondary provider, embedding identity
  /// drifted from a previous boot).
  void warn(Object message) => tomLog.warn(_tag(message));

  /// Important lifecycle event — substrate open / close, MCP handshake
  /// completed, embedding identity probe passed. Visible even under
  /// the `silent` level filter.
  void status(Object message) => tomLog.status(_tag(message));

  /// Error condition (recoverable). Use for failed-but-handled paths
  /// such as "provider returned a malformed chunk; reclassifying as
  /// `provider_io`".
  void error(Object message) => tomLog.error(_tag(message));

  /// Serious error that may require attention. Use for invariant
  /// violations the caller will need to act on.
  void severe(Object message) => tomLog.severe(_tag(message));

  /// Unrecoverable error. Use for paths that immediately precede an
  /// exit or a process-level failure (e.g. `AnchorViolation`).
  void fatal(Object message) => tomLog.fatal(_tag(message));

  /// Prepends the category prefix to [message], preserving the
  /// `() => String` lazy-evaluation contract that `tomLog` supports.
  Object _tag(Object message) {
    if (message is String Function()) {
      return () => '[${category.name}] ${message()}';
    }
    if (message is Object Function()) {
      return () => '[${category.name}] ${message()}';
    }
    return '[${category.name}] $message';
  }

  @override
  String toString() => 'SubstrateLog(${category.name})';
}
