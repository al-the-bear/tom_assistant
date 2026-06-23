// ApiKeyRegistrar — the narrow live-admission seam `/create_api_key` mutates
// (memory_session_profiles.md § 7 / § 13, MSP-7, decision MSPP-42).
//
// ── Why this interface exists ────────────────────────────────────────
//
// A runtime-created credential must be live *immediately* — the next request
// bearing the new key has to authenticate (MSP-7). On the no-authenticator
// bearer path the assembler consults two structures for every token: the
// `IdentityResolver` (does this residual key resolve to a principal?) and
// `apiKeysByKey` (what session/memory namespace does it scope into?). Both must
// gain the new key together, or the key authenticates with no scope (or scopes
// with no authentication). [ApiKeyRegistrar] is the single operation that
// mutates *both* atomically, so the creator orchestration ([ApiKeyCreator]) and
// its rollback (§ 13) never have to know there are two maps.
//
// `AccessAssembler` implements it — it already owns both structures. The
// interface is kept separate (rather than handing the creator the whole
// assembler) so the orchestration + rollback are unit-testable against a fake
// registrar with no booted dispatcher.

import '../config/api_key_config.dart';

/// The live-admission seam for runtime API keys (MSP-7).
///
/// Implemented by `AccessAssembler`, which holds both the identity registry and
/// the `apiKeysByKey` namespace index. [admit] makes [config] authenticate *and*
/// scope on the next request; [revoke] reverses exactly that, so a failed
/// persist can roll the live change back to match disk (§ 13).
abstract interface class ApiKeyRegistrar {
  /// Admits [config] into the live registry: its key now authenticates (the
  /// identity binding) and scopes sessions/memory (the namespace index), taking
  /// effect on the very next request bearing it.
  void admit(ApiKeyConfig config);

  /// Removes [config] from the live registry — the exact reverse of [admit].
  /// Used to roll back a live admission when the durable persist fails (§ 13),
  /// so the running process never authenticates a key that did not survive to
  /// disk.
  void revoke(ApiKeyConfig config);
}
