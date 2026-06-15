# Running the Tom Brain Observatory

The observatory is a **read-only** window onto a running (or finished) Tom Brain:
one process serves the Trail Read API under `/api` and the embedded Flutter-web
UI under `/`, from a single loopback origin. It never writes the trail tree,
never writes memory, never opens a DB file, and holds no control path into the
brain (OBS-1…OBS-5, `prompt_tracing.md` § 6.2 — proven by
`test/obs_conformance_test.dart`). You can point it at a live brain's trail tree
while the brain runs; reading is indistinguishable from not reading.

## 1. Build the web UI (once, or after UI changes)

```bash
cd ../tom_brain_observatory_web
flutter build web
```

This produces `build/web/`, which the backend serves at `/`. If it is absent,
the backend still starts and serves the `/api` surface only.

## 2. Launch the backend against a trail tree

```bash
cd tom_brain_observatory
dart run bin/observatory.dart <trail-host-root> \
  [--web=<dir>] [--scripts=<dir>] [--cognition=<dir>] [--run-config=<dir>] \
  [--memory-mcp-url=<url>] [--memory-mcp-token=<token>] \
  [--port=N] [--host=ADDR]
```

| Argument | Meaning | Default |
|---|---|---|
| `<trail-host-root>` | The trail tree to read, e.g. `_ai/tom_brain_trail/<host>` | required |
| `--web=<dir>` | The `flutter build web` output served at `/` | `../tom_brain_observatory_web/build/web` |
| `--scripts=<dir>` | The brain's `scripts/system` dir, served read-only by `GET /api/procedures/<id>` | `../tom_brain_procedure/scripts/system` |
| `--cognition=<dir>` | The brain's cognition root (registry + per-procedure configs + templates + roles). Drives `GET /api/catalogue` and the template routes — **this is the gear/Configuration page**. Without it, the catalogue 503s "config unavailable" | none |
| `--run-config=<dir>` | The root the substrate config (`brain_run.yaml`) resolves against for `GET/PUT /api/config?kind=substrate` | `--cognition` |
| `--memory-mcp-url=<url>` | The running memory MCP server's `/mcp` endpoint (§ 4 below). Without it, `GET /api/memory/*` 503s "memory unavailable" | none |
| `--memory-mcp-token=<token>` | Optional bearer forwarded to the memory MCP endpoint | none (anonymous loopback) |
| `--port=N` | Loopback port | `8787` |
| `--host=ADDR` | Bind address (loopback-only by design) | `127.0.0.1` |

Example — observe the local brain on this host, with the catalogue (gear)
page and memory monitoring both wired:

```bash
# 1. Start the read-only memory MCP server against the brain's run config
#    (a separate process — its store handle is what keeps OBS-3 intact).
dart run ../tom_brain_memory/bin/memory_mcp_server.dart \
  ../tom_brain_run/config/$(hostname -s)/brain_run.yaml --port 8765 &
#    It prints `MCP_HTTP_PORT=8765`.

# 2. Start the observatory, pointing --cognition at the brain's cognition root
#    (enables the gear page) and --memory-mcp-url at the server above.
dart run bin/observatory.dart ../../_ai/tom_brain_trail/$(hostname -s) \
  --cognition=../tom_brain_run/config/$(hostname -s)/cognition \
  --memory-mcp-url=http://127.0.0.1:8765/mcp
```

Then open the printed URL (e.g. <http://127.0.0.1:8787/>) in a browser. The
gear icon opens the Configuration catalogue; the memory icon opens Module 2.

## 3. Loopback against a brain on another fleet host

The backend binds `127.0.0.1`, so to view a brain running on `bomber` from your
laptop, tunnel the loopback port over SSH rather than exposing it:

```bash
# On the remote host, launch the observatory against its trail tree:
ssh alexis@10.8.0.9 \
  'cd /srv/repos/al_the_bear/.../tom_brain_observatory && \
   dart run bin/observatory.dart /srv/repos/al_the_bear/_ai/tom_brain_trail/bomber'

# On your laptop, forward the loopback port and open it locally:
ssh -N -L 8787:127.0.0.1:8787 alexis@10.8.0.9
open http://127.0.0.1:8787/
```

This keeps the observatory off-host-invisible: the only door is your SSH tunnel.

## 4. Memory monitoring (Module 2)

The `/api/memory/*` routes are served read-only over an MCP client to the
brain's **standalone memory MCP server** (`prompt_tracing.md` § 8.4). That
server (`tom_brain_memory/bin/memory_mcp_server.dart`) opens the store
WAL-mode read-concurrent in a **separate process** and exposes the v1 read-tool
surface over Streamable HTTP at `/mcp`:

```bash
dart run ../tom_brain_memory/bin/memory_mcp_server.dart <brain_run.yaml> --port 8765
# prints: MCP_HTTP_PORT=8765
```

Pass its URL to the observatory with `--memory-mcp-url=http://127.0.0.1:8765/mcp`
(and `--memory-mcp-token=<token>` if the endpoint requires a bearer). The
observatory connects as a read-only MCP client confined to the nine read tools —
the store handle stays in the separate process, so OBS-3 ("never opens a DB
file") still holds and a live brain and the observatory can read the same memory
root at once.

Without `--memory-mcp-url` — or if the server is unreachable — the
`/api/memory/*` routes answer `503 "memory unavailable"`. The routes always
exist, so the UI degrades cleanly; Module 1 (prompt tracing) is fully functional
without it.

## 5. The read-only guarantee

You can run the observatory against a brain's **live** trail tree without
affecting it: every endpoint is a fresh read, the live-tail is an OS file-watch
(not an in-process hook), and there is no write or control path anywhere in the
package. The conformance suite (`test/obs_conformance_test.dart`) exercises the
whole surface and asserts not one file the brain owns is created, truncated, or
modified.
