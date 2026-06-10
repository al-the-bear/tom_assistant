// SubstrateFactory — the top-level/static factory the host hands to
// the spawned isolate to construct the in-isolate
// `TomBrainSubstrateClient` instance (Tom Brain completion-plan
// item #12).
//
// Why a typedef rather than a class:
//
//   The factory crosses an isolate boundary as part of the
//   `TomWorkerContext` argument to `Isolate.spawn`. Dart isolates
//   reject closures that capture state from the spawning isolate —
//   the function reference must be either *top-level* or *static*.
//   Encoding the contract as a `typedef` keeps that constraint
//   obvious at every call site: the symbol passed in is named, and
//   the named symbol is one a reader can grep for.
//
// Why the factory constructs an *already-usable* client (unlike the
// memory factory, which returns an unopened store):
//
//   The in-process facade has no require-open guard for `complete` /
//   `embed` — `open(SubstrateConfig)` only seeds provider credentials
//   and cooldown state, which the stub/Ollama defaults already carry.
//   So the worker builds the client eagerly inside
//   `SubstrateWorkerContext.initializeIsolate` and the host's
//   `open(config)` envelope is optional. The factory's job is strictly
//   construction; any config arrives later via `OpenSubstrateRequest`.

import '../api/tom_brain_substrate_client.dart';

/// Constructs the in-isolate `TomBrainSubstrateClient` instance.
///
/// Must be a top-level or static function — closures captured from
/// the spawning isolate cannot cross the boundary.
///
/// Called exactly once per isolate, during
/// `SubstrateWorkerContext.initializeIsolate` (i.e. before the worker
/// signals ready). The returned instance is held by the in-isolate
/// executor and exposed to incoming `IsolateRequest` envelopes.
typedef SubstrateFactory = Future<TomBrainSubstrateClient> Function();
