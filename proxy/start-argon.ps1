# Starts the LiteLLM proxy for Gemini 4 Argon on 127.0.0.1:4000 (Windows PowerShell / pwsh).
# The Vertex key is read from a file so it never appears in shell history or config.
$ErrorActionPreference = "Stop"
$D = Join-Path $HOME ".config\litellm"
$env:VERTEX_API_KEY = (Get-Content (Join-Path $D "vertex-api-key") -Raw).Trim()
$env:LITELLM_TELEMETRY = "False"
$env:PYTHONPATH = if ($env:PYTHONPATH) { "$D;$env:PYTHONPATH" } else { $D }   # so argon_hooks.py loads
$litellm = Join-Path $HOME ".local\bin\litellm.exe"
if (-not (Test-Path $litellm)) { $litellm = "litellm" }   # fall back to PATH
& $litellm --config (Join-Path $D "argon.yaml") --host 127.0.0.1 --port 4000 @args
