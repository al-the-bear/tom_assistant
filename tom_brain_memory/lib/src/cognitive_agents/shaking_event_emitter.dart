// ShakingEventEmitter — the single well-defined seam through which
// a shaking event reaches memory's `events()` stream.
//
// Plan step A.69.
//
// What it owns:
//
//   * One `void Function(MemoryEvent)?` sink slot. The same sink the
//     `NodePersister`, `EdgeWriter`, `CentroidStore`, and
//     `RecallExecutor` write into for their own typed events; the
//     concrete `SqliteTomBrainMemory` will wire all of them to the
//     same `StreamController` that backs `TomBrainMemory.events()`.
//
//   * One public method, `raise(ShakingEvent event)`. It pushes
//     [event] onto the sink. A null sink (the test fixture that
//     doesn't care about events; the bootstrap path before the
//     `events()` stream is wired) is a silent no-op — the same
//     pass-through pattern the per-area event sinks already use.
//
// Why a dedicated helper rather than letting agents write to the sink
// directly:
//
//   * The four detection sites that memory owns internally (edge
//     writer, centroid store, recall executor) already construct
//     their own event sinks. Agents that raise `CritiqueRejected`
//     from the outside need a single, well-named seam to push events
//     through — `emitter.raise(CritiqueRejected(...))` reads as
//     intent, `sink(CritiqueRejected(...))` reads as plumbing.
//
//   * The future `TomBrainMemory.raiseShakingEvent(ShakingEvent)`
//     abstract method (deferred to the concrete-impl step — see
//     Q-A.69.4) will forward to this emitter. Establishing the
//     seam now means the abstract surface lands as a one-line
//     forward rather than as a fresh design.
//
//   * Test fixtures can construct a `ShakingEventEmitter` over a
//     list-backed sink and exercise the typed shaking shapes
//     without standing up the full memory store.
//
// What it does NOT own:
//
//   * It does not emit shaking events on its own initiative — every
//     emission is caller-driven. The "memory detects drift / conflict
//     / contradiction internally" cases run inside the relevant
//     writer / store / executor; they construct the typed event and
//     hand it to this emitter (or, equivalently, to their per-area
//     `MemoryEvent` sink — both paths converge on the same stream).
//
//   * It does not persist anything. Shaking events live on the event
//     stream only — they are not nodes, not edges, not trail
//     entries. Subscribers that want them durably recorded fold
//     them into a `Question` / `Conclusion` node themselves.

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryEvent;
import 'shaking_events.dart';

/// The well-defined seam through which a [ShakingEvent] reaches
/// memory's `events()` stream.
///
/// Construct once per open memory store; reuse for every shaking
/// raise. The emitter is stateless across calls and safe to share
/// between callers on a single memory store.
///
/// Production wires the [sink] to the `StreamController` that backs
/// `TomBrainMemory.events()`; tests pass a list-backed closure so
/// they can inspect the raised events directly.
final class ShakingEventEmitter {
  /// Optional sink — same shape as the per-area event sinks on
  /// `NodePersister`, `EdgeWriter`, `CentroidStore`, and
  /// `RecallExecutor`. A null sink is a silent no-op.
  final void Function(MemoryEvent)? _sink;

  /// Constructs an emitter over [sink]. Pass `null` (or omit) when
  /// no subscriber is wired — the [raise] method becomes a no-op.
  const ShakingEventEmitter({void Function(MemoryEvent)? sink}) : _sink = sink;

  /// Pushes [event] onto the sink. Silent no-op when no sink is wired.
  ///
  /// The method is synchronous because the sink is synchronous: the
  /// downstream `StreamController.add` (when the sink wires there)
  /// is itself a synchronous call into the broadcast stream's
  /// internal buffer. Subscribers that want to react asynchronously
  /// do so by listening to the stream, not by extending this call.
  void raise(ShakingEvent event) {
    _sink?.call(event);
  }
}
