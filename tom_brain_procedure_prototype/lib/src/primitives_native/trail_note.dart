// TrailNote + TrailSink — the value and the seam the engine-native `note`
// primitive writes through (Plan step C.20;
// `tom_brain_procedure_prototype_specification.md` § 5.1, § 8;
// `tom_brain_definition.md` § 3.4, § 7.4).
//
// ── What C.20 owns vs. defers ───────────────────────────────────────
//
// `note(category, payload)` "appends a structured note to the current
// run's trail" (§ 5.1). The *trail* itself — opening it at procedure
// start, persisting a `ProcedureRun`, pushing it to the `inflight` /
// `recent_runs` stacks — belongs to the `RunRecorder` (C.31, § 8). C.20
// implements only the act of producing a note and handing it to the
// recorder, behind a single injectable [TrailSink] seam. This mirrors
// C.19, which kept procedure resolution behind a `ProcedureExecutor`
// seam: C.20 supplies the *primitive* and the seam; C.31's recorder
// supplies what the seam delegates to.

import 'dart:collection';

/// The well-known note category that surfaces an idea to the dispatcher's
/// automation-idea harvester.
///
/// `note('automation_candidate', …)` is the wire by which a procedure tells
/// the brain "this looks worth automating" (§ 5.1; definition § 3.4). Other
/// categories are free-form strings; this is the one category the rest of
/// the system gives meaning to.
const String automationCandidateCategory = 'automation_candidate';

/// A single structured note appended to a procedure run's trail.
///
/// Immutable: [payload] is copied and wrapped on construction, so a caller
/// cannot mutate a note after it has been recorded and the producing
/// procedure cannot reach back into a note it already emitted. A note
/// carries its [category] (e.g. [automationCandidateCategory]), an
/// arbitrary structured [payload], and the [recordedAt] timestamp the
/// engine stamped when the note was taken.
final class TrailNote {
  /// Builds a note in [category] carrying [payload], stamped [recordedAt].
  ///
  /// Throws [ArgumentError] when [category] is empty — a note must say what
  /// kind of note it is so the harvester (and any later reader) can route
  /// it.
  TrailNote({
    required this.category,
    required this.recordedAt,
    Map<String, Object?> payload = const <String, Object?>{},
  }) : payload = UnmodifiableMapView<String, Object?>(
          Map<String, Object?>.of(payload),
        ) {
    if (category.isEmpty) {
      throw ArgumentError.value(
        category,
        'category',
        'a trail note must have a non-empty category',
      );
    }
  }

  /// The note's category. [automationCandidateCategory] is the one value
  /// the rest of the system acts on; all others are opaque labels.
  final String category;

  /// The structured contents of the note.
  final Map<String, Object?> payload;

  /// When the engine stamped the note.
  final DateTime recordedAt;

  @override
  String toString() =>
      'TrailNote($category, payload: ${payload.keys.join(', ')})';
}

/// The seam through which the `note` primitive hands a [TrailNote] to the
/// run's trail.
///
/// Supplied by the run recorder (C.31), which appends the note to the
/// currently-open trail. C.20 keeps it a bare callback — the same
/// deferral strategy C.19 used for `ProcedureExecutor` — so the `note`
/// primitive is testable in isolation now and the recorder plugs its real
/// trail in later without touching the primitive.
typedef TrailSink = void Function(TrailNote note);
