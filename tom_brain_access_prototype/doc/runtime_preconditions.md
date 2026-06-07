# Tom Brain — Runtime Preconditions

**Quest:** tom_brain · **Plan:** `prototype_implementation_plan_2.md` item 2
**Last verified:** 2026-06-05 (from **bomber**)

The assembled Tom Brain prototype talks to two external inference runtimes. They
are **operational preconditions**: the process does not start either of them, and
several integration tests (and every live end-to-end item, plan items 12, 19,
32–34) are gated on both being reachable. This document records the exact start
commands and the health checks that prove a runtime is up before the brain is run.

| Runtime | Role | Host | Endpoint | Wire format |
|---|---|---|---|---|
| **oMLX** | Substrate **LLM** (chat completions) | Macpro2023 (fleet VPN `10.8.0.7`) | `http://10.8.0.7:8000/v1/` | OpenAI-compatible |
| **Ollama** | **Embeddings** (`nomic-embed-text`, 768 d) | bomber (local) | `http://localhost:11434` | Ollama native |

The two are deliberately **split**: oMLX serves no embedding model (see § 1.3),
so embeddings are taken from Ollama. Both are plain configuration — the substrate
reads each runtime's `baseUrl` / `models` / `embedding.model` from the substrate
config (with `${ENV}` expansion), so the addresses below are defaults, not
hard-coded assumptions.

---

## 1. oMLX — substrate LLM (Macpro2023)

oMLX is a macOS-native, MLX-based, OpenAI-compatible inference server. It runs on
**Macpro2023** and is reached from the fleet over the VPN at `10.8.0.7:8000`
(locally on the Mac it is `http://localhost:8000`).

### 1.1 Start command

Run **on Macpro2023**:

```bash
omlx serve
```

Notes:

- Do **not** pass `--model`: oMLX treats `--model` as a *directory path*, not a
  model name. Plain `omlx serve` reads `model_dirs` from `~/.omlx/settings.json`
  and auto-discovers every model under `~/.omlx/models/`. On a correct setup the
  log prints `Discovered … models` including `gemma-4-26b-a4b-it-4bit`.
- The model is `gemma-4-26b-a4b-it-4bit`, living at
  `~/.omlx/models/gemma-4-26b-a4b-it-4bit/`. To (re)download it:
  `omlx pull mlx-community/gemma-4-26b-a4b-it-4bit` (~15 GB).
- **Autostart:** a LaunchAgent at `~/Library/LaunchAgents/homebrew.mxcl.omlx.plist`
  (`RunAtLoad: true`, `KeepAlive: true`) starts oMLX on login and relaunches it on
  crash. Log: `/opt/homebrew/var/log/omlx.log`.
- **Stop:** `pkill -f "omlx serve"` (or Ctrl+C in its terminal).

### 1.2 Health check

```bash
curl -s http://10.8.0.7:8000/v1/models
```

Expected (verified 2026-06-05 from bomber):

```json
{"object":"list","data":[{"id":"gemma-4-26b-a4b-it-4bit","object":"model","created":1780646016,"owned_by":"omlx"}]}
```

The gate is: HTTP 200 and `data[].id` contains `gemma-4-26b-a4b-it-4bit`.

A chat-completion smoke (optional, confirms the model actually answers):

```bash
curl -s http://10.8.0.7:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-26b-a4b-it-4bit",
       "messages":[{"role":"user","content":"Reply with the single word: ok"}],
       "max_tokens":8,"stream":false}'
```

Verified 2026-06-05: returns `choices[0].message.content == "ok"` with a populated
`usage` block.

### 1.3 oMLX has no embedding model

oMLX serves chat models only. Calling `/v1/embeddings` against it fails by design:

```bash
curl -s http://10.8.0.7:8000/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma-4-26b-a4b-it-4bit","input":"hi"}'
```

returns:

```json
{"error":{"message":"Model 'gemma-4-26b-a4b-it-4bit' is not an embedding model. Use /v1/chat/completions for LLM models.","type":"invalid_request_error","param":null,"code":null}}
```

This is **why embeddings come from Ollama** (§ 2), not oMLX.

---

## 2. Ollama — embeddings (bomber)

Ollama provides the `nomic-embed-text` embedding model (768 dimensions) on bomber.

### 2.1 Start command

Run **on bomber**:

```bash
ollama serve
```

(If Ollama is installed as a managed service it is already running on login; a
manual `ollama serve` is only needed when it is not.) Ensure the embedding model
is present:

```bash
ollama pull nomic-embed-text
```

### 2.2 Health checks

Server up:

```bash
curl -s http://localhost:11434/api/version
# {"version":"0.24.0"}   (verified 2026-06-05)
```

