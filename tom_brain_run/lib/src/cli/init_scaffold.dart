// init_scaffold.dart — the `tom_brain init <dir>` scaffolder (CLI plan step
// #11; `tom_brain_cli.md` § 5.4).
//
// `init` writes the `<dir>/agent/` convention skeleton so an operator can start
// from working example config instead of a blank directory:
//
//   * `providers.example.yaml` — a `providers:` list (§ 3.1), ready to rename
//     into the `providers/` aspect dir or inline under `substrate.providers`.
//   * `models.example.yaml`    — `roleRoutes:` + `embedding:` (§ 3.2).
//   * `profiles.example.yaml`  — a `default` + one custom profile, matching
//     `session_configuration.md` § 3.8.
//   * `mcp/`                   — the (empty) external-MCP aspect dir.
//
// When the binary carries a bundle (`tom_brain bundle` baked prompts/scripts
// in), `init` also **extracts** the bundled prompts into `<agent>/prompts/` and
// scripts into `<agent>/scripts/` so they are editable on disk; `--no-extract`
// leaves the project running off the in-binary bundle. The native sqlite-vec
// library is NOT extracted here — it is materialised lazily at first boot
// (§ 4.2).
//
// The work is a pure filesystem function ([scaffoldAgentSkeleton]) so the CLI
// executor is a thin wrapper and the behaviour is unit-testable without a
// `ToolRunner`. The agent root is resolved through [ProjectHome] so the `<home>`
// → `<home>/agent` convention stays single-sourced.

import 'dart:io';

import '../bundle/bundle_manifest.dart' show BundleManifest;
import '../project_home.dart' show ProjectHome;

/// Raised when `init` cannot scaffold — a target whose `agent/` directory
/// already exists and is non-empty (refusing to clobber an existing brain).
final class InitScaffoldException implements Exception {
  /// Operator-facing explanation.
  final String message;

  const InitScaffoldException(this.message);

  @override
  String toString() => 'InitScaffoldException: $message';
}

/// What [scaffoldAgentSkeleton] wrote, for the CLI summary and the tests.
final class InitScaffoldResult {
  /// The resolved agent root (`<home>/agent`).
  final String agentRoot;

  /// The example/aspect files written, as agent-root-relative paths
  /// (`providers.example.yaml`, …, `mcp/`).
  final List<String> created;

  /// The number of bundled prompt templates extracted to `<agent>/prompts/`.
  final int extractedPrompts;

  /// The number of bundled procedure scripts extracted to `<agent>/scripts/`.
  final int extractedScripts;

  /// `true` when bundle extraction ran (a non-empty bundle and not
  /// `--no-extract`).
  bool get extracted => extractedPrompts > 0 || extractedScripts > 0;

  const InitScaffoldResult({
    required this.agentRoot,
    required this.created,
    required this.extractedPrompts,
    required this.extractedScripts,
  });
}

/// Writes the `<home>/agent/` convention skeleton and, unless [extract] is
/// `false`, extracts [bundle]'s prompts/scripts onto disk.
///
/// Throws [InitScaffoldException] when `<home>/agent` already exists and is
/// non-empty — `init` never overwrites an established brain.
InitScaffoldResult scaffoldAgentSkeleton({
  required Directory home,
  required BundleManifest bundle,
  bool extract = true,
}) {
  final ProjectHome ph = ProjectHome(home: home.path);
  final Directory agent = Directory(ph.agentRoot);

  if (agent.existsSync() && agent.listSync().isNotEmpty) {
    throw InitScaffoldException(
      'agent directory already exists and is not empty: ${agent.path}. '
      'Pick an empty target, or edit the existing brain in place.',
    );
  }
  agent.createSync(recursive: true);

  final created = <String>[];
  void writeExample(String name, String body) {
    File('${agent.path}${Platform.pathSeparator}$name').writeAsStringSync(body);
    created.add(name);
  }

  writeExample('providers.example.yaml', _providersExample);
  writeExample('models.example.yaml', _modelsExample);
  writeExample('profiles.example.yaml', _profilesExample);

  Directory('${agent.path}${Platform.pathSeparator}mcp')
      .createSync(recursive: true);
  created.add('mcp/');

  var extractedPrompts = 0;
  var extractedScripts = 0;
  if (extract && !bundle.isEmpty) {
    extractedPrompts = _extractPrompts(agent, bundle);
    extractedScripts = _extractScripts(agent, bundle);
  }

  return InitScaffoldResult(
    agentRoot: agent.path,
    created: created,
    extractedPrompts: extractedPrompts,
    extractedScripts: extractedScripts,
  );
}

