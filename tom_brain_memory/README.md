# tom_brain_memory

Self-organizing property-graph memory for Tom Brain. Storage, retrieval, cognitive agents, sleep cycles, MCP server, multi-machine sync, backup.

## Scope

This package owns the canonical knowledge graph that every Tom Brain component reads from. Per quest overview hard principle 4, memory is the **second author** of every answer the brain produces:

- Each thinking trail is augmented by retrieval over the graph.
- Each completed trail is folded back into the graph by the cognitive agents.

The thinking, planning, creation and procedure subsystems all reach memory through this package — directly (in-process), through an isolate adapter (same machine, different process), or through the MCP server (across machines).

## What lives here (planned per Phase A)

| Module | Source | Plan step |
|---|---|---|
| Top-level `TomBrainMemory` interface + `MemoryConfig` | `lib/src/api/` | A.24 |
| SQLite store + sqlite-vec + FTS5 driver | `lib/src/store/` | A.26 – A.34 |
| Migrations | `lib/src/migrations/` | A.35 |
| Node typing (Event, Claim, Concept, …) | `lib/src/nodes/` | A.36 – A.42 |
| Closed 12-edge alphabet | `lib/src/edges/` | A.43 – A.46 |
| Stacks (first-class mind-state lists) | `lib/src/stacks/` | A.47 – A.52 |
| Trails (JSONL append-only history) | `lib/src/trails/` | A.53 – A.56 |
| Four-mode retrieval (BM25, vector, graph, symbolic) | `lib/src/retrieval/` | A.57 – A.70 |
| LLM-independent classification | `lib/src/classification/` | A.71 – A.74 |
| MCP server (read-only v1) | `lib/src/mcp_server/` | A.75 – A.80 |
| Isolate adapter (in-process, same machine) | `lib/src/isolate_adapter/` | A.81 – A.84 |
| Configuration | `lib/src/config/` | A.85 |

## What does NOT live here

- Cognitive agents that *write* into memory live in `tom_brain_memory` itself, but the **scheduling** of sleep cycles is owned by the dispatcher (`tom_brain_procedure_dispatcher`).
- LLM provider integration — that is in `tom_brain_substrate`. Memory takes already-embedded vectors and already-classified texts; it does not call LLMs directly.
- The OpenAI-format gateway and Telegram bot — those are in `tom_brain_access`.

## Vector runtime precondition

`SqliteTomBrainMemory` **refuses to open** unless sqlite-vec's `vec0`
extension registers. Vector recall is mandatory — there is no BM25-only
fallback — so a store that cannot serve it must not pretend to be a store.
Two things have to hold, and they fail for different reasons:

1. **A packaged `vec0` binary exists for the running ABI**, under
   `tom_binaries/sqlite_vec/<platform>/`. Upstream does not publish every
   ABI (linux-armhf, for one), so this can legitimately be absent.
2. **The `libsqlite3` this process resolves supports extension loading.**

The second is the one that surprises people. `package:sqlite3` resolves the
platform's SQLite, and on **macOS** that is Apple's system build, compiled
with `SQLITE_OMIT_LOAD_EXTENSION`: it exports neither
`sqlite3_load_extension` nor `sqlite3_enable_load_extension`, and
`sqlite3_auto_extension` answers `SQLITE_MISUSE` (21). The `vec0` dylib
itself is fine — it opens, and `sqlite3_vec_init` resolves — but nothing can
register it. Windows is in the same position whenever `winsqlite3.dll` is
what resolves.

| Host | Resolved SQLite | Extension loading |
|---|---|---|
| Flutter desktop (`sqlite3_flutter_libs`) | the bundled full build | **yes** |
| plain `dart run` / `dart test` on Linux | distro `libsqlite3.so` | normally **yes** |
| plain `dart run` / `dart test` on macOS | Apple's `/usr/lib/libsqlite3.dylib` | **no** |
| plain `dart run` / `dart test` on Windows | `sqlite3.dll` if on the search path, else `winsqlite3.dll` | depends |

### The host-library repair

A capable `libsqlite3` is usually already on a developer macOS box —
Homebrew's `sqlite` formula builds one with extension loading enabled — it
is simply not what `package:sqlite3` resolves. `SqliteHostLibrary` looks for
one and points `package:sqlite3` at it through the public
`open.overrideFor` seam. Search order:

1. `$TOM_SQLITE3_LIB` — an explicit path, honoured on every platform. The
   escape hatch for a host whose capable library lives somewhere the
   built-in guesses do not cover.
2. Homebrew's `sqlite` prefixes, macOS only: `/opt/homebrew/opt/sqlite/lib/…`
   then `/usr/local/opt/sqlite/lib/…`.

A candidate is accepted only if it opens **and** exports
`sqlite3_enable_load_extension`.

Three properties of the repair are load-bearing:

- **It is conditional.** It runs only where the default is *known* to be
  incapable, so a Flutter or Linux host keeps the SQLite it already has and
  nothing machine-dependent is introduced where correct behaviour existed.
- **It is production behaviour, not test support.** This package ships
  `bin/memory_mcp_server.dart`, a plain-Dart-VM host that hits the same wall;
  a fix confined to test support would leave that executable unrunnable on
  macOS while making the suite green — precisely the wrong way round.
  `SqliteTomBrainMemory` defaults its handle to `extensionCapableSqlite3`,
  so every consumer inherits the repair without asking for it.
- **Order matters.** `package:sqlite3` caches its `Sqlite3` instance on first
  access, so an override installed afterwards is a silent no-op. Always
  reach for `extensionCapableSqlite3`, never the bare `sqlite3` getter — and
  if the override does arrive late, `ensureExtensionCapableSqlite()` detects
  it and reports `SqliteHostLibraryOutcome.overrideTooLate` rather than
  claiming a repair that did not happen.

Diagnose a host with `ensureExtensionCapableSqlite()` — or read the last
verdict, side-effect free, from `sqliteHostLibraryResolution`. Its `summary`
is written for an operator and names the remedy. A `VectorRuntimeUnavailable`
carries that same summary in its `toString()` when the host library is the
cause.

### Stating the precondition in tests

`VectorRuntimeProbe.probe()` answers "can this process serve vector recall?"
by **running the real load once**, not by checking that the binary is on
disk — a presence check passes on macOS, where the file is there and the
load still fails, which would put a green gate in front of a red test.

It exposes the two conditions separately, because they are different
questions:

- `binariesSkipReason` — is a `vec0` binary published for this ABI? Enough
  for a test that only needs the path.
- `skipReason` — can it actually register? Strictly stronger; what anything
  that opens the store needs. Pass it straight to a test's `skip:`.

`test/vector_runtime_precondition_test.dart` states the verdict for the
running host and is the **first thing to read in a failure triage**: if it
reports "not available", every store-touching failure in the suite has that
one cause. It deliberately does *not* gate the other tests — on a host with a
capable SQLite they pass for real, which is worth more than a skip.

`package:tom_spec_engine` reuses the same probe rather than carrying a copy.

## Status

Phase A — step A.21 scaffold complete. Empty barrel; smoke test only. Real surface lands from A.22 onwards.

## See also

- `_ai/quests/tom_brain/memory_specification.md` — the authoritative contract this package implements.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase A steps A.21 – A.94 own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
