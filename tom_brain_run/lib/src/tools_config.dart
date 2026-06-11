// ToolsConfig — the typed `tools:` section of the whole-process config: the
// two-tier file-scope roots the engine's `file.*` tools resolve against
// (§ 21.4).
//
// The file sandbox is a configuration value with two tiers. `tools.writeScope`
// is a LIST of directories the write tools (`file.write` / `file.edit` /
// `file.delete` / `test.*`) may target, and `tools.readScope` a LIST the read
// tools (`file.read` / `file.diff` / `grep.search` / `file.search` /
// `file.list` / `analyze.*`) may additionally reach. A writeable directory is
// implicitly readable. A deployment grants a brain read-only access to a tree
// it must inspect but never modify by listing it under `readScope` alone (e.g.
// a colocated workspace), and a scratch tree it owns under `writeScope`.
//
// The block is optional. Its absence (a `null` on `BrainRunConfig`) leaves the
// engine on its neutral placeholder root — the prototype's many runs that
// never touch a real filesystem stay well-formed. A present block REQUIRES at
// least one root across the two tiers (an empty sandbox is a config error, not
// a silent stance — a file tool needs somewhere to act).
//
// This value type is read-only — parsed once at boot by `ToolsConfigLoader`
// and never re-serialised; [toFileScope] hands the engine its [FileScope].

import 'package:tom_brain_procedure/tom_brain_procedure.dart' show FileScope;

/// Thrown when a `tools:` block is structurally invalid (no roots at all, a
/// non-string entry, an unknown key, an undefined `${ENV}` token, …).
///
/// Messages carry the dotted key path (e.g. `tools.writeScope[0]`) so the
/// offending field is obvious — the same located-error discipline the sibling
/// section loaders use.
class ToolsConfigException implements Exception {
  /// Builds the exception with a [message].
  const ToolsConfigException(this.message);

  /// Human-readable, located explanation.
  final String message;

  @override
  String toString() => 'ToolsConfigException: $message';
}

/// The parsed `tools:` section — the two-tier file-scope roots the `file.*`
/// tools resolve against (§ 21.4).
///
/// Present ⇒ the engine's [ToolContext] is built over [toFileScope]; its
/// absence (a `null` on `BrainRunConfig`) ⇒ the engine's neutral placeholder
/// root. At least one of [writeScope] / [readScope] is non-empty; both are
/// unmodifiable.
final class ToolsConfig {
  /// The configured writeable roots, in priority order. The file write/delete
  /// tools target these; the first is the primary `file.write` target.
  /// Unmodifiable. May be empty when only read-only roots are granted.
  final List<String> writeScope;

  /// The configured read-only roots, in priority order — readable but not
  /// writeable. Unmodifiable. May be empty when every root is writeable.
  final List<String> readScope;

  /// Assembles a tools config over its two tiers. At least one of [writeScope]
  /// / [readScope] must be non-empty.
  ToolsConfig({
    List<String> writeScope = const <String>[],
    List<String> readScope = const <String>[],
  })  : assert(writeScope.isNotEmpty || readScope.isNotEmpty,
            'a tools: block must list at least one writeable or readable root'),
        writeScope = List<String>.unmodifiable(writeScope),
        readScope = List<String>.unmodifiable(readScope);

  /// The engine-side [FileScope] this config maps to: the writeable roots as
  /// the write tier, the read-only roots as the read tier.
  FileScope toFileScope() =>
      FileScope(writeRoots: writeScope, readRoots: readScope);
}
