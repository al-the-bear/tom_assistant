// ProfiledMemory — the engine-side per-profile memory router (plan step 6;
// `memory_session_profiles.md` § 8, decision D-4 / MSPP-23).
//
// A `memoryProfile` must select a *separate database* (`<root>/profiles/<name>/`),
// not merely tag a log bucket: two requests carrying different memory selectors
// must write disjoint nodes, and a recall in profile A must never see profile
// B's nodes (the MSP-1 isolation invariant).
//
// ── Why a provider in front of the transport (Option B, MSPP-23) ──────────
//
// The originally-sketched design put a `Map<profile, store>` *behind* the
// isolate transport and threaded a `profile` field through every one of the
// ~50 `mem.*` request envelopes. That is a large, error-prone refactor and
// leaves every tenant's store in one isolate, where a selection bug can read
// the wrong store. Instead, [ProfiledMemory] holds the map *in front of* the
// transport and provisions each non-default profile as **its own transport**
// (its own isolate in production, its own in-process store in tests) via the
// existing [MemoryProvisioner]. Separate transports physically cannot
// cross-contaminate — the strongest possible isolation — and the isolate
// envelopes, host, and executor are untouched.
//
// The engine consults [forProfile] once per run (the run's `profile` is already
// threaded to every nested run), binding that run's `RunRecorder` and
// `MemoryBridge` to the resolved client. The default profile reuses the
// boot-provisioned client unchanged.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, TomBrainMemoryClient;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show validateMemoryProfileName;

import 'memory_provisioning.dart' show ProvisionedMemory;

/// The canonical default memory profile (`memory_session_profiles.md` § 8.1 /
/// MSP-4: the unprofiled root becomes `defaultmemory_default` after migration).
///
/// A request whose `memoryProfile` is `null`, empty, or exactly this value runs
/// against the boot-provisioned default client rather than a separately
/// provisioned per-profile transport.
const String defaultMemoryProfile = 'defaultmemory_default';

/// Provisions one opened [ProvisionedMemory] for the given profile-bound
/// [MemoryConfig]. Supplied by the assembler so [ProfiledMemory] stays
/// transport-agnostic: production hands it a callback that spawns an isolate
/// (mirroring the boot transport); tests hand it one that opens an in-process
/// store. The returned memory must already be opened against [config].
typedef ProvisionForConfig = Future<ProvisionedMemory> Function(
  MemoryConfig config,
);

/// Routes a run's `memoryProfile` to the [TomBrainMemoryClient] bound to that
/// profile's database, opening and caching one transport per profile per
/// process.
///
/// Lifetime: the default client is owned by the caller (the boot/run layer) and
/// is **not** disposed here; every per-profile transport this provider spawns is
/// owned here and torn down on [dispose].
final class ProfiledMemory {
  /// Builds a router over a profile-unbound [baseConfig].
  ///
  /// [baseConfig] is the process memory config with no profile bound; each
  /// non-default profile is provisioned against `baseConfig.withProfile(name)`
  /// (so it lands under `<root>/profiles/<name>/`). [defaultClient] is the
  /// already-open client every default-profile run reuses. [provision] opens a
  /// fresh transport for a profile-bound config. [defaultProfile] names the
  /// selector that maps to [defaultClient] (defaults to [defaultMemoryProfile]).
  ProfiledMemory({
    required this.baseConfig,
    required TomBrainMemoryClient defaultClient,
    required ProvisionForConfig provision,
    this.defaultProfile = defaultMemoryProfile,
  })  : _defaultClient = defaultClient,
        _provision = provision;

  /// The profile-unbound process memory config. Each non-default profile is
  /// provisioned against `baseConfig.withProfile(<profile>)`.
  final MemoryConfig baseConfig;

  /// The selector that resolves to the boot-provisioned [_defaultClient].
  final String defaultProfile;

  final TomBrainMemoryClient _defaultClient;
  final ProvisionForConfig _provision;

  /// Opened per-profile transports, keyed by profile id. Excludes the default
  /// profile (which reuses [_defaultClient]).
  final Map<String, ProvisionedMemory> _byProfile = <String, ProvisionedMemory>{};

  /// In-flight opens, keyed by profile id, so concurrent first-touch requests
  /// for the same profile share one provisioning rather than racing to spawn
  /// two transports for one database.
  final Map<String, Future<TomBrainMemoryClient>> _opening =
      <String, Future<TomBrainMemoryClient>>{};

  bool _disposed = false;

  /// Whether [profile] resolves to the default client rather than a separately
  /// provisioned transport.
  bool _isDefault(String? profile) =>
      profile == null || profile.isEmpty || profile == defaultProfile;

  /// Returns the client bound to [profile], provisioning + caching it on first
  /// use. A `null` / empty / default-named profile resolves to the
  /// boot-provisioned default client.
  ///
  /// A non-default [profile] is validated as a safe profile name *before* any
  /// provisioning (path-traversal guard, MSPP-25): under the per-profile
  /// transport design this router maps the name straight to a
  /// `<root>/profiles/<name>/` path without passing through the
  /// `MemoryProfileRegistry`, so a name carrying a path separator or a `.`/`..`
  /// segment is rejected here with an [ArgumentError] rather than allowed to
  /// materialise a store outside the profiles directory. No directory is created
  /// for a rejected name.
  Future<TomBrainMemoryClient> forProfile(String? profile) async {
    if (_disposed) {
      throw StateError('ProfiledMemory.forProfile after dispose()');
    }
    if (_isDefault(profile)) return _defaultClient;
    final key = profile!;
    validateMemoryProfileName(key);

    final cached = _byProfile[key];
    if (cached != null) return cached.client;

    final inFlight = _opening[key];
    if (inFlight != null) return inFlight;

    final opening = _open(key);
    _opening[key] = opening;
    try {
      return await opening;
    } finally {
      _opening.remove(key);
    }
  }

  Future<TomBrainMemoryClient> _open(String profile) async {
    final provisioned = await _provision(baseConfig.withProfile(profile));
    _byProfile[profile] = provisioned;
    return provisioned.client;
  }

  /// Tears down every per-profile transport this provider spawned. Idempotent —
  /// a second call is a no-op, so it is safe in a `finally` block. The default
  /// client is **not** disposed (the boot/run layer owns it).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final provisioned = _byProfile.values.toList(growable: false);
    _byProfile.clear();
    for (final memory in provisioned) {
      await memory.dispose();
    }
  }
}
