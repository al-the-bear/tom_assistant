#!/usr/bin/env bash
#
# run_tom_brain.sh — launch the Tom Brain prototype in the standard
# configuration (all three API gateways — OpenAI + Ollama + Anthropic — plus
# the Telegram channel, trailing to the shared `_ai` mount).
#
# This is a thin, machine-agnostic launcher: it locates the project, resolves
# the per-machine config, makes sure the two Telegram secrets are in scope, and
# runs `dart run bin/brain_serve.dart <config>`. The config carries the concrete
# substrate / memory / trail paths for this host; the secrets come from the
# shell environment (already exported in ~/.bashrc on bomber):
#
#   TELEGRAM_TOM_BRAIN_TOKEN — the @BotFather token for the tom_brain bot
#   TELEGRAM_TOM_BRAIN_USER  — the owner's numeric Telegram user id (whitelist)
#
# Usage:
#   ./run_tom_brain.sh                 # uses the default machine config
#   ./run_tom_brain.sh /path/cfg.yaml  # uses an explicit config
#
# On startup the OpenAI edge listens on :8080/v1, Ollama on :8081/api,
# Anthropic on :8082/v1, and the Telegram channel pings the owner. The read-only
# Trail Observatory is hosted in-process (a second isolate) on :8787 — enabled
# here with the explicit `--observatory` switch; pass `--no-observatory` to skip
# it, or `--observatory-port=N` to move its loopback bind. Its memory-inspection
# routes are fed by the read-mostly memory MCP server, which is also hosted
# in-process (a third isolate, an ephemeral loopback port) — so everything
# relevant comes up in this one process; no separate memory_mcp_server.dart.
#
# Ctrl-C (or `kill` of this script) cleanly stops the server: the server runs
# as a child, and a SIGINT/SIGTERM trap forwards a graceful stop to it, waits,
# then force-kills if it does not exit in time. This is why the script does NOT
# `exec` into dart — it must stay alive to own the shutdown.

set -euo pipefail

# Resolve the project root (the directory this script lives in) so the launcher
# works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The standard per-machine config. Override by passing a path as $1. The
# default is this host's tracked config under config/<host>/ (host = short
# hostname, e.g. `bomber`).
HOST="$(hostname -s 2>/dev/null || hostname)"
DEFAULT_CONFIG="${SCRIPT_DIR}/config/${HOST}/brain_run.yaml"
CONFIG="${1:-$DEFAULT_CONFIG}"

if [[ ! -f "$CONFIG" ]]; then
  echo "run_tom_brain: config not found: $CONFIG" >&2
  echo "  this host is '${HOST}'; create config/${HOST}/brain_run.yaml" >&2
  echo "  or pass an explicit path: ./run_tom_brain.sh /path/to/config.yaml" >&2
  exit 66
fi

# The Telegram channel needs both secrets. If a non-login shell dropped them,
# pull them back in from the user profile before we warn.
if [[ -z "${TELEGRAM_TOM_BRAIN_TOKEN:-}" || -z "${TELEGRAM_TOM_BRAIN_USER:-}" ]]; then
  # shellcheck disable=SC1090
  [[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" || true
fi
if [[ -z "${TELEGRAM_TOM_BRAIN_TOKEN:-}" ]]; then
  echo "run_tom_brain: warning — TELEGRAM_TOM_BRAIN_TOKEN is not set;" >&2
  echo "  the Telegram channel will fail to start (export it in ~/.bashrc)." >&2
fi

echo "run_tom_brain: launching with config: $CONFIG"

# Run the server as a child so this shell can own the shutdown — with `exec`
# there would be no shell left to trap Ctrl-C. `set -m` (job control) puts the
# child in its OWN process group, so we can signal the whole tree at once:
# `dart run` may keep a launcher process alongside the actual VM, and a
# single-PID kill would leave one of them orphaned. Signalling the negative
# process-group id reaches every process in the group. `set +m` afterwards
# silences job-control notices for the rest of the script.
set -m
dart run bin/brain_serve.dart "$CONFIG" --observatory &
SERVER_PGID=$!                            # job-control leader == the group id
set +m

# Gracefully stop the whole server group, then force-kill if it overruns its
# grace window. brain_serve handles SIGINT/SIGTERM with a graceful shutdown
# (closes the edges, flushes the trail, stops the memory isolate); we give the
# group 5s before SIGKILL. The `-PGID` form signals every process in the group;
# the bare-PID fallback covers the (rare) case where job control was unavailable.
stop_server() {
  trap '' INT TERM                       # ignore further signals while stopping
  printf '\nrun_tom_brain: stopping server (group %s)…\n' "$SERVER_PGID"
  kill -INT -"$SERVER_PGID" 2>/dev/null || kill -INT "$SERVER_PGID" 2>/dev/null || true
  for _ in $(seq 1 50); do               # up to ~5s, polling every 100ms
    kill -0 "$SERVER_PGID" 2>/dev/null || return
    sleep 0.1
  done
  printf 'run_tom_brain: graceful stop timed out — forcing.\n' >&2
  kill -KILL -"$SERVER_PGID" 2>/dev/null || kill -KILL "$SERVER_PGID" 2>/dev/null || true
}
trap stop_server INT TERM

# Wait for the server. `wait` is interrupted when the trap fires, so re-enter it
# until the group leader is actually gone; `|| true` keeps `set -e` from exiting
# on the signal-derived non-zero status.
while kill -0 "$SERVER_PGID" 2>/dev/null; do
  wait "$SERVER_PGID" || true
done
