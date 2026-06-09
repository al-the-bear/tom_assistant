// ToolsConfig — the typed `tools:` section of the whole-process config: the
// file-scope roots the engine's `file.*` tools resolve against (§ 21.4).
//
// The file sandbox is a configuration value. `tools.fileScope` is a LIST of
// directories so a deployment can widen the sandbox as needed (a brain that
// must reach two project trees lists both). The file tools resolve and
// path-escape-check against the *union* of these roots: a `file.*` call may
// reach any configured directory but nothing outside them all; the first root
// is the primary (the `file.write` target).
//
// The block is optional. Its absence (a `null` on `BrainRunConfig`) leaves the
// engine on its neutral placeholder root — the prototype's many runs that
// never touch a real filesystem stay well-formed. A present block REQUIRES a
// non-empty `fileScope` list (an empty sandbox is a config error, not a silent
// no-web-style stance — a tool that may write needs somewhere to write).
//
// This value type is read-only — parsed once at boot by `ToolsConfigLoader`
// and never re-serialised.

/// Thrown when a `tools:` block is structurally invalid (a missing / empty
/// `fileScope`, a non-string entry, an unknown key, an undefined `${ENV}`
/// token, …).
///
/// Messages carry the dotted key path (e.g. `tools.fileScope[0]`) so the
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

/// The parsed `tools:` section — the file-scope roots the `file.*` tools
/// resolve against (§ 21.4).
///
/// Present ⇒ the engine's [ToolContext] is built over [fileScope]; its absence
/// (a `null` on `BrainRunConfig`) ⇒ the engine's neutral placeholder root.
/// [fileScope] is always non-empty and unmodifiable when the block is present.
final class ToolsConfig {
  /// The configured file-scope roots, in priority order. Non-empty and
  /// unmodifiable. The file tools resolve against the union of these roots; the
  /// first is the primary `file.write` target.
  final List<String> fileScope;

  /// Assembles a tools config over a non-empty [fileScope] list.
  ToolsConfig({required List<String> fileScope})
      : assert(fileScope.isNotEmpty, 'fileScope must carry at least one root'),
        fileScope = List<String>.unmodifiable(fileScope);
}
