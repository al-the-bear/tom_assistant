// HistoryPolicy — the behavioural-flags half of the history config split
// (Extension G step 25; `tom_brain_procedure_prototype_specification.md`
// § 22.6a; access § 13.1).
//
// History config is split across the two existing Extension-F config layers
// (§ 22.6): the *sizing* knobs (`rawCount` / `compactionThreshold` / …) ride
// the **model config** as a `HistorySizing` (so the window scales with the
// model's context budget), while the *behavioural* flags ride the **prompt
// template** as this `HistoryPolicy` (so each prompt type chooses how it uses
// history). This file owns the behavioural half:
//
//   useLocal            send the brain's own session history (§ 22.5 part 2).
//   useRemote           send the client-provided messages[]  (§ 22.5 part 1).
//   injectAsPriorTurns  on ⇒ a real prior-turns array; off ⇒ history reaches
//                       the model only through the placeholders (§ 22.5).
//   compactionTemplate  which prompt template compaction uses (§ 22.4).
//
// A missing `history:` block on the prompt template falls back to the standard
// policy (every flag on, the default compaction template) — it is not an error
// (§ 22.6). Loading goes through the canonical plain-map loader, so no
// `YamlMap` node leaks into a `HistoryPolicy`.

library;

import 'package:tom_core_agentic/tom_core_agentic.dart' show YamlConfigReader;

/// The default compaction prompt template type (§ 22.4) — the canonical single
/// source of truth shared by [HistoryPolicy.compactionTemplate]'s default and
/// the engine-side `HistoryCompactor` (which imports it from here, honouring
/// the `config → history` dependency direction).
const String defaultHistoryCompactionTemplate = 'compact_history_v1';

/// The behavioural history flags for one prompt type (§ 22.6a).
///
/// Immutable value object with the documented defaults. A prompt template that
/// declares no `history:` block uses [HistoryPolicy.standard].
final class HistoryPolicy {
  /// Whether the brain's own session history is sent (default `true`).
  final bool useLocal;

  /// Whether the client-provided `messages[]` are sent (default `true`).
  final bool useRemote;

  /// Whether history is injected as a real prior-turns array (default `true`);
  /// when `false`, history reaches the model only through the placeholders.
  final bool injectAsPriorTurns;

  /// Which prompt template compaction uses (default
  /// [defaultHistoryCompactionTemplate]).
  final String compactionTemplate;

  /// Builds a policy. Every flag defaults to its documented value.
  const HistoryPolicy({
    this.useLocal = true,
    this.useRemote = true,
    this.injectAsPriorTurns = true,
    this.compactionTemplate = defaultHistoryCompactionTemplate,
  });

  /// The standard policy — every flag on, the default compaction template.
  const HistoryPolicy.standard() : this();

  /// Parses a `history:` [block] from a prompt template (or returns the
  /// standard policy when the block is absent).
  ///
  /// [reader] is the prompt template loader's [YamlConfigReader] (so a present
  /// but ill-typed value surfaces as the loader's own located error);
  /// [basePath] is the dotted path of the block (`prompt_template.history`).
  /// An absent flag defaults; only a *present, wrong-typed* flag throws.
  static HistoryPolicy fromYamlBlock(
    Map<Object?, Object?>? block,
    YamlConfigReader reader,
    String basePath,
  ) {
    if (block == null) return const HistoryPolicy.standard();
    final useLocal = reader.optionalBool(block, 'useLocal', '$basePath.useLocal');
    final useRemote =
        reader.optionalBool(block, 'useRemote', '$basePath.useRemote');
    final injectAsPriorTurns = reader.optionalBool(
        block, 'injectAsPriorTurns', '$basePath.injectAsPriorTurns');
    final compactionTemplate = reader.optionalString(
        block, 'compactionTemplate', '$basePath.compactionTemplate');
    return HistoryPolicy(
      useLocal: useLocal ?? true,
      useRemote: useRemote ?? true,
      injectAsPriorTurns: injectAsPriorTurns ?? true,
      compactionTemplate: compactionTemplate ?? defaultHistoryCompactionTemplate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryPolicy &&
      other.useLocal == useLocal &&
      other.useRemote == useRemote &&
      other.injectAsPriorTurns == injectAsPriorTurns &&
      other.compactionTemplate == compactionTemplate;

  @override
  int get hashCode =>
      Object.hash(useLocal, useRemote, injectAsPriorTurns, compactionTemplate);

  @override
  String toString() => 'HistoryPolicy(useLocal: $useLocal, '
      'useRemote: $useRemote, injectAsPriorTurns: $injectAsPriorTurns, '
      'compactionTemplate: $compactionTemplate)';
}
