// Barrel for the `events/` module (Plan step A.14).
//
// Module surface:
//
//   * `BrainEvent`           — abstract base for typed observability events
//                              emitted by every Tom Brain component.
//                              Subclasses live in the owning module
//                              (memory will add `MemoryEvent` at A.38).
//   * `DiagnosticEnvelope`   — transport wrapper around a `BrainEvent`
//                              carrying source identity, sequence number,
//                              severity, and tags.
//   * `DiagnosticSeverity`   — five-level severity enum (debug → error).
//   * `DiagnosticSeverityCompare` — extension with `atLeast` plus `<` / `<=`
//                              for filtering predicates that read at the
//                              call site.
//
// What is deliberately NOT here:
//
//   * Any concrete `BrainEvent` subclass. Those live in the components
//     that own the semantics — `tom_brain_memory` owns `MemoryEvent`,
//     `tom_brain_substrate` owns `SubstrateEvent`, etc. The shared layer
//     should not import knowledge of subclasses it does not define.
//   * Any decoder / registry. Deserialisation (when added at A.46+ for the
//     trail reader) lives in the consuming module and returns
//     `Result<BrainEvent, FormatException>` as flagged in the A.13
//     details.

export 'brain_event.dart' show BrainEvent;
export 'diagnostic_envelope.dart' show DiagnosticEnvelope;
export 'diagnostic_severity.dart'
    show DiagnosticSeverity, DiagnosticSeverityCompare;
