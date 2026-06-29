// ProfileMode — the closed processing-shape alphabet of the Profile axis
// (session_configuration.md § 3.2, plan step 2).
//
// A profile's `mode` is the *friendly* knob that picks a well-known entry
// procedure. `cognitive` is the full process (today's behaviour); `answer` is a
// single memory-aware completion; `passthrough` is a memory-free relay. The
// mode→entry-procedure mapping is the spec § 3.2 contract — it lives here as a
// pure getter so the boot resolver (step 3) and the dispatcher override
// (step 6) read one source of truth rather than each duplicating the mapping.

/// The processing shape a [profile] selects. Closed alphabet (SC-Q3 / SC-Q7).
enum ProfileMode {
  /// The full cognitive process — `prompt_analyzer_v1` → answer/thinking.
  /// Today's behaviour and the `default` profile's mode (SC-5).
  cognitive,

  /// One memory-aware answer call, no analyzer / sub-prompts / critique.
  answer,

  /// One relay call, no memory and no orchestration (still a traced,
  /// budgeted, rate-limited procedure — SC-3).
  passthrough,

  /// Pure non-LLM memory retrieval, no synthesis — the diagnostic mode
  /// (SC-Q4). It runs only the lexical (bm25) recall pass and returns the
  /// recalled context verbatim as the answer; it issues no substrate call
  /// (structurally enforced — `retrieve_v1` imports no substrate bridge) and
  /// makes no embedding callout (bm25 only). Distinct from the LLM-augmented
  /// four-mode retrieval *system* of § 23 (`retrieve_for_prompt_v1`), which is
  /// a procedure-layer conductor, not a profile mode.
  retrieval;

  /// The well-known entry procedure this mode selects by default (spec § 3.2).
  /// A profile's explicit `entryProcedure` may override it (step 6).
  String get defaultEntryProcedure => switch (this) {
        ProfileMode.cognitive => 'prompt_analyzer_v1',
        ProfileMode.answer => 'answer_with_memory_v1',
        ProfileMode.passthrough => 'passthrough_v1',
        ProfileMode.retrieval => 'retrieve_v1',
      };

  /// The token used in config (`mode:`) and trail records — the enum name.
  String get wireName => name;

  /// Parses a wire token back to a [ProfileMode]. An unknown token is an
  /// [ArgumentError] (a `profile.unknown_mode`-class config error surfaces it
  /// at the boot loader, step 3).
  static ProfileMode fromWire(String value) => values.firstWhere(
        (m) => m.name == value,
        orElse: () => throw ArgumentError.value(
          value,
          'value',
          'unknown ProfileMode (expected one of '
              '${values.map((m) => m.name).join(', ')})',
        ),
      );
}
