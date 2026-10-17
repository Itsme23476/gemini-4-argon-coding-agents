<#
.SYNOPSIS
  Gemini 4 Argon (Vertex AI) for Codex CLI, Codex desktop and Claude Code CLI on Windows,
  through a local LiteLLM proxy. Idempotent: run it again any time.

.USAGE
  $env:VERTEX_PROJECT = "your-project-id"
  $env:VERTEX_API_KEY = "AQ.your-key"
  .\setup.ps1              # full setup: install, files, proxy, tests
  .\setup.ps1 -FilesOnly   # write/patch files only

  If scripts are blocked:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

.NOTES
  Touches: ~\.config\litellm\*, ~\.codex\config.toml, ~\.claude\settings.json, your PowerShell profile.
  Backups: <file>.bak-argon-<timestamp> next to each patched file.
  The patch logic is the same Python used by setup.sh (scripts\*.py), run through uv.
#>
[CmdletBinding()]
param([switch]$FilesOnly)
$ErrorActionPreference = "Stop"

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cfg     = Join-Path $HOME ".config\litellm"
$Stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$OnWindows = ($env:OS -eq "Windows_NT")

function Log  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "WARN: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Py {
  & uv run --quiet --python 3.12 --no-project python @args
  if ($LASTEXITCODE -ne 0) { Die "python step failed" }
}
function WriteNoBom ($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function ProxyUp {
  try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:4000/health/liveliness").StatusCode -eq 200 }
  catch { $false }
}

# ---------------------------------------------------------------- 0. inputs and tools
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  Log "installing uv"
  if ($OnWindows) { powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex" }
  else { Die "uv is required: https://docs.astral.sh/uv/" }
  $env:Path = (Join-Path $HOME ".local\bin") + ";" + $env:Path
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Die "uv installed but not on PATH yet; open a new terminal and run setup.ps1 again" }
}
if (-not (Get-Command codex  -ErrorAction SilentlyContinue)) { Warn "codex not found: npm install -g @openai/codex   then: codex login" }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Warn "claude not found: irm https://claude.ai/install.ps1 | iex   (needs Git for Windows)" }

$Project = $env:VERTEX_PROJECT
if (-not $Project -and (Test-Path (Join-Path $Cfg "argon.yaml"))) {
  $m = Select-String -Path (Join-Path $Cfg "argon.yaml") -Pattern '/projects/([^/]+)/locations/global/' | Select-Object -First 1
  if ($m) { $Project = $m.Matches[0].Groups[1].Value; Log "reusing project from existing argon.yaml: $Project" }
}
if (-not $Project) { $Project = Read-Host "Google Cloud project ID" }
if (-not $Project) { Die "empty project ID" }

$Key = $env:VERTEX_API_KEY
$KeyFile = Join-Path $Cfg "vertex-api-key"
if (-not $Key -and (Test-Path $KeyFile)) { Log "reusing existing key file $KeyFile" }
elseif (-not $Key) {
  $sec = Read-Host "Vertex API key (input hidden)" -AsSecureString
  $Key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
  if (-not $Key) { Die "empty key" }
}

# ---------------------------------------------------------------- 1. proxy install
if (-not $FilesOnly) {
  Log "installing LiteLLM proxy (litellm[proxy] + google-genai, Python 3.12)"
  & uv tool install 'litellm[proxy]' --with google-genai --python 3.12 --force | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "uv tool install failed" }
}

# ---------------------------------------------------------------- 2. proxy files
Log "writing proxy files to $Cfg"
New-Item -ItemType Directory -Force -Path $Cfg | Out-Null
if ($Key) {
  WriteNoBom $KeyFile ($Key.Trim() + "`n")
  if ($OnWindows) { icacls $KeyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null }
}
$yaml = (Get-Content (Join-Path $RepoDir "proxy\argon.yaml.template") -Raw).Replace("__PROJECT__", $Project)
WriteNoBom (Join-Path $Cfg "argon.yaml") $yaml
Copy-Item (Join-Path $RepoDir "proxy\start-argon.ps1") (Join-Path $Cfg "start-argon.ps1") -Force

# ---------------------------------------------------------------- 3. Codex config
$CodexDir = Join-Path $HOME ".codex"; $CodexCfg = Join-Path $CodexDir "config.toml"
New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
if (-not (Test-Path $CodexCfg)) { WriteNoBom $CodexCfg "" }
$before = (Get-FileHash $CodexCfg).Hash
Log "patching $CodexCfg"
Py (Join-Path $RepoDir "scripts\patch_codex_config.py") $CodexCfg $Stamp
$after = (Get-FileHash $CodexCfg).Hash

# ---------------------------------------------------------------- 4. Claude Code
$ClaudeDir = Join-Path $HOME ".claude"; $ClaudeCfg = Join-Path $ClaudeDir "settings.json"
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
Log "patching $ClaudeCfg"
Py (Join-Path $RepoDir "scripts\patch_claude_settings.py") $ClaudeCfg $Stamp (Join-Path $RepoDir "claude\settings-snippet.json")

$ProfilePath = $PROFILE.CurrentUserAllHosts
if (-not (Test-Path $ProfilePath)) { New-Item -ItemType File -Force -Path $ProfilePath | Out-Null }
if (Select-String -Path $ProfilePath -Pattern '^function claude-argon' -Quiet) {
  Log "claude-argon already in $ProfilePath"
} else {
  Log "adding claude-argon function to $ProfilePath"
  Add-Content -Path $ProfilePath -Value ("`n" + (Get-Content (Join-Path $RepoDir "claude\claude-argon.ps1") -Raw))
}

if ($FilesOnly) { Log "files written (-FilesOnly). Done."; exit 0 }

# ---------------------------------------------------------------- 5. start proxy + test
if (ProxyUp) {
  Log "stopping the running proxy on 127.0.0.1:4000"
  if ($OnWindows) {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "argon\.yaml" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
  Start-Sleep 1
}
Log "starting proxy in a hidden window (log: $Cfg\argon.log)"
$startArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Cfg 'start-argon.ps1')`""
Start-Process -FilePath "powershell" -ArgumentList $startArgs -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $Cfg "argon.log") -RedirectStandardError (Join-Path $Cfg "argon.err.log")
$up = $false
for ($i = 0; $i -lt 90; $i++) { if (ProxyUp) { $up = $true; break }; Start-Sleep 1 }
if (-not $up) { Get-Content (Join-Path $Cfg "argon.err.log") -Tail 20; Die "proxy did not come up; see $Cfg\argon.err.log" }
Log "proxy is up; running end-to-end checks (a few small Argon calls)"
Py (Join-Path $RepoDir "tests\test_proxy.py")

# ---------------------------------------------------------------- 6. desktop app reload
if ($before -ne $after) {
  Warn "Codex config changed: fully quit the Codex desktop app (tray icon -> Quit, or Task Manager) and reopen it so it reloads the config."
}

Write-Host @"

Done. Try it:
  codex exec --skip-git-repo-check "List the files in this directory and count them."
  . `$PROFILE.CurrentUserAllHosts; claude-argon -p "List the files in this directory and count them."
  Codex desktop: model shows "Custom" -> new chat -> send anything.
Proxy log: $Cfg\argon.log     Start again later: powershell -File "$Cfg\start-argon.ps1"
"@
