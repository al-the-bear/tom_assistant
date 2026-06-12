// BrainBuiltins — the six boot-time built-in placeholders every resolver
// `tom_brain_run` hands down carries (`prompt_configuration.md` §6, §12 step 2).
//
// The unified `PlaceholderResolver` (in `tom_core_agentic`) reads a binding
// namespace for its `${name}` / `${{ … }}` forms. A handful of those names are
// not per-call context — they are process-wide facts resolved once at boot:
// the fleet host, the trail / cognition-config / memory / scripts folders, and
// the assistant-dedication anchor. This value type is that set, derived from
// the parsed `BrainRunConfig` plus the two folders the config does not itself
// carry (the cognition root and the resolved `scripts/system` dir), with the
// anchor as a compile-time constant.
//
// It is the boot-time half of §2's "`tom_brain_run` constructs the engine-side
// resolver with the built-in bindings and hands it down": [resolver] builds a
// `PlaceholderResolver` already seeded with the built-ins, and [bindInto] seeds
// an existing stack (the engine wires this onto its own resolver in later
// increments).

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'brain_run_config.dart';

/// The six §6 built-in placeholder values, bound into every resolver the run
/// assembly constructs.
///
/// Five are paths / host facts resolved at boot; the sixth — `${role.anchor}`
/// — is the compile-time [AssistantDedicationAnchor.text] constant. The anchor
/// binding key carries a dot, so it is reachable only via the simple
/// `${role.anchor}` lookup and is *not* a valid `${{ … }}` expression local —
/// correct, since the anchor is injected as text, never computed against.
final class BrainBuiltins {
  /// The fleet host name (e.g. `bomber`). `${hostname}`.
  final String hostname;

  /// The resolved trail root, or empty in unconfigured trail mode.
  /// `${trail_folder}`.
  final String trailFolder;

  /// The cognition config root. `${config_folder}`.
  final String configFolder;

  /// The SQLite memory directory. `${memory_root}`.
  final String memoryRoot;

  /// The resolved `scripts/system` directory. `${scripts_folder}`.
  final String scriptsFolder;

  /// Binds the five boot-resolved values; the anchor is the compile-time
  /// constant added by [bindings].
  const BrainBuiltins({
    required this.hostname,
    required this.trailFolder,
    required this.configFolder,
    required this.memoryRoot,
    required this.scriptsFolder,
  });

  /// Derives the built-ins from a parsed [config] plus the two folders the
  /// config does not carry: the cognition [configFolder] and the resolved
  /// [scriptsFolder].
  ///
  /// `${memory_root}` reads `config.memory.root`; `${trail_folder}` reads
  /// `config.trail?.root` (empty when the document carries no `trail:` block —
  /// unconfigured mode). [hostname] defaults to [Platform.localHostname].
  factory BrainBuiltins.fromRunConfig(
    BrainRunConfig config, {
    required String configFolder,
    required String scriptsFolder,
    String? hostname,
  }) =>
      BrainBuiltins(
        hostname: hostname ?? Platform.localHostname,
        trailFolder: config.trail?.root ?? '',
        configFolder: configFolder,
        memoryRoot: config.memory.root,
        scriptsFolder: scriptsFolder,
      );

  /// The §6 built-in name → value bindings, including the dedication anchor.
  Map<String, Object?> get bindings => <String, Object?>{
        'hostname': hostname,
        'trail_folder': trailFolder,
        'config_folder': configFolder,
        'memory_root': memoryRoot,
        'scripts_folder': scriptsFolder,
        'role.anchor': AssistantDedicationAnchor.text,
      };

  /// Seeds the §6 built-ins into [stack]'s current frame.
  void bindInto(PlaceholderStack stack) => stack.bindAll(bindings);

  /// Builds a [PlaceholderResolver] already seeded with the §6 built-ins.
  ///
  /// [expressions] backs the `${{ … }}` form (the engine passes a
  /// `D4rtExpressionContext`; the config layer passes `null` so a stray
  /// expression fails fast). [strict] and [environment] are forwarded to the
  /// resolver unchanged.
  PlaceholderResolver resolver({
    PlaceholderExpressions? expressions,
    bool strict = true,
    Map<String, String>? environment,
  }) {
    final resolver = PlaceholderResolver(
      expressions: expressions,
      strict: strict,
      environment: environment,
    );
    bindInto(resolver.stack);
    return resolver;
  }
}
