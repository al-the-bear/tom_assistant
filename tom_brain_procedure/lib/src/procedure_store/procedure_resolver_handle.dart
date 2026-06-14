// ProcedureResolverHandle — a refreshable holder around a [ProcedureResolver]
// that lets the engine pick up an edited script on the *next* run without a
// restart (`prompt_tracing.md` § 6.3, AUTH-5 — the brain pulls source on
// re-read; nothing pushes into it).
//
// The resolver itself stays an immutable snapshot (`procedure_resolver.dart`):
// "resolution is a pure function of a fixed index". This handle preserves that
// — it never mutates a resolver — and instead swaps the *current* snapshot for
// a freshly-built one when the underlying store's cheap signature changes. A
// run that asks the engine for the current resolver gets one fixed snapshot for
// its whole duration (the engine refreshes only at top-level-run entry, never
// mid-turn), so within-turn purity is intact; between turns, an edited script
// is reflected.
//
// Two shapes:
//   - [ProcedureResolverHandle.fixed] — no store, [maybeRefresh] is a no-op.
//     The default for tests and any deployment that does not want live reload.
//   - [ProcedureResolverHandle.reloading] — backed by a [ProcedureStore]; each
//     [maybeRefresh] re-stats the store (cheap, no body reads) and rebuilds the
//     resolver only when the signature changed.

import 'procedure_loader.dart';
import 'procedure_resolver.dart';
import 'procedure_store_interface.dart';

/// Holds the engine's *current* [ProcedureResolver] and, when backed by a
/// store, rebuilds it on demand when the store's contents change.
final class ProcedureResolverHandle {
  ProcedureResolver _current;

  /// The store to rebuild from, or `null` for a [fixed] handle that never
  /// reloads.
  final ProcedureStore? _store;

  /// The loader used to parse re-read sources. Unused by a [fixed] handle.
  final ProcedureLoader _loader;

  /// The store signature captured at the last (re)build, or `null` when no
  /// signature has been captured yet — a seeded [reloading] handle whose first
  /// [maybeRefresh] therefore rebuilds once to settle the signature (and pick
  /// up any edit made between boot and the first run).
  String? _signature;

  ProcedureResolverHandle._(
    this._current,
    this._store,
    this._loader,
    this._signature,
  );

  /// A handle over a fixed [resolver] that never reloads. [maybeRefresh]
  /// always returns `false`.
  factory ProcedureResolverHandle.fixed(ProcedureResolver resolver) =>
      ProcedureResolverHandle._(resolver, null, ProcedureLoader.shared, null);

  /// A reloading handle seeded with an already-built [initial] resolver over
  /// [store].
  ///
  /// Synchronous, so it fits the engine's synchronous constructor; the
  /// signature is left uncaptured, so the **first** [maybeRefresh] re-stats the
  /// store and rebuilds once (cheap — one parse of the script set, picking up
  /// any edit since boot), after which refreshes are signature-gated.
  factory ProcedureResolverHandle.reloading(
    ProcedureStore store,
    ProcedureResolver initial, {
    ProcedureLoader loader = ProcedureLoader.shared,
  }) =>
      ProcedureResolverHandle._(initial, store, loader, null);

  /// Builds a fully-settled reloading handle, reading and fingerprinting
  /// [store] up front so a no-change [maybeRefresh] is a true no-op from the
  /// first call.
  static Future<ProcedureResolverHandle> open(
    ProcedureStore store, {
    ProcedureLoader loader = ProcedureLoader.shared,
  }) async {
    final resolver = await ProcedureResolver.fromStore(store, loader: loader);
    final signature = await store.signature();
    return ProcedureResolverHandle._(resolver, store, loader, signature);
  }

  /// The current resolver snapshot.
  ProcedureResolver get current => _current;

  /// Whether this handle can reload (is backed by a store).
  bool get reloads => _store != null;

  /// Re-reads the backing store **iff** its cheap signature changed since the
  /// last build, swapping in a freshly-built resolver and returning `true` when
  /// it did. A [fixed] handle, or an unchanged store, returns `false` without
  /// re-reading any source body.
  Future<bool> maybeRefresh() async {
    final store = _store;
    if (store == null) return false;
    final signature = await store.signature();
    if (signature == _signature) return false;
    _current = await ProcedureResolver.fromStore(store, loader: _loader);
    _signature = signature;
    return true;
  }
}
