// MemoryFactory — the top-level/static factory the host hands to
// the spawned isolate to construct the in-isolate `TomBrainMemory`
// instance (plan step A.79).
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
// Why the factory constructs an *unopened* memory:
//
//   `MemoryConfig` only arrives at `open()` time (§ 14 of
//   `memory_specification.md` is explicit that config is parsed
//   upstream and passed in). Construction and opening are separate
//   lifecycle steps; the host exercises them through two distinct
//   envelopes (`OpenMemoryRequest` then `CloseMemoryRequest`), so
//   the factory's job is strictly construction. The first
//   `OpenMemoryRequest` after spawn drives `memory.open(config)`
//   inside the isolate.
//
// Tests use a top-level test fake (see `a79_isolate_host_test.dart`).
// Production wiring (Phase D) passes a top-level function in the
// composition root that returns `SqliteTomBrainMemory()` once A.28+
// has shipped.

import '../api/tom_brain_memory.dart';
import '../store/sqlite_tom_brain_memory.dart';

/// Constructs the in-isolate `TomBrainMemory` instance.
///
/// Must be a top-level or static function — closures captured from
/// the spawning isolate cannot cross the boundary.
///
/// Called exactly once per isolate, during
/// `TomWorkerContext.initializeIsolate` (i.e. before the worker
/// signals ready). The returned instance is held by the in-isolate
/// executor and exposed to incoming `IsolateRequest` envelopes.
///
/// The factory **must** return an *unopened* memory instance — the
/// host drives `memory.open(config)` via `OpenMemoryRequest` after
/// the worker is ready.
typedef MemoryFactory = Future<TomBrainMemory> Function();

/// The production [MemoryFactory]: constructs the concrete on-disk
/// [SqliteTomBrainMemory] store the isolate host hosts.
///
/// This is the top-level function the file-level doc above promised
/// "Production wiring … passes in the composition root". Passing it to
/// `TomBrainMemoryIsolateHost(factory: createSqliteTomBrainMemory)`
/// spawns a worker whose held memory is the real store; the host then
/// drives `memory.open(config)` via `OpenMemoryRequest`.
///
/// It satisfies the [MemoryFactory] sendability constraint — a
/// top-level tear-off captures no closure state — and returns an
/// *unopened* instance, leaving `open(config)` to the first
/// `OpenMemoryRequest`.
Future<TomBrainMemory> createSqliteTomBrainMemory() async =>
    SqliteTomBrainMemory();
