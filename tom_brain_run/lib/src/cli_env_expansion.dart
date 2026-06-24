// cli_env_expansion.dart — CLI `${env:NAME}` flag expansion (CLI plan step #7;
// `tom_brain_cli.md` § 5 note / § 11.7 / `--set` § 5.3).
//
// `tom_brain_cli.md` makes `${env:…}` work on the command line, not just inside
// config files (CLI-Q8 override): every CLI flag value and every
// `--set key=value` value is run through the SAME `${env:NAME}` expander the
// YAML config loaders use, BEFORE any path resolution. So
// `--telegram-token '${env:TELEGRAM_BOT_TOKEN}'`, `--openai='${env:PORT}'`,
// `--home '${env:BRAIN_HOME}'`, `--providers '${env:CFG}/providers'` all expand
// from the process environment. An unresolved `${env:X}` (unset variable) is a
// clear startup error — never an empty string — so a misspelled or missing
// secret fails loudly at boot instead of silently producing a broken config.
//
// The single shared mechanism is `YamlConfigReader.expandEnv`, which routes
// through the one `PlaceholderResolver` the whole config layer + engine use.
// Reusing it here (with a CLI-specific error factory) is the point of the step:
// flag values and file values resolve placeholders through one code path, so
// the `env:`-only contract and the unset-variable error wording are identical.
//
// This unit is pure: the environment is injected, so there is no `dart:io`
// import. The step-8 CLI binary supplies `Platform.environment`.

import 'package:tom_core_agentic/tom_core_agentic.dart' show YamlConfigReader;

/// Thrown when a CLI flag value (or a `--set` value) references an undefined
/// environment variable, an unbound bare placeholder, or an unsupported
/// expression form. The [message] names the offending flag and variable so a
/// boot failure points the operator straight at the bad invocation.
final class CliEnvExpansionException implements Exception {
  CliEnvExpansionException(this.message);

  /// Engineer-readable description of what failed to expand.
  final String message;

  @override
  String toString() => 'CliEnvExpansionException: $message';
}

/// Expands `${env:NAME}` tokens in a single CLI flag [value] against [env],
/// reporting failures by [flag] (e.g. `--telegram-token`).
///
/// Returns [value] unchanged when it carries no placeholder. Throws
/// [CliEnvExpansionException] when a token names an undefined variable, is an
/// unbound bare `${NAME}` (the environment is reachable only via the
/// `${env:NAME}` form), or uses the unsupported `${{ … }}` expression form.
String expandCliFlag(
  String flag,
  String value, {
  required Map<String, String> env,
}) {
  final reader = YamlConfigReader(
    env: env,
    errorFactory: CliEnvExpansionException.new,
  );
  return reader.expandEnv(value, flag);
}

/// Expands every value in [flags] (flag name → raw value) against [env],
/// preserving insertion order. Each key is the error path, so an unset variable
/// names the offending flag. The first failure throws.
Map<String, String> expandCliFlags(
  Map<String, String> flags, {
  required Map<String, String> env,
}) {
  final out = <String, String>{};
  for (final entry in flags.entries) {
    out[entry.key] = expandCliFlag(entry.key, entry.value, env: env);
  }
  return out;
}

/// Expands the value half of a `--set <key>=<value>` override against [env],
/// reporting failures as `--set <key>` so a bad scalar override is traceable to
/// the exact `--set` it came from.
String expandSetValue(
  String key,
  String value, {
  required Map<String, String> env,
}) =>
    expandCliFlag('--set $key', value, env: env);
