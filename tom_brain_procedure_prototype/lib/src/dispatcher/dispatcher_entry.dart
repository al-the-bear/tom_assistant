// Dispatcher entry surface (Plan step D.14;
// `tom_brain_procedure_prototype_specification.md` § 10.1, PE-11).
//
// `Dispatcher.accept(Access)` is the *single* entry point into the
// dispatcher half. It consumes an `Access` object (envelope / identity /
// session / persona / `deliver`) and nothing else: the dispatcher never
// speaks a wire protocol, and every byte that returns to the originating
// channel goes through `Access.deliver`, never through this method's
// return value (which is therefore `Future<void>`).
//
// Scope of D.14. This step delivers the entry surface only — the front of
// the `accept → classify → select → schedule` pipeline (spec § 9 diagram).
// The stages behind it land in later steps:
//
//   - D.15 — the inbound classifier (kind-hint pass-through +
//     `classify_inbound_v1` fallback),
//   - D.16 — procedure selection (`user_prompt` → `answer_with_memory_v1`,
//     else `UnsupportedProcedureKind`),
//   - D.18+ — the `RunCoordinator` that actually schedules the run.
//
// Until those exist, the entry surface delegates the post-admission work
// to an injected [DispatchRoute]. That keeps `accept` a real, testable
// boundary today (a test fake supplies the route; the production wiring
// supplies the real classify→select→schedule chain) without the entry
// surface presuming the internal shape of the stages it precedes.
//
// The entry surface's own responsibility is narrow and stable across the
// later steps: admit the access, fire the entry observation (the
// `tom_brain.dispatcher.entry` hook the D.48 logger / D.49 event stream
// will drive), then hand the access to the route. Growth in D.15+ happens
// behind the route, not in this signature.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Access;

/// The classify → select → schedule pipeline the entry surface hands an
/// admitted [Access] to.
///
/// Returns when the access has been routed (queued, run, or rejected). The
/// answer never flows back through this return value — it reaches the
/// channel only through `Access.deliver`. A routing failure (e.g. the
/// D.16 `UnsupportedProcedureKind`) surfaces as a thrown error on the
/// returned future; the entry surface does not swallow it.
typedef DispatchRoute = Future<void> Function(Access access);

/// Observation hook fired the moment an [Access] is admitted, before it is
/// routed.
///
/// D.14 keeps this a plain callback so the entry surface is observable in
/// isolation; D.48 feeds a `TomLogger` (`tom_brain.dispatcher.entry`) and
/// D.49 a `DispatcherEvent` (`AccessAccepted`) through this exact seam. The
/// hook never reads the prompt body for its own purposes — it exists to
/// record that admission happened.
typedef DispatcherEntryObserver = void Function(Access access);

/// The single entry point into the dispatcher half (PE-11).
///
/// A Phase-E adapter constructs exactly one [Access] per inbound request
/// and calls [accept]. The dispatcher consumes a closed read-surface of
/// that object (`envelope`, `identity`, `session`, `persona`, `deliver`)
/// and routes it; it interprets no channel and writes no wire bytes.
final class Dispatcher {
  /// Builds the entry surface over a [route] (the classify → select →
  /// schedule chain) and an optional [onAccepted] observation hook.
  Dispatcher({
    required DispatchRoute route,
    DispatcherEntryObserver? onAccepted,
  })  : _route = route,
        _onAccepted = onAccepted;

  final DispatchRoute _route;
  final DispatcherEntryObserver? _onAccepted;

  /// Admits [access] and hands it to the routing pipeline.
  ///
  /// Order is fixed and observable: the entry observation ([onAccepted])
  /// fires first — admission is recorded before any routing work — then
  /// the access is handed to the route. The returned future completes
  /// only when routing completes; a routing error propagates to the
  /// caller unchanged.
  ///
  /// The return type is `Future<void>` by contract: the dispatcher's only
  /// outbound path is `Access.deliver`. `accept` never calls `deliver`
  /// itself — that is the engine's / `answer_with_memory_v1`'s job once
  /// the route reaches the answer step (D.38).
  Future<void> accept(Access access) async {
    _onAccepted?.call(access);
    await _route(access);
  }
}
