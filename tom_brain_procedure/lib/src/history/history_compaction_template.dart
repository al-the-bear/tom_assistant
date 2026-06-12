// HistoryCompactionTemplate — the minimal two-scaffold template the
// `HistoryCompactor` folds a conversation's pending batch through (hub § 22.4).
//
// Before increment 9 the compactor loaded its scaffolds through the full
// layer-3 `PromptTemplateConfig` (role + models chain + tool policy + history
// flags). That three-layer config is retired with the scripted `call_llm_v1`
// loop; the compactor only ever read the `system` / `user` scaffolds from it,
// so it now loads exactly those two from a self-contained
// `compact_history_v1.yaml` — no role resolution, no model chain, nothing the
// retired scaffold carried. The anchor (PE-7) is still applied by the substrate
// at the call site (hub § 22.4), not via a template placeholder.

library;

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show YamlConfigReader, loadYamlAsMap;

import '../config/llm_config_errors.dart' show LlmConfigInvalid;

/// Thrown when a requested compaction template `<type>.yaml` does not exist.
final class HistoryCompactionTemplateMissing implements Exception {
  /// Records the absent compaction template for [type] at [path].
  const HistoryCompactionTemplateMissing(this.type, this.path);

  /// The compaction template type whose file is missing (the filename stem).
  final String type;

  /// The filesystem path that was expected to hold the template.
  final String path;

  /// Human-readable explanation, reused by [toString].
  String get message => 'history compaction template "$type" not found at '
      '"$path"';

  @override
  String toString() => 'history.compaction.template.missing: $message';
}

/// The two history-compaction scaffolds, kept verbatim (placeholder-bearing).
///
/// Only `${history.compacted}` / `${history.batch}` are injected by the
/// compactor (hub § 22.4); the `${role.anchor}` is applied by the substrate at
/// the call site, so it is not a placeholder the compactor resolves.
final class HistoryCompactionTemplate {
  /// Builds a compaction template from its two scaffolds.
  const HistoryCompactionTemplate({required this.system, required this.user});

  /// The system scaffold (placeholder-bearing).
  final String system;

  /// The user scaffold (placeholder-bearing).
  final String user;

  /// Parses a compaction template from [yamlText].
  ///
  /// A missing `system` / `user` field is a located [LlmConfigInvalid]. Any
  /// other fields (`id`, `role`, `models`, …) a legacy `compact_history_v1.yaml`
  /// still carries are ignored — only the two scaffolds are read.
  static HistoryCompactionTemplate fromYamlString(String yamlText) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'compact_history',
      errorFactory: LlmConfigInvalid.new,
    );
    const reader = YamlConfigReader(
      env: <String, String>{},
      errorFactory: LlmConfigInvalid.new,
    );
    return HistoryCompactionTemplate(
      system: reader.requireString(doc, 'system', 'compact_history.system'),
      user: reader.requireString(doc, 'user', 'compact_history.user'),
    );
  }

  /// Reads and parses a compaction template at [file].
  ///
  /// An absent file throws [HistoryCompactionTemplateMissing] keyed by the
  /// filename stem; a structural problem throws [LlmConfigInvalid].
  static Future<HistoryCompactionTemplate> loadFromFile(File file) async {
    if (!await file.exists()) {
      throw HistoryCompactionTemplateMissing(_stemOf(file.path), file.path);
    }
    return fromYamlString(await file.readAsString());
  }

  static String _stemOf(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }
}

/// Loads compaction templates from a directory by type
/// (`<directory>/<type>.yaml`).
final class HistoryCompactionTemplateStore {
  /// Wraps the directory holding the `<type>.yaml` compaction templates.
  const HistoryCompactionTemplateStore(this.directory);

  /// The directory holding `<type>.yaml` compaction templates.
  final Directory directory;

  /// Loads the template named [type] (`<directory>/<type>.yaml`).
  ///
  /// Throws [HistoryCompactionTemplateMissing] when the file is absent, or
  /// [LlmConfigInvalid] when it is malformed.
  Future<HistoryCompactionTemplate> load(String type) {
    final file =
        File('${directory.path}${Platform.pathSeparator}$type.yaml');
    return HistoryCompactionTemplate.loadFromFile(file);
  }
}
