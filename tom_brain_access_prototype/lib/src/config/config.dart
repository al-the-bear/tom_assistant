// Configuration.
//
// Owns the access-process YAML configuration loader (the single
// whole-process config file — substrate, memory, engine, dispatcher,
// access — loaded the `tom_build_base` way) plus the typed `access:`
// section it parses. See
// `tom_brain_access_prototype_specification.md` § 11.4 / § 13.1 and Plan
// step E.44.
//
// - E.44 ✅ — `AccessConfig` (`access_config.dart`): the typed `access:`
//   section of the whole-process YAML — the OpenAI adapter port + base
//   path, the Telegram bot token + the user-id whitelist (expressed as
//   identity bindings, one source of truth), the OpenAI bearer-token
//   bindings, the rate-limit / daily-quota / anchor-signature policies,
//   the persona vocabulary, the session window, and the embedding-cache
//   TTL. A pure data holder — it builds no runtime collaborator; the boot
//   root (E.45) maps it onto `BrainAccessConfig`, injecting the runtime
//   seams that are not config.
// - E.44 ✅ — `AccessConfigLoader` (`access_config_loader.dart`): parses
//   the single whole-process YAML file into an `AccessConfig`. Validates
//   the document's top-level shape (the five sibling sections
//   `substrate:` / `memory:` / `engine:` / `dispatcher:` / `access:` are
//   tolerated; any other root key is rejected — AC-12 forward-only) and
//   parses the `access:` block it owns. The other four sections are parsed
//   by their own already-defined loaders (`SubstrateConfigLoader`,
//   `MemoryConfigLoader`, `EngineConfig`, `DispatcherConfig`) at boot
//   wiring (E.45) — the access package never imports substrate / memory
//   (Q-E.44.1). Mirrors `SubstrateConfigLoader` / `MemoryConfigLoader`
//   (same `loadYaml` plumbing, dotted-key-path errors, `${ENV}`
//   substitution, no-I/O-until-`loadFromFile` discipline).

export 'access_config.dart';
export 'access_config_loader.dart';
