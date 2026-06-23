// SqliteMemoryProfileRegistry — filesystem-backed concrete
// `MemoryProfileRegistry` (memory_specification.md § 2.5).
//
// A profile is an isolated `<memory-root>/profiles/<name>/` tenant.
// This registry administers that tier on top of the on-disk store:
//
//   * `list` / `exists` introspect the `<root>/profiles/` directory.
//   * `createProfile` / `seedProfile` materialise a profile by opening
//     a short-lived child `SqliteTomBrainMemory` bound to the profile
//     (via `MemoryConfig.withProfile`), letting `open()` build the full
//     layout + bootstrap catalogue, then closing it. Seeding persists
//     each draft through that child handle.
//   * `dropProfile` is a whole-store delete: it removes the entire
//     `<root>/profiles/<name>/` directory (reset-to-zero), distinct
//     from the per-event `forget` on the data plane.
//
// The registry never holds a long-lived child handle: every operation
// opens, works, and closes. That keeps the contract simple (no nested
// open store to track through the parent's lifecycle) at the cost of a
// store open per call — acceptable for an administration surface that
// is not on any hot path.
//
// Events ride the *parent* store's bus: the registry takes the parent's
// `emit` sink and emits `ProfileCreated` / `ProfileDropped` there, so a
// subscriber on the parent `events()` feed sees profile lifecycle
// (memory § 16). The child store's own events (NodeTypeRegistered,
// NodePersisted from seeding) land on the child's bus and are
// discarded when it closes — they are an implementation detail of
// materialisation, not the profile-admin signal.
//
// Why the child-store factory rather than importing the concrete store
// directly: the composition root (`SqliteTomBrainMemory.open`) owns
// store construction and threads its injected `sqlite` / `clock` into
// the factory. The registry depends only on the abstract
// `TomBrainMemory` surface, so it neither knows nor cares which
// concrete store it spawns.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Clock,
        MemoryConfig,
        MemoryEvent,
        MemoryProfileRegistry,
        NodeDraft,
        Scope,
        TomBrainMemoryClient,
        validateMemoryProfileName;

import '../api/tom_brain_memory.dart';
import '../config/memory_config_paths.dart';
import 'profile_events.dart';

/// Filesystem-backed [MemoryProfileRegistry] over the
/// `<memory-root>/profiles/` tier.
///
/// Constructed by the composition root (`SqliteTomBrainMemory.open`)
/// from the profile-unbound base config the parent store was opened
/// with, a factory that mints child stores sharing the parent's
/// `sqlite` / `clock`, the parent event bus's `emit` sink, and the
/// clock for event timestamps.
final class SqliteMemoryProfileRegistry implements MemoryProfileRegistry {
  /// The profile-**unbound** base config of the owning store. Child
  /// handles are spawned from `baseConfig.withProfile(name)`.
  final MemoryConfig _baseConfig;

  /// Mints a fresh, unopened child store sharing the parent's injected
  /// `sqlite` runtime and `clock`.
  final TomBrainMemory Function() _childStoreFactory;

  /// The parent store's event sink — profile lifecycle events land
  /// here so they surface on the parent `events()` feed.
  final void Function(MemoryEvent) _emit;

  /// Clock for event timestamps (UTC-coerced at emission).
  final Clock _clock;

  SqliteMemoryProfileRegistry({
    required MemoryConfig baseConfig,
    required TomBrainMemory Function() childStoreFactory,
    required void Function(MemoryEvent) emit,
    required Clock clock,
  })  : _baseConfig = baseConfig,
        _childStoreFactory = childStoreFactory,
        _emit = emit,
        _clock = clock;

  String get _profilesDir => _baseConfig.profilesDir;

  String _profileDir(String name) =>
      '$_profilesDir${Platform.pathSeparator}$name';

  @override
  Future<List<String>> list() async {
    final dir = Directory(_profilesDir);
    if (!dir.existsSync()) return <String>[];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(Platform.pathSeparator).last)
        .where((name) => name.isNotEmpty)
        .toList();
  }

  @override
  Future<bool> exists(String name) async {
    _validateName(name);
    return Directory(_profileDir(name)).existsSync();
  }

  @override
  Future<void> createProfile(String name) async {
    _validateName(name);
    // Idempotent: an existing profile is left untouched and does not
    // re-emit (memory § 16 one-event-per-effective-mutation).
    if (Directory(_profileDir(name)).existsSync()) return;
    await _materialise(name);
    _emit(ProfileCreated(profileName: name, occurredAt: _now()));
  }

  @override
  Future<void> seedProfile(
    String name,
    List<NodeDraft> drafts, {
    required Scope scope,
  }) async {
    _validateName(name);
    final store = _childStoreFactory();
    await store.open(_baseConfig.withProfile(name));
    try {
      for (final draft in drafts) {
        await store.persist(draft, scope: scope);
      }
    } finally {
      await store.close();
    }
  }

  @override
  Future<void> dropProfile(String name) async {
    _validateName(name);
    final dir = Directory(_profileDir(name));
    // A drop of an absent profile is a no-op and emits nothing.
    if (!dir.existsSync()) return;
    dir.deleteSync(recursive: true);
    _emit(ProfileDropped(profileName: name, occurredAt: _now()));
  }

  @override
  Future<T> readInProfile<T>(
    String name,
    Future<T> Function(TomBrainMemoryClient body) body,
  ) async {
    _validateName(name);
    // Same open/work/close lifecycle as seedProfile: a transient child
    // handle bound to `name`, closed in finally even when `body` throws.
    // `body` sees the TomBrainMemoryClient surface (read-shaped by the
    // interface), so this view-scoping seam can never write.
    final store = _childStoreFactory();
    await store.open(_baseConfig.withProfile(name));
    try {
      return await body(store);
    } finally {
      await store.close();
    }
  }

  /// Opens a child store bound to [name] just long enough for `open()`
  /// to build the full layout + bootstrap catalogue, then closes it.
  Future<void> _materialise(String name) async {
    final store = _childStoreFactory();
    await store.open(_baseConfig.withProfile(name));
    await store.close();
  }

  DateTime _now() => _clock.now().toUtc();

  /// Rejects any name that could escape the `profiles/` directory.
  ///
  /// Delegates to the shared [validateMemoryProfileName] guard
  /// (`tom_brain_shared`), the single source of truth this registry and
  /// the engine-side `ProfiledMemory` router both apply before a name
  /// becomes a `<root>/profiles/<name>` path.
  static void _validateName(String name) => validateMemoryProfileName(name);
}
