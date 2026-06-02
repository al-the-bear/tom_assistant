# Changelog

## 0.0.1 — 2026-06-02 (Phase E.46)

- **New project.** `tom_brain_smoke_prototype` — the higher-assembly end-to-end
  smoke harness for the Tom Brain prototype (Plan step E.46).
- `SmokeSubstrate` — a top-level stub `TomBrainSubstrateClient` (canned chunked
  answer stream + a one-dim embedding), modelled on the procedure prototype's
  `_AnsweringSubstrate`.
- `SmokeMemory` + `spawnSmokeMemory` — a top-level in-isolate `TomBrainMemory`
  double and its top-level factory, modelled on the procedure prototype's
  `RecordingFakeMemory`.
- `standUpSmokeProcess` — boots `BrainProcessBoot` (stub substrate + in-isolate
  memory), projects its `RunCoordinator` onto a `QueueSnapshot`, hands back a
  `ProvisionedBrain`, and calls `startBrainAccessProcess` to bind the OpenAI +
  `/healthz` socket on a local (ephemeral by default) port — returning a
  `SmokeProcess` handle.
