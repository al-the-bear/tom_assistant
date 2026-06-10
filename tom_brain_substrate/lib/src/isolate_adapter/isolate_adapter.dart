// Barrel for the substrate `isolate_adapter/` module (Tom Brain
// completion-plan item #12).
//
// Owns the isolate-backed second implementation of
// `TomBrainSubstrateClient`. The first implementation is the in-process
// facade (`InProcessTomBrainSubstrate`); this module hosts a real client
// inside a worker isolate and marshals the surface across the boundary,
// independently re-checking the assistant-dedication anchor on every
// report it surfaces (`substrate_specification.md` § 3).
//
// Exported (the consumer-facing surface):
//
//   - `IsolateTomBrainSubstrateAdapter` — the proxy `TomBrainSubstrateClient`.
//   - `TomBrainSubstrateIsolateHost`    — the worker lifecycle owner.
//   - `SubstrateFactory`                — the top-level worker factory typedef.
//
// Intentionally **not** exported: the executor, the boot context, the
// envelope catalogue, the stream protocol, and the exception codec.
// They are construction details owned by the host; consumers drive the
// boundary through the adapter, never the wire types.
export 'isolate_tom_brain_substrate_adapter.dart'
    show IsolateTomBrainSubstrateAdapter;
export 'substrate_factory.dart' show SubstrateFactory;
export 'tom_brain_substrate_isolate_host.dart'
    show TomBrainSubstrateIsolateHost;
