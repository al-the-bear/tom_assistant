// Reconstructs the §3.4 [Configuration] that *actually ran* for a turn from the
// LLM-call trail — never from the YAML. Each `llm` node in the run-tree links to
// its authoritative `llm/<role>/<stem>.raw.json` dump (`LlmCallTrailRecord`,
// `tom_brain_logging.md` § 5.2); reading the distinct (role, provider, model,
// profile) tuples off those dumps is the only honest answer to "what config was
// in effect" (§ 3.4 / § 4.3). A free-tier rotation mid-turn therefore shows both
// providers — the set is what ran, not what was asked for.

import 'dart:convert';
import 'dart:io';

import '../model/prompt_trace.dart';
import '../model/run_tree.dart';
import 'run_tree_walk.dart';
import 'trail_host.dart';

/// One parsed top-level run paired with the `.log` file its `llm` links resolve
/// against (`../../llm/…raw.json`, relative to the `procedures/<proc>/` folder).
typedef ParsedRun = ({ProcedureRun run, File log});

/// Builds the [Configuration] for a turn from **all** its top-level [runs] —
/// the distinct (role, provider, model, profile) tuples that actually ran across
/// every run (classifier + answer + …). Returns an entry-less [Configuration]
/// (carrying only [memoryProfile]) when no run carried an LLM call — absence is
/// never an error (§ 4.1).
///
/// Entries are de-duplicated by (role, provider, model, profile) and kept in
/// first-seen order across the runs: a `LinkedHashSet` over [ConfigEntry], whose
/// `==`/`hashCode` define the tuple identity.
Configuration buildConfiguration({
  required List<ParsedRun> runs,
  required TrailHost host,
  String? memoryProfile,
}) {
  final entries = <ConfigEntry>{};
  for (final (:run, :log) in runs) {
    for (final llm in allLlmCalls(run)) {
      final raw = host.llmRawFromLink(log, llm.rawPath);
      if (!raw.existsSync()) continue;
      final decoded = jsonDecode(raw.readAsStringSync());
      if (decoded is! Map<String, Object?>) continue;
      entries.add(
        ConfigEntry(
          role: decoded['callType'] as String? ?? llm.callType,
          provider: decoded['provider'] as String? ?? 'unknown',
          model: decoded['model'] as String? ?? 'unknown',
          profile:
              decoded['profile'] as String? ??
              decoded['memoryProfile'] as String?,
          temperature: (decoded['temperature'] as num?)?.toDouble(),
          maxOutputTokens: decoded['maxOutputTokens'] as int?,
          stopSequences: <String>[
            for (final s
                in (decoded['stopSequences'] as List<Object?>? ??
                    const <Object?>[]))
              s as String,
          ],
        ),
      );
    }
  }
  return Configuration(entries: entries.toList(), memoryProfile: memoryProfile);
}
