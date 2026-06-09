// note — the engine-native trail-note primitive (Plan step C.20;
// `tom_brain_procedure_specification.md` § 5.1, § 8;
// `tom_brain_definition.md` § 3.4).
//
// `note(category, payload)` appends a structured note to the current
// run's trail. The primitive stamps the note with the current time and
// forwards it to the injected [TrailSink]; the recorder (C.31) owns where
// the trail lives. C.20 keeps the I/O behind the sink seam exactly as
// C.19 kept procedure resolution behind `ProcedureExecutor` — see
// `trail_note.dart` for the rationale.

import 'trail_note.dart';

/// The engine-native `note` primitive.
///
/// Builds a [TrailNote] from a `(category, payload)` call and hands it to
/// the [sink]. Stateless apart from its [sink] and clock; the clock is
/// injectable so tests can assert a deterministic [TrailNote.recordedAt].
final class NotePrimitive {
  /// Builds the primitive over a [sink] and an optional clock.
  ///
  /// [now] defaults to [DateTime.now]; tests pass a fixed clock to assert
  /// the stamped [TrailNote.recordedAt].
  NotePrimitive({
    required this.sink,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Receives every note the primitive produces.
  final TrailSink sink;

  final DateTime Function() _now;

  /// Appends a note in [category] carrying [payload] to the run's trail.
  ///
  /// The note is stamped with the current time and forwarded to [sink].
  /// Throws [ArgumentError] (via [TrailNote]) when [category] is empty.
  /// `payload` is defensively copied by [TrailNote], so the caller may
  /// reuse or mutate the map it passed without affecting the recorded
  /// note.
  void note(String category, Map<String, Object?> payload) {
    sink(
      TrailNote(
        category: category,
        payload: payload,
        recordedAt: _now(),
      ),
    );
  }
}
