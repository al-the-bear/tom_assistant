// `MemoryProfileSelector` — access' Extension-H memory-profile selection
// (access spec § 7.4; hub § 23.6, Q-H.9; plan step #32).
//
// Access owns the session, so access owns *which memory profile* a
// conversation recalls against. On the first admitted prompt of a session,
// when `selection.enabled`, the `SessionManager` runs a `MemoryProfileSelector`
// — the `profile_selector` substrate role, behind this interface so access
// stays decoupled from the substrate transport. The selector is given the
// prompt (and, when `selection.useHistory`, the full conversation history) and
// the known profile names, and returns a `(profile, confidence)` pick plus
// whether that pick names a real profile.
//
// The state machine that consumes a [ProfileSelection] — pin on confidence,
// fall back to the default on inconclusive / unknown / unavailable, and re-run
// every `recheckEveryNTurns` turns until confident — lives in the
// `SessionManager` (it owns the per-session state). This file owns only the
// narrow selector contract and the value types that cross it.
//
// PE-1 / layering: this is an *interface*. The concrete, substrate-backed
// selector is wired by the host at boot (it depends on the substrate client),
// exactly as the substrate `profile_selector` role call is anchor-carrying and
// budgeted there; access never reaches the substrate itself.

import 'package:tom_brain_shared/tom_brain_shared.dart' show HistoryTurn;

/// The wire code recorded when the selected profile names no known profile —
/// the conversation falls back to the default and selection stays inconclusive
/// (access spec § 7.4; § 14).
const String accessProfileUnknownCode = 'access.profile.unknown';

/// The wire code recorded when the `profile_selector` substrate call fails —
/// the conversation falls back to the default and selection stays inconclusive
/// (PE-6 graceful degrade; access spec § 7.4; § 14).
const String accessProfileSelectorUnavailableCode =
    'access.profile.selector.unavailable';

/// The wire code recorded when a previously inconclusive selection becomes
/// confident and the session re-pins to a new profile (access spec § 7.4).
const String accessProfileRepinnedCode = 'access.profile.repinned';

/// One run of the `profile_selector` role: the picked profile name, the
/// model's confidence in `[0, 1]`, and whether the pick matches a real profile
/// in the registry (`memory.profiles.list`). The selector resolves
/// [isKnownProfile] because it is the side that holds the candidate list; the
/// `SessionManager` only decides what to do with the pick.
final class ProfileSelection {
  /// Builds a selection result.
  const ProfileSelection({
    required this.profile,
    required this.confidence,
    this.isKnownProfile = true,
  });

  /// The profile name the role picked.
  final String profile;

  /// The role's confidence in the pick, in `[0, 1]`.
  final double confidence;

  /// Whether [profile] matched a known memory profile. `false` drives the
  /// `access.profile.unknown` fall-back.
  final bool isKnownProfile;
}

/// Selects the memory profile a conversation should recall against.
///
/// Implementations call the `profile_selector` substrate role with the prompt,
/// the conversation [history] (empty when first-prompt-only), and the known
/// profile names, returning a [ProfileSelection]. A failure to reach the role
/// is signalled by **throwing** — the `SessionManager` catches it and degrades
/// to the default profile (`access.profile.selector.unavailable`, PE-6).
abstract interface class MemoryProfileSelector {
  /// Runs one selection pass. [history] is the full conversation when
  /// `selection.useHistory` is set, or empty for first-prompt-only selection.
  /// Throws on substrate unavailability.
  Future<ProfileSelection> select({
    required String prompt,
    required List<HistoryTurn> history,
  });
}

/// What one [SessionManager.selectMemoryProfile] pass did — the access-side
/// diagnostic the assembler stamps onto the `Session` and (optionally) turns
/// into an observability event, mirroring how the `SessionResolution` flags
/// drive the `access.session.*` events.
enum MemoryProfileSelectionStatus {
  /// Selection is off (`selection.enabled` false) or no selector is wired —
  /// the conversation uses the process default profile (no pinned name).
  disabled,

  /// A confident pick on the first selection — the session is now pinned.
  pinned,

  /// A confident pick after a prior inconclusive selection — the session
  /// re-pins (`access.profile.repinned`).
  repinned,

  /// The pick was below `inconclusiveThreshold` — the default profile is used
  /// and the selector will re-run after the re-check window.
  inconclusive,

  /// Within the re-check window after an inconclusive selection — no selector
  /// call this turn; the default profile continues.
  deferred,

  /// A confident profile is already pinned — reused with no selector call.
  alreadyPinned,

  /// The picked profile matched no known profile — fall back to the default,
  /// stay inconclusive (`access.profile.unknown`).
  profileUnknown,

  /// The selector call failed — fall back to the default, stay inconclusive
  /// (`access.profile.selector.unavailable`, PE-6).
  selectorUnavailable,
}

/// The result of one profile-selection pass over a session.
final class MemoryProfileSelectionOutcome {
  /// Builds an outcome.
  const MemoryProfileSelectionOutcome({
    required this.status,
    required this.profile,
    this.confidence,
    this.code,
  });

  /// What the pass did.
  final MemoryProfileSelectionStatus status;

  /// The effective profile name for this conversation: the pinned name when
  /// confident, the `selection.default` profile when degraded/inconclusive,
  /// or `null` when selection is off (process default). This is what the
  /// `Session.memoryProfile` is stamped with.
  final String? profile;

  /// The selector's confidence, when a selector ran this pass; else `null`.
  final double? confidence;

  /// The `access.profile.*` wire code, when the pass degraded or re-pinned;
  /// `null` for the plain pin / reuse / disabled paths.
  final String? code;
}
