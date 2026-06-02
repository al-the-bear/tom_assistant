// Identity, session, and persona resolution.
//
// Owns `IdentityResolver` (OpenAI bearer tokens + Telegram user-ids →
// internal `TomPrincipal`), `SessionManager` (a sliding window keyed by
// principal / channel / conversation-id, persisted as `Session` nodes in
// memory), and `PersonaResolver` (model-id-or-default → `Persona`
// template, handed to substrate via the `Access` object). See
// `tom_brain_access_prototype_specification.md` § Identity and Plan
// steps E.24 – E.27.
//
// At E.8 this folder is intentionally empty. No exports yet.