/// Extracts every bundled prompt to `<agent>/prompts/<key>`, where the key is
/// the cognition-root-relative POSIX path the bundle stored it under (the
/// inverse of the codegen's `_readPrompts`). Returns the count written.
int _extractPrompts(Directory agent, BundleManifest bundle) {
  final root = '${agent.path}${Platform.pathSeparator}prompts';
  Directory(root).createSync(recursive: true);
  for (final entry in bundle.prompts.entries) {
    final relative =
        entry.key.split('/').join(Platform.pathSeparator);
    final file = File('$root${Platform.pathSeparator}$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return bundle.prompts.length;
}

/// Extracts every bundled procedure to `<agent>/scripts/<locator>.dart`. The
/// bundle keys procedures by their filename stem (the disk store reads `*.dart`
/// keyed by the same stem), so the `.dart` extension is reattached. Returns the
/// count written.
int _extractScripts(Directory agent, BundleManifest bundle) {
  final root = '${agent.path}${Platform.pathSeparator}scripts';
  Directory(root).createSync(recursive: true);
  for (final entry in bundle.scripts.entries) {
    File('$root${Platform.pathSeparator}${entry.key}.dart')
        .writeAsStringSync(entry.value);
  }
  return bundle.scripts.length;
}

/// `providers.example.yaml` — the `providers:` aspect (§ 3.1).
const String _providersExample = '''
# providers — connection definitions: where the models live and how to reach
# them (tom_brain_cli.md § 3.1). Rename this into the `providers/` aspect dir
# (e.g. providers/local.yaml) or inline it under `substrate.providers` in
# brain.yaml. `\${env:NAME}` expands from the environment at load.
providers:
  - id: local
    kind: ollama
    baseUrl: http://127.0.0.1:11434
    models:
      - gemma3:27b
      - nomic-embed-text
  # - id: openai
  #   kind: openai
  #   baseUrl: https://api.openai.com/v1/
  #   auth: \${env:OPENAI_API_KEY}
  #   models:
  #     - gpt-4o-mini
''';

/// `models.example.yaml` — the `models:` aspect: role routing + embedding
/// (§ 3.2).
const String _modelsExample = '''
# models — role → model routing plus the embedding model (tom_brain_cli.md
# § 3.2). Rename this into the `models/` aspect dir or inline it under
# `substrate.roleRoutes` + `substrate.embedding`. Every providerId must name a
# provider from the providers aspect.
roleRoutes:
  assistant_to_user:
    - providerId: local
      model: gemma3:27b
  analyser:
    - providerId: local
      model: gemma3:27b
embedding:
  providerId: local
  model: nomic-embed-text
  dims: 768
  normalize: true
''';

/// `profiles.example.yaml` — a `default` + one custom profile, mirroring
/// `session_configuration.md` § 3.8.
const String _profilesExample = '''
# profiles — session behaviour bundles (session_configuration.md § 3.8). Rename
# this into the `profiles/` aspect dir (profiles/<name>.yaml, unioned by id) or
# inline it under the top-level `profiles:` map. Never bundled — a profile may
# carry secret-bearing defineMcpServers.
profiles:
  # The reserved default — the global baseline (cognitive: the full process).
  default:
    mode: cognitive

  # A deep-research assistant: full process, a research voice, a tweaked answer
  # template, and a wider budget.
  research:
    mode: cognitive
    role: researcher
    templateOverlay: research
    budget:
      maxLlmCalls: 24
      wallClock: 180s
    defaultMemory: research
''';
