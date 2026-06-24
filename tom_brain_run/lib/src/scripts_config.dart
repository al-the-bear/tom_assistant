// ScriptsConfig — the typed `scripts:` section of the whole-process config:
// the disk directories the procedure store's disk backend resolves
// `scripts/system/` (and optionally `scripts/user/`) from (CLI plan step 3).
//
// The standalone `tom_brain` CLI resolves its shipped procedures from a
// configured disk directory (`<agent>/scripts/system/`) instead of the
// package-relative path the prototype boot falls back to. A present block
// names that directory; an optional `userDir` adds the user-authored tier.
//
// The block is optional. Its absence (a `null` on `BrainRunConfig`) leaves the
// boot path on its package-relative fallback (`_resolveProcedurePrototypeScripts`),
// so existing prototype deployments stay well-formed. A present block REQUIRES
// `systemDir` — the disk backend needs a system directory to serve.
//
// This value type is read-only — parsed once at boot by `ScriptsConfigLoader`.
// The directory paths are stored verbatim (after `${env:NAME}` expansion); no
// base-path resolution is applied here (CLP decision — the CLI passes absolute
// directories via `--scripts`).

import 'dart:io';

/// Thrown when a `scripts:` block is structurally invalid (missing
/// `systemDir`, an unknown key, a non-map block, an undefined `${ENV}` token,
/// …).
///
/// Messages carry the dotted key path (e.g. `scripts.systemDir`) so the
/// offending field is obvious — the same located-error discipline the sibling
/// section loaders use.
class ScriptsConfigException implements Exception {
  /// Builds the exception with a [message].
  const ScriptsConfigException(this.message);

  /// Human-readable, located explanation.
  final String message;

  @override
  String toString() => 'ScriptsConfigException: $message';
}

/// The parsed `scripts:` section — the disk directories the procedure store's
/// disk backend resolves procedures from (CLI plan step 3).
///
/// Present ⇒ the boot path builds its [DiskProcedureStore] over [systemDir]
/// (+ [userDir]); its absence (a `null` on `BrainRunConfig`) ⇒ the boot path's
/// package-relative fallback.
final class ScriptsConfig {
  /// Directory of shipped, well-known procedures (`scripts/system/`).
  final Directory systemDir;

  /// Directory of user-authored procedures (`scripts/user/`); `null` when no
  /// `userDir` is configured.
  final Directory? userDir;

  /// Assembles a scripts config over its directories. [systemDir] is required.
  const ScriptsConfig({required this.systemDir, this.userDir});
}
