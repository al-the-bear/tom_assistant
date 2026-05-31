// MemoryLog — category-tagged wrapper over `tomLog` (plan step A.84).
//
// Plan step A.84 (verbatim):
//   "Wire `TomLogger` from `tom_core_kernel`. Categories:
//    `tom_brain.memory.store`, `…retrieval`, `…stacks`, `…trail`,
//    `…mcp`, `…isolate`."
//
// What this file delivers:
//
//   - [MemoryLogCategory] — the closed enumeration of the six wiring
//     categories named in the plan, each carrying its canonical
//     `tom_brain.memory.<area>` string identifier. The enum is closed:
//     adding a category is a deliberate edit here, not a stringly-typed
//     accident at a call site.
//
//   - [MemoryLog] — a thin value type that pairs a category with the
//     standard log methods (`trace`, `debug`, `info`, `warn`, `status`,
//     `error`, `severe`, `fatal`). Each method prepends
//     `'[<category>] '` to the message and forwards to the global
//     `tomLog` instance from `tom_basics`.
//
//   - Six const instances (`MemoryLog.store`, `…retrieval`, `…stacks`,
//     `…trail`, `…mcp`, `…isolate`) so call sites read like
//     `MemoryLog.store.info(...)` with no allocation per call.
//
// Why a wrapper and not raw `tomLog`:
//
//   `TomLogger` itself has no first-class "category" concept. Its
//   per-class/method level overrides are inferred from stack-frame
//   analysis (`addNameLevel('SchemaMigrator', …)`), which is fine for
//   filtering individual classes but doesn't give us the operational
//   surface the plan asks for: six named groups whose emissions can
//   be inspected, filtered, or muted as a unit. Prepending a stable
//   `'[tom_brain.memory.<area>]'` tag at this layer:
//
//     * Lets operators grep for one area without depending on which
//       internal class produced the line.
//     * Lets tests assert "this lifecycle event emitted under the
//       expected category" without inspecting Dart's stack analysis.
//     * Keeps the package's public log surface deliberately small
//       (six instances) so a code reviewer can see at a glance which
//       module is logging something.
//
// Why `MemoryLog` is not a singleton service:
//
//   `tomLog` is already a singleton (the global instance). Wrapping
//   it in another singleton would add no value and would make tests
//   harder to drive (every test would have to reset the wrapper as
//   well as `tomLog.logOutput`). The wrapper is a `const` value type;
//   its only state is its category.
//
// Why lazy-evaluated messages are preserved:
//
//   `tomLog` honours the `() => String` pattern for expensive messages
//   (the function is only invoked when the level is enabled). Each
//   method below checks whether the supplied object is a `Function`
//   and, if so, wraps it so the category prefix is added lazily too —
//   otherwise we would defeat the lazy contract by stringifying the
//   message eagerly to attach the tag.
//
// Categories not on the plan's list:
//
//   The plan names six categories. Other internals (config loader,
//   cognitive agents, MCP write-forbidden, classification) do not yet
//   have a category — they keep using `tomLog` directly when they
//   need to log at all, which today is essentially never. New
//   categories should be added by extending [MemoryLogCategory] and
//   the corresponding `MemoryLog.<area>` instance below; ad-hoc
//   string categories are not supported on purpose.

import 'package:tom_basics/tom_basics.dart';

/// Closed enumeration of the six logging categories the
/// `tom_brain_memory` package emits under.
///
/// The `name` field carries the canonical string identifier used as
/// the log-line prefix. Adding a new category is a deliberate edit
/// of this enum and the matching [MemoryLog] static — there is no
/// way to construct an ad-hoc category from a string.
enum MemoryLogCategory {
  /// Storage stack: SQLite open/close, schema migrations, two-DB
  /// commit-log recovery, vec0 extension load.
  store('tom_brain.memory.store'),

  /// Recall executor: per-mode dispatch, RRF fusion, MMR diversify,
  /// optional re-rank, retrieval-conflict shaking events.
  retrieval('tom_brain.memory.retrieval'),

  /// Stack API: bootstrap stack installation, push/pop/list, demote
  /// policies, harvester hooks.
  stacks('tom_brain.memory.stacks'),

