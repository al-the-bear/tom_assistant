<#
.SYNOPSIS
  Launch the Tom Brain prototype in the standard configuration (all three API
  gateways — OpenAI + Ollama + Anthropic — plus the Telegram channel, trailing
  to the shared `_ai` mount).

.DESCRIPTION
  The PowerShell sibling of run_tom_brain.sh. A thin, machine-agnostic
  launcher: it locates the project, resolves the per-machine config, checks the
  two Telegram secrets are in scope, and hands off to
  `dart run bin/brain_serve.dart <config>`. The config carries the concrete
  substrate / memory / trail paths for this host; the secrets come from the
  environment:

    TELEGRAM_TOM_BRAIN_TOKEN — the @BotFather token for the tom_brain bot
    TELEGRAM_TOM_BRAIN_USER  — the owner's numeric Telegram user id (whitelist)

.PARAMETER Config
  An explicit config path. Defaults to this host's machine-local config
  (untracked, under ztmp).

.EXAMPLE
  ./run_tom_brain.ps1
  ./run_tom_brain.ps1 C:\path\to\config.yaml

  On startup the OpenAI edge listens on :8080/v1, Ollama on :8081/api,
  Anthropic on :8082/v1, and the Telegram channel pings the owner.
#>
param(
  [string]$Config
)

$ErrorActionPreference = 'Stop'

# Resolve the project root (the directory this script lives in) so the launcher
# works regardless of the caller's CWD.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# The standard per-machine config. Override with -Config. The default points at
# this host's machine-local config (untracked, under ztmp).
$DefaultConfig = Join-Path $ScriptDir '..\..\ztmp\brain_run\brain_run.yaml'
if (-not $Config) { $Config = $DefaultConfig }

if (-not (Test-Path $Config)) {
  Write-Error "run_tom_brain: config not found: $Config`n  pass an explicit path: ./run_tom_brain.ps1 C:\path\to\config.yaml"
  exit 66
}

# The Telegram channel needs both secrets.
if (-not $env:TELEGRAM_TOM_BRAIN_TOKEN) {
  Write-Warning "run_tom_brain: TELEGRAM_TOM_BRAIN_TOKEN is not set; the Telegram channel will fail to start."
}

Write-Host "run_tom_brain: launching with config: $Config"

# Run the server as a child process so Ctrl-C can tear it down cleanly. On a
# console Ctrl-C, Windows delivers CTRL_C_EVENT to the child too, which
# brain_serve handles (SIGINT) for a graceful stop; the finally block then
# guarantees the process is gone (force-killing if it overran its grace window).
$proc = Start-Process -FilePath 'dart' `
  -ArgumentList @('run', 'bin/brain_serve.dart', $Config) `
  -NoNewWindow -PassThru
try {
  while (-not $proc.HasExited) { Start-Sleep -Milliseconds 200 }
} finally {
  if (-not $proc.HasExited) {
    Write-Host "`nrun_tom_brain: stopping server (pid $($proc.Id))…"
    for ($i = 0; $i -lt 25 -and -not $proc.HasExited; $i++) {
      Start-Sleep -Milliseconds 200       # up to ~5s for the graceful stop
    }
    if (-not $proc.HasExited) {
      Write-Warning 'run_tom_brain: graceful stop timed out — forcing.'
      Stop-Process -Id $proc.Id -Force
    }
  }
}
exit $proc.ExitCode
