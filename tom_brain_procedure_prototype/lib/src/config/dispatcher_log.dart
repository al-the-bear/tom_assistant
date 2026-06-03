// DispatcherLog — category-tagged wrapper over `tomLog` (Plan step D.48).
//
// Plan step D.48 (verbatim):
//   "Wire `TomLogger`: categories `tom_brain.dispatcher.entry`,
//    `…coordinator`, `…fallback`, `…scheduler`, `…boot`."
//
// `tom_brain_procedure_prototype_specification.md` § 13 names the same
// five dispatcher categories (the engine half ships its own under
// `tom_brain.engine.*` via `EngineLog`, C.43; those are not this step's
// concern).
//
// What this file delivers:
//
//   - [DispatcherLogCategory] — the closed enumeration of the five
//     wiring categories named in the plan, each carrying its canonical
//     `tom_brain.dispatcher.<area>` string identifier. The enum is
//     closed: adding a category is a deliberate edit here, not a
//     stringly-typed accident at a call site.
//
//   - [DispatcherLog] — a thin value type that pairs a category with the
//     standard log methods (`trace`, `debug`, `traffic`, `info`, `warn`,
//     `status`, `error`, `severe`, `fatal`). Each method prepends
//     `'[<category>] '` to the message and forwards to the global
//     `tomLog` instance from `tom_basics`.
//
//   - Five const instances (`DispatcherLog.entry`, `…coordinator`,
//     `…fallback`, `…scheduler`, `…boot`) so call sites read like
//     `DispatcherLog.entry.info(...)` with no allocation per call.
//
// Why a wrapper and not raw `tomLog`:
//
//   This mirrors `EngineLog` (C.43), `MemoryLog` (A.84) and
//   `SubstrateLog` (B.37) exactly — the four Tom-Brain components share
//   one logging idiom so an operator reads
//   `[tom_brain.<component>.<area>]` uniformly across all of them.
//   `TomLogger` itself has no first-class "category" concept; prepending
//   a stable tag at this layer lets operators grep one area without
//   depending on which internal class produced the line, lets tests
//   assert categorisation without inspecting Dart's stack analysis, and
//   keeps the package's public log surface deliberately small.
//
// Why `DispatcherLog` is not a singleton service:
//
//   `tomLog` is already the global singleton. Wrapping it in another
//   singleton would add no value and make tests harder to drive. The
//   wrapper is a `const` value type; its only state is its category.
//
// Why lazy-evaluated messages are preserved:
//
//   `tomLog` honours the `() => String` pattern for expensive messages
//   (the function is only invoked when the level is enabled). Each method
//   below checks whether the supplied object is a `Function` and, if so,
//   wraps it so the category prefix is added lazily too — otherwise we
//   would defeat the lazy contract by stringifying eagerly to attach the
//   tag.
//
// Wiring status (Q-D.48.1):
//
//   D.48 ships the facade and exports it through the `config/` barrel,
//   following the C.43 precedent: the surface is the deliverable; call-site
//   emissions are added as the dispatcher lifecycle points they describe
//   acquire operator value. The dispatcher collaborators (`DispatcherEntry`,
//   `RunCoordinator`, `FallbackExecutor`, `FreeTimeScheduler`,
//   `BrainProcessBoot`) take their underlying knobs directly today; the
//   composition root is the first natural place to thread the logger
//   through (logged as Q-D.48.1).

import 'package:tom_core_agentic/tom_core_agentic.dart';

/// Closed enumeration of the five logging categories the
/// `tom_brain_procedure_prototype` dispatcher emits under.
///
/// The `name` field carries the canonical string identifier used as the
/// log-line prefix. Adding a new category is a deliberate edit of this
/// enum and the matching [DispatcherLog] static — there is no way to
/// construct an ad-hoc category from a string.
enum DispatcherLogCategory {
  /// Dispatcher entry surface (`DispatcherEntry`, inbound classifier):
  /// accepted access, classification outcome, procedure selection,
  /// foreground / background routing decisions.
  entry('tom_brain.dispatcher.entry'),

  /// Run coordinator (`RunCoordinator`, registry, preemption controller):
  /// foreground-slot occupancy, background preemption / resume, queue
  /// enqueue / drain, hard step-deadline truncation.
  coordinator('tom_brain.dispatcher.coordinator'),

  /// Fallback chain (`FallbackExecutor`, sustained-fallback monitor):
  /// fallback procedure tried, fallback exhausted, sustained-fallback
  /// alarm.
  fallback('tom_brain.dispatcher.fallback'),

  /// Free-time scheduler (`FreeTimeScheduler`): idle-window detection,
  /// background work submission, scheduler enabled / disabled state.
  scheduler('tom_brain.dispatcher.scheduler'),

  /// Process boot / shutdown (`BrainProcessBoot`, memory provisioning):
  /// substrate / memory / engine bring-up, startup phase transitions,
  /// drain + clean shutdown.
  boot('tom_brain.dispatcher.boot');

  const DispatcherLogCategory(this.name);

  /// Canonical string identifier for this category, used as the log
  /// prefix and as the operator-facing name (e.g. in filter rules).
  final String name;
}

/// A thin, category-tagged facade over the global [tomLog] instance.
///
/// Construct via the five const statics ([entry], [coordinator],
/// [fallback], [scheduler], [boot]) — those are the only legal
/// categories. Each method prepends `'[<category>] '` to the message
/// before forwarding to the matching `tomLog` method, preserving the lazy
/// `() => String` contract.
final class DispatcherLog extends CategoryLog {
  /// The category this logger emits under. Read-only and final.
  final DispatcherLogCategory category;

  /// Internal: constructs a logger for [category]. Not exposed; the five
  /// static instances below are the public surface.
  const DispatcherLog._(this.category);

  @override
  String get categoryName => category.name;

  /// Entry-surface logger. See [DispatcherLogCategory.entry].
  static const DispatcherLog entry =
      DispatcherLog._(DispatcherLogCategory.entry);

  /// Run-coordinator logger. See [DispatcherLogCategory.coordinator].
  static const DispatcherLog coordinator =
      DispatcherLog._(DispatcherLogCategory.coordinator);

  /// Fallback-chain logger. See [DispatcherLogCategory.fallback].
  static const DispatcherLog fallback =
      DispatcherLog._(DispatcherLogCategory.fallback);

  /// Free-time-scheduler logger. See [DispatcherLogCategory.scheduler].
  static const DispatcherLog scheduler =
      DispatcherLog._(DispatcherLogCategory.scheduler);

  /// Boot / shutdown logger. See [DispatcherLogCategory.boot].
  static const DispatcherLog boot = DispatcherLog._(DispatcherLogCategory.boot);

  /// All five loggers in the order they appear on
  /// [DispatcherLogCategory.values]. Convenience for tests and for
  /// operator-facing tools that want to enumerate the surface.
  static const List<DispatcherLog> all = <DispatcherLog>[
    entry,
    coordinator,
    fallback,
    scheduler,
    boot,
  ];

  @override
  String toString() => 'DispatcherLog(${category.name})';
}
