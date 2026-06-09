// PT-3.2 — pure run-step ↔ source correlation (§ 4.6). The run-tree nodes carry
// no source line numbers (the trail records *what* acts ran, not *which line*
// issued them), so the inspector correlates best-effort: it collects the act
// tokens a run executed and lights up the source lines that mention them. A hit
// means "this line issues an act the run executed", never an authoritative 1:1
// map — that is the §4.6 "where the trail makes the correspondence available"
// degradation, made explicit.
//
// No Flutter import: these are pure functions over the §3.9 model, unit-tested
// directly and reused by [ProcedureScriptView].

import 'dart:convert';

import '../model/prompt_trace.dart';

/// The act tokens [run] issued, drawn from its **immediate** nodes only:
///
///  - a primitive call contributes its `primitive` name (`embed`, `persist`, …),
///  - an LLM call contributes the literal `llm` (the source calls it `llm(...)`),
///  - a sub-run contributes its dispatched `procedureId` (it appears in the
///    source as the string literal passed to `runProcedure`),
///  - notes and errors contribute nothing — they are not source acts.
///
/// Sub-runs deliberately do **not** contribute their inner acts: those belong to
/// the sub-procedure's own source, not the source being inspected here.
Set<String> executedActs(ProcedureRun run) {
  final acts = <String>{};
  for (final node in run.nodes) {
    switch (node) {
      case PrimitiveCallNode(:final primitive):
        acts.add(primitive);
      case LlmCallNode():
        acts.add('llm');
      case SubRunNode(:final run):
        acts.add(run.procedureId);
      case NoteNode():
      case ErrorNode():
        break;
    }
  }
  return acts;
}

/// The 0-based indices of lines in [source] that mention any of [acts] as a
/// whole token. A token may be prefixed by a receiver dot (`sub.embed` matches
/// `embed`) but is never a mere substring of a larger identifier (`embedder`
/// does not match `embed`). Best-effort by contract (see file header).
Set<int> correlateLines(String source, Set<String> acts) {
  if (acts.isEmpty) return const <int>{};
  final patterns = <RegExp>[
    for (final act in acts)
      if (act.isNotEmpty)
        // Block a leading word char (so `embedder` ≠ `embed`) but allow a
        // leading `.` (so `sub.embed` matches); block a trailing word char.
        RegExp(r'(?<!\w)' + RegExp.escape(act) + r'(?!\w)'),
  ];
  final lines = const LineSplitter().convert(source);
  final hits = <int>{};
  for (var i = 0; i < lines.length; i++) {
    if (patterns.any((p) => p.hasMatch(lines[i]))) hits.add(i);
  }
  return hits;
}
