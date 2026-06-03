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

  /// Internal tags map — see [tags] for the exposed view. Copied into an
  /// unmodifiable map at construction so a caller that retains and later
  /// mutates the supplied list/map cannot reach in and change the
  /// envelope's state.
  final Map<String, String> _tags;

  /// Construct an envelope.
  ///
  /// [sequence] must be ≥ 0 — negative sequences indicate a programming
  /// error in the emitter and are rejected in release builds too (the
  /// envelope is the observability transport; an invalid one must not ride
  /// silently). [source] must be non-empty. [tags] is copied into an
  /// unmodifiable map at construction, so post-construction mutation of the
  /// caller's map does not affect the envelope; callers can pass `const {}`
  /// (the default) for the no-tags case.
  DiagnosticEnvelope({
    required this.event,
    required this.source,
    required this.sequence,
    this.severity = DiagnosticSeverity.info,
    Map<String, String> tags = const {},
  }) : _tags = Map<String, String>.unmodifiable(tags) {
    if (sequence < 0) {
      throw ArgumentError.value(
        sequence,
        'sequence',
        'must be ≥ 0; a negative sequence indicates an emitter bug',
      );
    }
    if (source.isEmpty) {
      throw ArgumentError.value(source, 'source', 'must not be empty');
    }
  }

  /// Unmodifiable view of the tags map.
  ///
  /// The map is already wrapped unmodifiable at construction, so this
  /// returns it directly — consumers cannot mutate the envelope's state
  /// through the getter.
  Map<String, String> get tags => _tags;

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
