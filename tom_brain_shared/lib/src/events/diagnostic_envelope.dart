// `DiagnosticEnvelope` — transport wrapper around a [BrainEvent]
// (Plan step A.14).
//
// The envelope carries the cross-process diagnostic metadata that is *not*
// part of the domain event itself: who emitted it ([source]), where it
// sits in the local emission order ([sequence]), how severe it is
// ([severity]), and arbitrary opaque key/value tags for downstream
// filtering ([tags]).
//
// Why separate from `BrainEvent`:
//
//   * `BrainEvent` is the domain object — its fields are what the *brain*
//     cares about (`occurredAt`, `runId`, `causedBy`, subclass payload).
//   * `DiagnosticEnvelope` is the *transport* object — its fields are what
//     the *operator* cares about (which component, in what order, how
//     loud, tagged how). Mixing the two would force every event subclass
//     to carry transport metadata, which is wrong: events emitted in-
//     process do not need a sequence number; events transmitted across
//     the isolate boundary do.
//   * The envelope is the unit a stream consumer reads. The event is the
//     unit a stream consumer dispatches on.
//
// Generic over the event type. Consumers that observe only a single
// subclass family can keep the static type narrow:
//
// ```dart
// Stream<DiagnosticEnvelope<MemoryEvent>> events = memory.diagnosticStream();
// ```
//
// While consumers that observe all events use the upper bound:
//
// ```dart
// Stream<DiagnosticEnvelope<BrainEvent>> all = brain.allDiagnostics();
// ```

import 'brain_event.dart';
import 'diagnostic_severity.dart';

/// Transport wrapper around a [BrainEvent] carrying cross-process
/// diagnostic metadata.
///
/// Generic over the event type so a consumer can statically narrow to a
/// specific subclass family (e.g. `DiagnosticEnvelope<MemoryEvent>`)
/// without losing the envelope contract.
///
/// The envelope is immutable. The [tags] map is stored as-is; the
/// constructor wraps it in an unmodifiable view on access via [tags] so
/// callers cannot smuggle in a mutation after construction. Pass
/// `const {}` (the default) for envelopes without tags.
final class DiagnosticEnvelope<E extends BrainEvent> {
  /// The wrapped domain event.
  final E event;

  /// Component identifier of the emitter.
  ///
  /// Convention: the Tom Brain component name — `tom_brain_memory`,
  /// `tom_brain_substrate`, `tom_brain_procedure_engine`,
  /// `tom_brain_procedure_dispatcher`, `tom_brain_access`. Free-form
  /// strings are accepted because Forge tooling and future external
  /// emitters will plug in their own identities.
  final String source;

  /// Monotonically increasing per-source emission sequence number.
  ///
  /// Allows downstream consumers to detect gaps (a missed event implies a
  /// dropped envelope on a buffered transport). Per-source means each
  /// emitter maintains its own counter; correlate across sources via
  /// `event.runId` / `event.causedBy`, not sequence.
  ///
  /// Negative values are rejected at construction.
  final int sequence;

  /// Operator-facing severity for filtering and routing.
  ///
  /// Defaults to [DiagnosticSeverity.info]. The domain event itself does
  /// not declare severity — the same event subclass may be `info` in one
  /// emission context and `warning` in another (e.g. a recall that
  /// returned fewer than k items is normally `notice`, but in the middle
  /// of a sleep-mode dream it's `info`).
  final DiagnosticSeverity severity;

  /// Internal tags map — see [tags] for the exposed view.
  final Map<String, String> _tags;

  /// Construct an envelope.
  ///
  /// [sequence] must be ≥ 0 — negative sequences indicate a programming
  /// error in the emitter. [tags] is captured by reference and exposed
  /// through an unmodifiable view; callers can pass `const {}` (the
  /// default) for the no-tags case.
  DiagnosticEnvelope({
    required this.event,
    required this.source,
    required this.sequence,
    this.severity = DiagnosticSeverity.info,
    Map<String, String> tags = const {},
  })  : assert(sequence >= 0, 'sequence must be ≥ 0; got $sequence'),
        assert(source.isNotEmpty, 'source must not be empty'),
        _tags = tags;

  /// Unmodifiable view of the tags map.
  ///
  /// Returned as an unmodifiable wrapper so consumers cannot mutate the
  /// envelope's state through the getter. The underlying map is whatever
  /// the constructor was given — typically `const {}` or a small literal.
  Map<String, String> get tags => Map<String, String>.unmodifiable(_tags);

  /// JSON representation of the envelope.
  ///
  /// Shape:
  ///
  /// ```json
  /// {
  ///   "source": "tom_brain_memory",
  ///   "sequence": 42,
  ///   "severity": "info",
  ///   "tags": { "host": "bomber", "shard": "a" },   // omitted when empty
  ///   "event": { ... event.toJson() ... }
  /// }
  /// ```
  ///
  /// Empty `tags` are omitted to match the null-omission rule used by
  /// [BrainEvent.toJson].
  Map<String, Object?> toJson() => <String, Object?>{
        'source': source,
        'sequence': sequence,
        'severity': severity.name,
        if (_tags.isNotEmpty) 'tags': Map<String, String>.from(_tags),
        'event': event.toJson(),
      };
}
