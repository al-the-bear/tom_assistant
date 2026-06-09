# tom_brain_smoke_prototype — Local Guidelines

Project-specific notes for the Tom Brain end-to-end smoke harness.

## What this project is

The **higher assembly** that wires the four Tom Brain prototype packages
together for the prototype's own end-to-end smoke (Plan Phase E.10, steps
E.46–E.50). It is the legally-correct place to import both
`tom_brain_substrate` and `tom_brain_memory` — the access package cannot, so it
takes a booted cognition through the `BrainProvisioner` seam this package
fulfils.

## Rules

- **This is the only package that may import all four brain packages at once.**
  Keep the substrate/memory imports here; never push them back down into
  `tom_brain_access`.
- **The doubles are top-level.** `SmokeMemory` and `spawnSmokeMemory` cross the
  isolate boundary (memory is provisioned isolate-transport), so the factory and
  the class it returns must stay top-level — mirroring the procedure prototype's
  `d43_memory_provisioning_test.dart` convention.
- **Bind ephemeral ports in tests.** `standUpSmokeProcess` binds port `0`
  (OS-assigned) by default; the real bound port is read back from
  `SmokeProcess.process.port`. Do not hard-code a fixed port in tests.
- **No backwards compatibility** (initial implementation). Migrate every call
  site in the same change when a contract moves.

## Reference patterns

- Stub substrate: `tom_brain_procedure/test/d44_brain_process_boot_test.dart`
  (`_AnsweringSubstrate`).
- In-isolate memory double + factory:
  `tom_brain_procedure/test/d43_memory_provisioning_test.dart`
  (`RecordingFakeMemory` + `spawnRichFakeMemory`).
