// Memory-profile-name safety (memory_specification.md § 2.5).
//
// A profile name maps directly onto a filesystem path:
// `MemoryConfig.withProfile(name)` resolves the whole handle under
// `<root>/profiles/<name>/`. A name carrying a path separator or a
// `.`/`..` segment would let that path **escape** the `profiles/`
// directory, so every site that turns a profile name into a path must
// first reject such names.
//
// Two sites do that today: the `MemoryProfileRegistry` admin surface
// (`tom_brain_memory`) and the engine-side `ProfiledMemory` router
// (`tom_brain_procedure`), which under the per-profile-transport design
// (Option B / MSPP-23) maps a request's `memoryProfile` straight to a
// transport without passing through the registry. The rule is one
// concept, so it lives here — beside `MemoryConfig.withProfile`, the
// path mapping it protects — and both sites delegate to it.

/// The reserved profile name of the cross-profile aggregation tier
/// (memory_specification.md § 2.6, GA-1 / GA-2).
///
/// `<memory-root>/profiles/global/` holds the derive-only, read-only digest the
/// Aggregator writes from every other profile. It is a *reserved* name: no
/// request can ever bind it as its active (writable) profile, because a request
/// resolves a profile as `memoryPrefix + (selector ?? 'default')` and every
/// `memoryPrefix` is non-empty and ends in `_`, so no concatenation produces the
/// bare string `global`. The selector resolvers reject it as a *result* too
/// (defence in depth), while [validateMemoryProfileName] still accepts it as a
/// *directory* name (it is `_`-free and traversal-free) so the registry and the
/// Aggregator can address it.
const String reservedGlobalProfile = 'global';

/// Whether [name] is the reserved global-aggregation profile (GA-10).
///
/// Consumers that must distinguish a user profile from the aggregation tier
/// compare against this rather than the bare literal.
bool isReservedGlobalProfile(String name) => name == reservedGlobalProfile;

/// Whether [name] is a valid memory-profile name.
///
/// Valid means: non-empty, not the `.` or `..` segment, and free of any
/// path separator (`/` or `\`). That keeps the resolved
/// `<root>/profiles/<name>/` strictly one level below `profiles/` and
/// unable to escape it.
bool isValidMemoryProfileName(String name) => !(name.isEmpty ||
    name == '.' ||
    name == '..' ||
    name.contains('/') ||
    name.contains(r'\'));

/// Validates [name] as a memory-profile name, throwing an [ArgumentError]
/// (label `argName`, default `'profile'`) when [isValidMemoryProfileName]
/// is `false`.
///
/// The single guard the profile registry and the engine-side
/// `ProfiledMemory` router both apply before a name becomes a filesystem
/// path, so a hostile `../../…` selector can never materialise a store
/// outside `<root>/profiles/`.
void validateMemoryProfileName(String name, {String argName = 'profile'}) {
  if (!isValidMemoryProfileName(name)) {
    throw ArgumentError.value(
      name,
      argName,
      'profile name must be non-empty and contain no path separators '
          "or '.'/'..' segments",
    );
  }
}
