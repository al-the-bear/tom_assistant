// Profile config errors — the located, coded failures the Profile axis raises
// at parse and at boot (session_configuration.md § 8, plan step 3).
//
// Two distinct shapes, by who is at fault:
//
//   * [ProfileConfigException] — an *operator* config fault in the `profiles:`
//     block. It carries a stable `code` (`profile.mode_entry_conflict`,
//     `profile.unknown_role`, `profile.overlay_missing`, `profile.unknown_mode`)
//     so the boot loader and tests assert on the cause without string-matching,
//     and an optional dotted `path` for the located key. Raised at parse
//     (`fromYamlString`) for the pure mode/entry conflict and unknown-mode
//     token, and at `validateAtBoot` for the role/overlay checks that need
//     injected boot dependencies (SCP-13).
//   * [UnknownProfileException] — a *request* fault: a `profile-<name>` marker
//     selecting a profile that does not exist. It is the boot/registry-level
//     analogue the edge (step 5) maps to the `400 invalid_api_key`
//     (`profile.unknown`) response (§ 8). It is not an operator config error, so
//     it is its own type rather than a `ProfileConfigException`.

/// An operator-side fault in the `profiles:` config block.
///
/// [code] is one of the spec § 8 stable codes; [path] is the dotted key path of
/// the offending node when known.
class ProfileConfigException implements Exception {
  /// Human-readable explanation.
  final String message;

  /// The stable § 8 failure code (e.g. `profile.mode_entry_conflict`), or
  /// `null` when the fault has no dedicated code.
  final String? code;

  /// The dotted config key path of the offending node (e.g.
  /// `profiles.research.role`), or `null` when not located.
  final String? path;

  /// Builds the exception with a [message] and the optional [code] / [path].
  const ProfileConfigException(this.message, {this.code, this.path});

  @override
  String toString() {
    final where = path == null ? '' : ' at $path';
    final what = code == null ? '' : ' [$code]';
    return 'ProfileConfigException$what$where: $message';
  }
}

/// A request selected a `profile-<name>` that the registry does not contain.
///
/// The edge (step 5) maps this to `400 invalid_api_key` with the § 8
/// `profile.unknown` code; the registry raises only the typed cause.
class UnknownProfileException implements Exception {
  /// The selected profile name that was not found.
  final String name;

  /// Builds the exception for the missing profile [name].
  const UnknownProfileException(this.name);

  @override
  String toString() => 'UnknownProfileException: no profile named "$name"';
}
