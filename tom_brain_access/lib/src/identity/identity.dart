// Identity, session, and persona resolution.
//
// Owns `IdentityResolver` (OpenAI bearer tokens + Telegram user-ids →
// internal `TomPrincipal`), `SessionManager` (the two-history conversation
// resolver — a per-(principal, channel) global history plus a per-session
// `ConversationHistory` keyed by a brain-minted id), and `PersonaResolver`
// (model-id-or-default → `Persona` template, handed to substrate via the
// `Access` object). See `tom_brain_access_specification.md`
// § 7.2 / § 21.2 and Plan steps E.24 – E.27.
//
// E.24 ✅ — `IdentityResolver` (+ `IdentityBinding`,
// `IdentityResolutionException`): credential → `TomPrincipal` →
// `ResolvedIdentity`, resolved once at the edge (AC-7).
// E.25 / Ext-G ✅ — `SessionManager` (+ `AccessChannel`, `SessionIdMinter`,
// `SessionResolution`, `SessionHistoriesSnapshot`): resolves every request
// against a global "all prompts" history and a per-session history, minting a
// fresh id when one is absent or unrecognised; hands the engine the history it
// answers from (§ 7.2 / § 21.2).
// E.26 ✅ — `PersonaResolver`: model-id-or-default → `Persona`, reusing the
// shared `OpenAiPersonaMapping.knownModels` vocabulary (AC-5).
// E.27 ⏳ — the resolution-test sweep (token / user-id / session / persona).

export 'history_markdown.dart';
export 'history_store.dart';
export 'identity_resolver.dart';
export 'memory_profile_selector.dart';
export 'persona_resolver.dart';
export 'session_manager.dart';
export 'telegram_command.dart';
export 'telegram_session_registry.dart';