Embedding model present:

```bash
curl -s http://localhost:11434/api/tags
# models[].name includes "nomic-embed-text:latest"   (verified 2026-06-05)
```

**768-dimension embedding check** (the authoritative gate):

```bash
curl -s http://localhost:11434/api/embeddings \
  -d '{"model":"nomic-embed-text","prompt":"tom brain runtime precondition health check"}'
```

Verified 2026-06-05 from bomber: the response `embedding` array has **768**
elements. The gate is: HTTP 200 and `len(embedding) == 768`. The recorded
`EmbeddingModelIdentity` the memory store persists alongside each vector
(`nomic-embed-text`, 768 d) must match this.

---

## 3. Verification log (2026-06-05, bomber)

| Check | Command | Result |
|---|---|---|
| oMLX models | `curl http://10.8.0.7:8000/v1/models` | 200 · `gemma-4-26b-a4b-it-4bit` listed |
| oMLX chat smoke | `POST /v1/chat/completions` | 200 · replies `ok`, `usage` populated |
| oMLX embeddings (negative) | `POST /v1/embeddings` | rejected — not an embedding model (expected) |
| Ollama version | `curl http://localhost:11434/api/version` | 200 · `0.24.0` |
| Ollama tags | `curl http://localhost:11434/api/tags` | 200 · `nomic-embed-text:latest` present |
| Ollama embedding dims | `POST /api/embeddings` | 200 · **768** dimensions |

Both required health checks pass from bomber; embeddings return 768 dimensions.
This satisfies plan-2 item 2's verification.

---

## 3a. Extension-F config folders (Plan step 15)

When the run config carries an `extensions:` block (spec § 13, § 21.5, § 21.6),
boot assembles the Extension-F bundle — the tool registry, the MCP client, and
the three-layer LLM configuration a future `call_llm_v1` reads — during the
engine phase. The block is **optional**: omit it entirely and the prototype's
`answer_with_memory_v1` runs unchanged. When present it adds the following
**config-folder preconditions**, validated eagerly at boot so a missing
template or an unresolvable model surfaces a typed error *before any run* (hence
before any substrate call):

| Precondition | What it is | Failure at boot |
|---|---|---|
| `prompt_template/` (§ 21.5) | One `<type>.yaml` per prompt type (role + prompt layers + the layer-3 model binding). | A required type with no file → `PromptTemplateMissing` (wrapped as `BrainStartupError(phase: engine)`). |
| `llm_configuration/providers.yaml` (§ 21.6, layer 1) | The substrate providers the templates bind against. **Required** when `extensions:` is present. | Absent file → `ProvidersMissing`. |
| `llm_configuration/models/<id>.yaml` (§ 21.6, layer 2) | Per-model config, looked up lazily by id from a template's binding. | A bound model id with no file → `LlmConfigInvalid`. |
| `mcpServers:` (§ 21.6) | A **list** of MCP servers (`id` + `transport`, plus stdio `command`/`args` or http `url`/`headers`) the `mcp.*` primitives call out to. | Bad shape (unknown transport, missing `id`, duplicate id) → `McpConfigInvalid`. A configured-but-*unreachable* server is **not** a boot error — it surfaces at connect time (PE-6). |

`requirePromptTypes:` names which prompt types are resolved eagerly at boot; the
rest resolve lazily on first use. The `toolPolicy:` block (§ 21.8) sets the
global tool-access default plus the shared deny / enabled-groups / allow lists.
See `tom_brain_run/example/brain_run.example.yaml` for the full documented shape.

These are **declarative config**, not running services: unlike oMLX/Ollama
(§ 1–2) nothing needs to be *started* — the directories and files simply have to
exist and parse. The one runtime dependency among them is each configured MCP
server, whose reachability is checked at connect time, not boot.

---

## 4. When a precondition is not met

- **oMLX unreachable** (`/v1/models` times out or connection refused): the Mac is
  off, off-VPN, or `omlx serve` is not running. Start it per § 1.1 (or check the
  LaunchAgent and `/opt/homebrew/var/log/omlx.log`). Live items (12, 19, 32–34)
  that drive oMLX must skip-or-fail loudly rather than silently pass — do not
  point them at a stub to make a red gate green.
- **Ollama unreachable** (`/api/version` fails): run `ollama serve` on bomber.
- **Embedding model missing** (`/api/tags` lacks `nomic-embed-text`):
  `ollama pull nomic-embed-text`.
- **Wrong dimension** (not 768): the configured embedding model is not
  `nomic-embed-text`; fix the substrate `embedding.model` and re-pull. A vector
  store opened with a mismatched `EmbeddingModelIdentity` must not be reused.
