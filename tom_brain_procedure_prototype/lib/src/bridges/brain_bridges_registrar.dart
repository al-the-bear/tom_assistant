// BrainBridges — the engine's d4rt bridge-registration entrypoint
// (Plan step C.14; `tom_brain_procedure_prototype_specification.md` § 3).
//
// ── Why this file is hand-authored ──────────────────────────────────
//
// In the pinned generator (`tom_d4rt_generator 1.8.24`) the
// `generateDartscript` feature emits a `dartscript.b.dart` that does not
// compile: its template imports a `relaxers.b.dart` the builder never
// writes and calls `<Module>Bridge.subPackageBarrels()`, a method the
// per-package-orchestrator delegating barrel (`AllBridge`) never emits.
// See `build.yaml` (Q-C.14.1) for the full diagnosis. `generateDartscript`
// is therefore OFF, and this file provides the `BrainBridges.register`
// entrypoint the rest of the prototype (the C.16 host) expects.
//
// This is **host wiring, not a reimplementation of generator behaviour**:
// every bridge *definition* — constructors, methods, signatures,
// primitive⇄domain coercion — is still produced by the generator
// (`AllBridge` / `PackageTomBrainProcedurePrototypeBridge`). This class
// only composes the cleanly-generated `AllBridge.registerBridges` under
// the two source-file library paths d4rt scripts import the bridges from,
// exactly as the (broken) generated dartscript intended. The
// generic-constructor / relaxer / sub-package-barrel registrations the
// dartscript template also emits are no-ops for this package: its two
// bridges are primitive-typed, declare no generics, re-export no
// sub-packages, and need no relaxer wrappers.
//
// When the generator is fixed and republished (Q-C.14.1), this file is
// deleted and `generateDartscript` re-enabled — no consumer changes,
// because `BrainBridges.register(d4rt)` is the same contract either way.

import 'package:tom_d4rt/d4rt.dart';

import 'brain_bridges.b.dart';

/// Registers the engine's two bridges (`MemoryBridge`, `SubstrateBridge`)
/// — plus the `LlmCompletionFailure` value carried by the substrate
/// bridge — with a D4rt [interpreter].
///
/// Mirrors the registration the generated dartscript file would perform:
/// the bridges are registered under each source-file library path so a
/// d4rt procedure script can import them from either
/// `lib/src/bridges/memory_bridge.dart` or
/// `lib/src/bridges/substrate_bridge.dart`.
class BrainBridges {
  const BrainBridges._();

  /// The library URI under which the memory bridge is importable from a
  /// d4rt script. This is the canonical `package:` URI — the same value
  /// the generated `classSourceUris()` records for `MemoryBridge`.
  ///
  /// It must be a `package:` URI (not a relative path): d4rt's
  /// `ModuleLoader` resolves `package:` imports directly against the
  /// registered-library map, whereas a relative import requires a
  /// filesystem base URI the interpreter does not have at script-execute
  /// time.
  static const String memoryLibrary =
      'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';

  /// The library URI under which the substrate bridge is importable from a
  /// d4rt script. Canonical `package:` URI for `SubstrateBridge`'s source
  /// file (see [memoryLibrary] for why a `package:` URI is required).
  static const String substrateLibrary =
      'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';

  /// Registers every generated bridge with [interpreter] under both
  /// bridge library paths. Idempotent at the call-site level: callers
  /// register once per interpreter at host boot (C.16).
  static void register(D4rt interpreter) {
    AllBridge.registerBridges(interpreter, memoryLibrary);
    AllBridge.registerBridges(interpreter, substrateLibrary);
  }
}
