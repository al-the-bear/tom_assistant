// Barrel for the `cognitive_agents/` module in `tom_brain_shared`
// (Plan step A.70).
//
// What this module owns (shared layer):
//
//   * `AgentRegistration` — the per-agent registry value memory uses
//     to attribute writes (`producedBy`) and to enforce read/write
//     scopes. Living in shared because both memory (enforcement) and
//     the dispatcher (population, serialisation) consume it.
//
// What this module does NOT own:
//
//   * The runtime registry (`AgentRegistry`) and the
//     `AgentScopeViolation` exception. Both live in `tom_brain_memory`
//     because they belong to the enforcement layer; the value type
//     stays here, the enforcement machinery stays close to the
//     write paths it guards.

export 'agent_registration.dart' show AgentRegistration;
