# tom_brain_smoke_prototype

The end-to-end **smoke harness** for the Tom Brain prototype — the higher
assembly that stands the whole cognition up and points the access process at
it on a local port.

## Why it exists

`tom_brain_access_prototype` (the running process) must not import
`tom_brain_substrate` / `tom_brain_memory`; it receives an already-booted
cognition through the `BrainProvisioner` seam, whose default *refuses* because
the access package cannot legally boot a brain on its own. This package is the
higher assembly the seam anticipates: it sits above all four brain packages and
is the only place that wires them together.

It boots `BrainProcessBoot` (stub substrate + in-isolate memory), projects the
resulting `RunCoordinator` onto a `QueueSnapshot`, hands back a
`ProvisionedBrain`, and calls `startBrainAccessProcess` to bind the OpenAI +
`/healthz` socket — exercising the real boot path the standalone access binary
cannot reach.

## Surface

| Symbol | Role |
|---|---|
| `SmokeSubstrate` | Stub `TomBrainSubstrateClient` — canned chunked answer + one-dim embedding. |
| `SmokeMemory` / `spawnSmokeMemory` | In-isolate `TomBrainMemory` double + its top-level factory. |
| `standUpSmokeProcess` | Boots the cognition and stands the access process up on a local port. |
| `SmokeProcess` | The live handle — the bound `BrainAccessProcess` + the in-process stub substrate. |

## Status

- **E.46 ✅** — Stand-up smoke: stub substrate + in-isolate memory + the OpenAI
  adapter on a local port. The E.46 test asserts the process binds a port,
  answers `GET /healthz` and `GET /v1/models`, and tears down cleanly.

Phase E.47+ (non-streaming roundtrip + memory inspection, streaming SSE,
Telegram loopback, kind-hint cache) build on this harness.
