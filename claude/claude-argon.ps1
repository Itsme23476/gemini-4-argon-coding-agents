# === Gemini 4 Argon (Vertex) in Claude Code: claude-argon ===
# Proxy must be running: ~\.config\litellm\start-argon.ps1
function claude-argon {
  $vars = @{
    ANTHROPIC_BASE_URL                      = "http://127.0.0.1:4000"
    ANTHROPIC_AUTH_TOKEN                    = "local-proxy"
    ANTHROPIC_MODEL                         = "gemini-4-argon"
    ANTHROPIC_DEFAULT_SONNET_MODEL          = "gemini-4-argon"
    ANTHROPIC_DEFAULT_OPUS_MODEL            = "gemini-4-argon"
    ANTHROPIC_DEFAULT_HAIKU_MODEL           = "gemini-4-argon"
    ANTHROPIC_DEFAULT_FABLE_MODEL           = "gemini-4-argon"
    CLAUDE_CODE_SUBAGENT_MODEL              = "gemini-4-argon"
    DISABLE_PROMPT_CACHING                  = "1"
    CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS  = "1"
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
  }
  $saved = @{}
  foreach ($k in $vars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
    [Environment]::SetEnvironmentVariable($k, $vars[$k], "Process")
  }
  try { & claude --model gemini-4-argon @args }
  finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], "Process") }
  }
}
# === End Gemini 4 Argon ===