  /// Trail subsystem: trail open/append/close, JSONL writer, corruption
  /// recovery, trail event stream.
  trail('tom_brain.memory.trail'),

  /// MCP server: initialize handshake, tool calls, bearer-auth
  /// translation, write-forbidden refusals.
  mcp('tom_brain.memory.mcp'),

  /// Isolate adapter: host spawn / shutdown, worker boot, request /
  /// response routing, stream credit accounting, cancellation.
  isolate('tom_brain.memory.isolate');

  const MemoryLogCategory(this.name);

  /// Canonical string identifier for this category, used as the log
  /// prefix and as the operator-facing name (e.g. in filter rules).
  final String name;
}

/// A thin, category-tagged facade over the global [tomLog] instance.
///
/// Construct via the six const statics ([store], [retrieval], [stacks],
/// [trail], [mcp], [isolate]) — those are the only legal categories.
/// Each method prepends `'[<category>] '` to the message before
/// forwarding to the matching `tomLog` method, preserving the lazy
/// `() => String` contract.
class MemoryLog {
  /// The category this logger emits under. Read-only and final.
  final MemoryLogCategory category;

  /// Internal: constructs a logger for [category]. Not exposed; the
  /// six static instances below are the public surface.
  const MemoryLog._(this.category);

  /// Storage-stack logger. See [MemoryLogCategory.store].
  static const MemoryLog store = MemoryLog._(MemoryLogCategory.store);

  /// Retrieval-executor logger. See [MemoryLogCategory.retrieval].
  static const MemoryLog retrieval =
      MemoryLog._(MemoryLogCategory.retrieval);

  /// Stack-API logger. See [MemoryLogCategory.stacks].
  static const MemoryLog stacks = MemoryLog._(MemoryLogCategory.stacks);

  /// Trail-subsystem logger. See [MemoryLogCategory.trail].
  static const MemoryLog trail = MemoryLog._(MemoryLogCategory.trail);

  /// MCP-server logger. See [MemoryLogCategory.mcp].
  static const MemoryLog mcp = MemoryLog._(MemoryLogCategory.mcp);

  /// Isolate-adapter logger. See [MemoryLogCategory.isolate].
  static const MemoryLog isolate = MemoryLog._(MemoryLogCategory.isolate);

  /// All six loggers in the order they appear on
  /// [MemoryLogCategory.values]. Convenience for tests and for
  /// operator-facing tools that want to enumerate the surface.
  static const List<MemoryLog> all = <MemoryLog>[
    store,
    retrieval,
    stacks,
    trail,
    mcp,
    isolate,
  ];

  /// Most-verbose level. Use for entering / leaving inner methods and
  /// for argument dumps that would be too noisy at `debug`.
  void trace(Object message) => tomLog.trace(_tag(message));

  /// Detailed debugging information. Filtered out at production level.
  void debug(Object message) => tomLog.debug(_tag(message));

  /// Network / data-flow logging. Memory uses this for SQL statements
  /// that are noisy enough to warrant a separate level.
  void traffic(Object message) => tomLog.traffic(_tag(message));

  /// General runtime information.
  void info(Object message) => tomLog.info(_tag(message));

  /// Potentially problematic situation that did not prevent
  /// operation (e.g. fell back to default policy, missing optional
  /// extension).
  void warn(Object message) => tomLog.warn(_tag(message));

  /// Important lifecycle event — startup completion, schema migration
  /// applied, MCP server initialized, etc. Visible even under the
  /// `silent` level filter.
  void status(Object message) => tomLog.status(_tag(message));

  /// Error condition (recoverable). Use for failed-but-handled paths
  /// such as "trail JSONL line was corrupt, skipped".
  void error(Object message) => tomLog.error(_tag(message));

  /// Serious error that may require attention. Use for invariant
  /// violations the caller will need to act on.
  void severe(Object message) => tomLog.severe(_tag(message));

  /// Unrecoverable error. Use for paths that immediately precede an
  /// exit or a process-level failure.
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
  String toString() => 'MemoryLog(${category.name})';
}
