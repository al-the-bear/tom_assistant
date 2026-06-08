#!/usr/bin/env bash
#
# run_tom_brain.sh — launch the Tom Brain prototype in the standard
# configuration (all three API gateways — OpenAI + Ollama + Anthropic — plus
# the Telegram channel, trailing to the shared `_ai` mount).
#
# This is a thin, machine-agnostic launcher: it locates the project, resolves
# the per-machine config, makes sure the two Telegram secrets are in scope, and
# hands off to `dart run bin/brain_serve.dart <config>`. The config carries the
# concrete substrate / memory / trail paths for this host; the secrets come
# from the shell environment (already exported in ~/.bashrc on bomber):
#
#   TELEGRAM_TOM_BRAIN_TOKEN — the @BotFather token for the tom_brain bot
#   TELEGRAM_TOM_BRAIN_USER  — the owner's numeric Telegram user id (whitelist)
#
# Usage:
#   ./run_tom_brain.sh                 # uses the default machine config
#   ./run_tom_brain.sh /path/cfg.yaml  # uses an explicit config
#
# On startup the OpenAI edge listens on :8080/v1, Ollama on :8081/api,
# Anthropic on :8082/v1, and the Telegram channel pings the owner.

set -euo pipefail

# Resolve the project root (the directory this script lives in) so the launcher
# works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# The standard per-machine config. Override by passing a path as $1. The
# default points at this host's machine-local config (untracked, under ztmp).
DEFAULT_CONFIG="${SCRIPT_DIR}/../../ztmp/brain_run/brain_run.yaml"
CONFIG="${1:-$DEFAULT_CONFIG}"

if [[ ! -f "$CONFIG" ]]; then
  echo "run_tom_brain: config not found: $CONFIG" >&2
  echo "  pass an explicit path: ./run_tom_brain.sh /path/to/config.yaml" >&2
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
exec dart run bin/brain_serve.dart "$CONFIG"
