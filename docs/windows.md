# Windows guide

The architecture is identical to macOS: one LiteLLM proxy on `127.0.0.1:4000`, the same three
config changes. Only the install commands, the paths and the shell function differ.

> Honesty note: the macOS path was built and verified end to end. The Windows files mirror it
> line for line and the config-patching logic is the very same Python, but we have not run the
> Windows desktop app ourselves. If something differs on your machine, open an issue with the
> error text and the proxy log.

## 0. Prerequisites

| Item | Windows command / note |
|---|---|
| PowerShell 5.1 or 7 | Built in. If scripts are blocked: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| uv | `winget install astral-sh.uv` or `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 \| iex"`, then open a new terminal |
| Node.js (for Codex CLI) | `winget install OpenJS.NodeJS.LTS` |
| Codex CLI | `npm install -g @openai/codex`, then `codex login` (Codex runs natively on Windows; WSL is not required) |
| Codex desktop app | Install the Codex app or the ChatGPT app with the Codex tab, sign in. It reads `%USERPROFILE%\.codex\config.toml`, the same file the CLI uses. |
| Git for Windows | `winget install Git.Git` (Claude Code needs it for its shell tool) |
| Claude Code CLI | `irm https://claude.ai/install.ps1 \| iex`, then run `claude` once to sign in |
| Google Cloud project, Vertex AI API, Vertex API key | Same as the main README, step 0 and 1 |

Verify the key from PowerShell (note `curl.exe`, because plain `curl` is an alias for
`Invoke-WebRequest` in PowerShell):

```powershell
curl.exe -s -H "x-goog-api-key: YOUR_KEY" -H "Content-Type: application/json" "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/global/publishers/google/models/gemini-4-argon:generateContent" -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Reply with the single word OK.\"}]}],\"generationConfig\":{\"maxOutputTokens\":64,\"thinkingConfig\":{\"thinkingLevel\":\"LOW\"}}}"
```

## 1. One-command setup

```powershell
git clone https://github.com/Itsme23476/gemini-4-argon-coding-agents.git
cd gemini-4-argon-coding-agents
$env:VERTEX_PROJECT = "your-project-id"
$env:VERTEX_API_KEY = "AQ.your-key"
.\setup.ps1
```

`setup.ps1` does the same six things as `setup.sh`: installs `litellm[proxy]` with
`google-genai` on Python 3.12 via uv, writes `%USERPROFILE%\.config\litellm\{argon.yaml,
start-argon.ps1, vertex-api-key}`, patches `%USERPROFILE%\.codex\config.toml` and
`%USERPROFILE%\.claude\settings.json` (backups next to them), adds a `claude-argon` function to
your PowerShell profile, starts the proxy in a hidden window and runs `tests\test_proxy.py`.

Then, in a **new** PowerShell window:

```powershell
codex exec --skip-git-repo-check "List the files in this directory and count them."
```

```powershell
claude-argon -p "List the files in this directory and count them."
```

Codex desktop: quit it completely (tray icon → Quit) and reopen it; the model picker shows
**Custom**; new chat; send anything.

## 2. What is different from macOS

| Topic | macOS | Windows |
|---|---|---|
| Proxy start | `~/.config/litellm/start-argon.sh &` | `powershell -File "$HOME\.config\litellm\start-argon.ps1"` (setup.ps1 starts it hidden; see below for autostart) |
| Proxy binary | `~/.local/bin/litellm` | `%USERPROFILE%\.local\bin\litellm.exe` (uv puts it there) |
| Health check | `curl -s http://127.0.0.1:4000/health/liveliness` | `curl.exe -s http://127.0.0.1:4000/health/liveliness` |
| Shell function | `claude-argon()` in `~/.zshrc` | `function claude-argon` in `$PROFILE.CurrentUserAllHosts` (`claude\claude-argon.ps1`). It sets the env vars for the process, runs `claude`, then restores them. |
| Config paths | `~/.codex/config.toml`, `~/.claude/settings.json` | `%USERPROFILE%\.codex\config.toml`, `%USERPROFILE%\.claude\settings.json` (same content) |
| File encoding | n/a | Config files must be UTF-8 **without BOM**. `setup.ps1` writes them that way; if you edit by hand, do not let Notepad add a BOM. |
| Key file permission | `chmod 600` | `icacls` restricted to your user (done by setup.ps1) |
| Desktop app relaunch | Cmd-Q the ChatGPT app and reopen | Right-click the tray icon → Quit (closing the window is not enough), reopen |
| Stop the proxy | `pkill -f argon.yaml` | `Get-CimInstance Win32_Process \| ? { $_.CommandLine -match 'argon.yaml' } \| % { Stop-Process -Id $_.ProcessId }` |
| Line endings | n/a | Keep LF in `argon.yaml` and `config.toml`; the repo's `.gitattributes` enforces it |

Everything in the main README's [troubleshooting table](../README.md#troubleshooting) applies
unchanged; the error strings are the same on Windows.

## 3. Start the proxy automatically at logon

Create a scheduled task that runs the start script hidden at logon:

```powershell
$cmd = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$HOME\.config\litellm\start-argon.ps1`""
schtasks /Create /TN "LiteLLM Argon proxy" /SC ONLOGON /TR $cmd /RL LIMITED /F
```

Remove it with `schtasks /Delete /TN "LiteLLM Argon proxy" /F`.

## 4. WSL instead of native Windows

If you prefer to run the CLIs inside WSL2, follow the macOS/Linux README inside WSL. Two notes:

- The proxy inside WSL2 is reachable from Windows at `127.0.0.1:4000` (WSL2 forwards localhost),
  so a **Windows** Codex desktop app can use a proxy that runs in WSL. The desktop app still reads
  the **Windows** config file, so apply the `codex\config-snippet.toml` lines there too.
- Claude Code's `claude-argon` function must live in the shell where you run `claude` (WSL's
  `~/.zshrc` or `~/.bashrc` for WSL, the PowerShell profile for Windows).
