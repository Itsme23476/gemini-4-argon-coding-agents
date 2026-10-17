# Gemini 4 Argon inside Codex and Claude Code (via Vertex AI)

Run Google's **Gemini 4 Argon** (`gemini-4-argon`) as the model behind **Codex CLI**, the
**Codex desktop app** and **Claude Code CLI**, billed to your own Google Cloud project on
Vertex AI (so Google Cloud credits apply). One small local proxy does the translation.

```
Codex CLI / Codex desktop  ──OpenAI Responses API──▶ ┌──────────────────────┐
                                                     │ LiteLLM proxy        │ ──Gemini API──▶ Vertex AI (global)
Claude Code CLI            ──Anthropic Messages API─▶ │ 127.0.0.1:4000       │                 gemini-4-argon
                                                     └──────────────────────┘
```

Everything here was built and verified on a Mac on 17 Oct 2026 with the versions listed at the
bottom. Follow the steps in order and it works first time. Every error we hit on the way is in
the [troubleshooting table](#troubleshooting), with the fix that is already baked into the files.

> **Why a proxy at all?** Codex only speaks the OpenAI *Responses* API with a bearer token.
> Claude Code only speaks the Anthropic *Messages* API. Vertex AI offers neither for Gemini, and
> its OpenAI-compatible endpoint is Chat Completions only, which Codex dropped in early 2026.
> LiteLLM exposes both front-ends and talks native Gemini on the back.

---

## 0. What you need before starting

| Item | Notes |
|---|---|
| macOS on Apple Silicon or Intel | Tested on macOS 26.2, arm64. Linux works for the CLI parts; the desktop-app steps are macOS. |
| [Homebrew](https://brew.sh) | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| [uv](https://docs.astral.sh/uv/) | `brew install uv` (installs the proxy and its own Python, nothing else touches your system Python) |
| Codex CLI | `brew install codex` or `npm install -g @openai/codex`, then run `codex login` once (ChatGPT sign-in; see [why](#why-does-codex-still-need-a-chatgpt-login)) |
| Codex desktop app | On macOS the Codex app now lives inside the **ChatGPT** desktop app (Codex tab). Install ChatGPT from openai.com and sign in. If you have the standalone Codex.app, it reads the same config file. |
| Claude Code CLI | `curl -fsSL https://claude.ai/install.sh \| bash`, then run `claude` once to sign in |
| A Google Cloud project with **billing enabled** | A Free Trial billing account is fine. Trial credit covers first-party Gemini on Vertex, but **not** the Gemini Developer API / AI Studio, so do not use an AI Studio key. |
| **Vertex AI API enabled** on that project | Console → APIs & Services → Enable APIs → "Vertex AI API" (`aiplatform.googleapis.com`) |
| A **Vertex API key** for that project | See step 1. The key we used starts with `AQ.` |
| Your **project ID** | Console → project picker. The project *number* works too. |

Keep two values handy for the next steps: `VERTEX_PROJECT` (project ID) and `VERTEX_API_KEY`.

---

## 1. Create the Vertex API key (2 minutes)

1. Open the Google Cloud console and select the project that has billing.
2. Open **Gemini Enterprise Agent Platform** (the product formerly named Vertex AI; some pages call it
   "Gemini platform") and look for **API keys**. Create a key. It starts with `AQ.`.
   If your console shows the classic page instead: **APIs & Services → Credentials → Create
   credentials → API key**, then restrict it to the Vertex AI API.
3. Verify the key and the model before touching any tool. Replace the two placeholders:

```bash
curl -s -H "x-goog-api-key: YOUR_KEY" -H "Content-Type: application/json" \
  "https://aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/global/publishers/google/models/gemini-4-argon:generateContent" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Reply with the single word OK."}]}],"generationConfig":{"maxOutputTokens":64,"thinkingConfig":{"thinkingLevel":"LOW"}}}'
```

You must see `"modelVersion": "gemini-4-argon"` and the text `OK`. If you get a 404 mentioning
`us-central1`, you used the location-less URL; Argon only exists on `global`, `us` and `eu`.
If you get 403, the Vertex AI API is not enabled or billing is off.

---

## 2. One-command setup

```bash
git clone https://github.com/Itsme23476/gemini-4-argon-coding-agents.git
cd gemini-4-argon-coding-agents
VERTEX_PROJECT=your-project-id VERTEX_API_KEY='AQ.your-key' ./setup.sh
```

`setup.sh` is idempotent and does exactly this (each step is also written out below if you
prefer to do it by hand):

1. installs the proxy: `uv tool install 'litellm[proxy]' --with google-genai --python 3.12`
2. writes `~/.config/litellm/argon.yaml`, `start-argon.sh` and the key file (mode 600)
3. patches `~/.codex/config.toml` (backup kept next to it)
4. patches `~/.claude/settings.json` (backup kept) and appends `claude-argon` to `~/.zshrc`
5. starts the proxy and runs `tests/test_proxy.py` against it
6. relaunches the ChatGPT app if it is running, so Codex desktop reloads the config

Then test the three tools:

```bash
codex exec --skip-git-repo-check "List the files in this directory and count them."
```

```bash
source ~/.zshrc && claude-argon -p "List the files in this directory and count them."
```

Codex desktop: open the Codex tab, the model picker shows a single entry named **Custom**, start a
new chat and send anything. Watch the request land in `~/.config/litellm/argon.log`.

### Windows

Same architecture, same three config changes, different install commands and paths. Use
`setup.ps1` instead of `setup.sh` and read **[docs/windows.md](docs/windows.md)** for the
differences (PowerShell profile function, `curl.exe`, UTF-8 without BOM, autostart via Task
Scheduler, WSL notes).

```powershell
$env:VERTEX_PROJECT = "your-project-id"; $env:VERTEX_API_KEY = "AQ.your-key"; .\setup.ps1
```

The Windows files mirror the verified macOS setup line for line and share the same patch scripts,
but we have not run the Windows desktop app ourselves.

---

## 3. Manual steps (what setup.sh does)

### 3.1 Install the proxy

```bash
uv tool install 'litellm[proxy]' --with google-genai --python 3.12
```

Three details matter and each one cost us a round of debugging:

- `[proxy]` extra: without it the server dies with `Missing dependency No module named 'backoff'`.
- `--with google-genai`: LiteLLM's Gemini token counter imports `google.genai`; without it
  `/v1/messages/count_tokens` returns 500.
- `--python 3.12`: pin it, a later `uv tool upgrade` otherwise silently moves to a newer Python.

### 3.2 Proxy config

Copy `proxy/argon.yaml.template` to `~/.config/litellm/argon.yaml` and replace `__PROJECT__`
with your project ID. The file is short enough to read in full:

```yaml
model_list:
  - model_name: gemini-4-argon
    litellm_params:
      model: gemini/gemini-4-argon
      api_base: https://aiplatform.googleapis.com/v1/projects/__PROJECT__/locations/global/publishers/google
      api_key: os.environ/VERTEX_API_KEY

litellm_settings:
  drop_params: true
  modify_params: true

router_settings:
  disable_cooldowns: true

general_settings:
  dangerously_permit_weak_or_unset_master_key: true
```

Why it looks like this:

- **`gemini/` provider, not `vertex_ai/`**: LiteLLM's Vertex provider only authenticates with
  OAuth (service account or gcloud ADC). The `gemini/` provider is the one path that sends an
  `x-goog-api-key` header. With `api_base` set, it builds
  `{api_base}/models/gemini-4-argon:generateContent`, which is exactly the project-scoped
  **global** Vertex URL. Billing lands on your project.
- **`drop_params`**: Argon ignores `temperature`, `top_p`, `top_k` and rejects
  `thinkingBudget` (only `thinkingLevel` LOW/MEDIUM/HIGH exist). LiteLLM already maps
  reasoning effort to thinking levels for gemini-3-and-newer names.
- **`disable_cooldowns`**: with a single upstream, one transient error otherwise puts the model
  in cooldown and every request for the next minute gets a 429.
- **No master key**: Codex desktop sends its ChatGPT token as the bearer (see 3.3), so the proxy
  must accept any token. It binds to `127.0.0.1` only, nothing outside your machine can reach it.
  LiteLLM refuses to start without a master key unless that `dangerously_permit...` flag is set.

Start script `~/.config/litellm/start-argon.sh` (from `proxy/start-argon.sh`):

```sh
#!/bin/sh
set -e
D="$HOME/.config/litellm"
export VERTEX_API_KEY="$(cat "$D/vertex-api-key")"
export LITELLM_TELEMETRY=False
exec "$HOME/.local/bin/litellm" --config "$D/argon.yaml" --host 127.0.0.1 --port 4000 "$@"
```

Put the key in `~/.config/litellm/vertex-api-key` with `chmod 600`. Start and check:

```bash
nohup ~/.config/litellm/start-argon.sh > ~/.config/litellm/argon.log 2>&1 &
```

```bash
curl -s http://127.0.0.1:4000/health/liveliness
```

Run the end-to-end check (both APIs, tool-call round trips, streaming):

```bash
uv run --python 3.12 --no-project tests/test_proxy.py
```

The proxy does not survive a reboot. Run the start command again, or add a launchd agent.

### 3.3 Codex CLI and Codex desktop

Both read `~/.codex/config.toml`. Add these **at the very top** of the file (TOML requires
top-level keys before any `[table]`), and the provider block anywhere below:

```toml
model = "gemini-4-argon"
model_provider = "litellm"

[model_providers.litellm]
name = "LiteLLM (Gemini 4 Argon on Vertex)"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
```

Rules that are not obvious:

- **Top level, not a profile.** The desktop app ignores `--profile` and only reads the top-level
  `model` / `model_provider`.
- **`wire_api = "responses"` is the only value that works.** Chat Completions support was
  removed from Codex in early 2026.
- **`requires_openai_auth = true` is what makes the desktop app work.** Without it the ChatGPT
  app treats the thread as signed out and refuses to start it with
  `Work browser access requires an authenticated account`. With it, Codex sends your ChatGPT
  login token as the bearer to the proxy, which ignores it. Consequence: **do not add a
  `[model_providers.litellm.auth]` block or an `env_key`**. Codex refuses to load a config that
  has both (`provider auth cannot be combined with requires_openai_auth`), and a broken config
  shows up in the desktop app as a vague "couldn't be loaded" message.
- **Fully quit and relaunch the ChatGPT app** after every change to the file. The model picker
  then shows one entry named **Custom** and the configured model string is sent as-is.
- `model_reasoning_effort` (if you set it) maps to Argon's thinking level: `low`, `medium`, `high`.

Known limitations in Codex with any custom provider (open upstream issues): MCP servers from
`config.toml` may not be exposed to the model, and switching models means editing the file.

### 3.4 Claude Code CLI

Two pieces. First, Claude Code refuses model IDs it does not know unless you map them. Add to
`~/.claude/settings.json` (merge with what is there):

```json
{
  "modelPicker": {
    "options": [
      {
        "model": "gemini-4-argon",
        "label": "Gemini 4 Argon (Vertex via LiteLLM)",
        "behavesAs": "claude-opus-4-8"
      }
    ]
  }
}
```

`behavesAs` tells Claude Code which built-in model's client-side profile to use for the unknown
ID. The error you get without it is
`"gemini-4-argon" isn't described by this version's model catalog`.

Second, a shell function so the normal `claude` command stays untouched. Append
`claude/claude-argon.zsh` to `~/.zshrc`:

```zsh
claude-argon() {
  ANTHROPIC_BASE_URL="http://127.0.0.1:4000" \
  ANTHROPIC_AUTH_TOKEN="local-proxy" \
  ANTHROPIC_MODEL="gemini-4-argon" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="gemini-4-argon" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="gemini-4-argon" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="gemini-4-argon" \
  ANTHROPIC_DEFAULT_FABLE_MODEL="gemini-4-argon" \
  CLAUDE_CODE_SUBAGENT_MODEL="gemini-4-argon" \
  DISABLE_PROMPT_CACHING=1 \
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude --model gemini-4-argon "$@"
}
```

- Every tier variable (Sonnet, Opus, Haiku, Fable) must point at the same model, otherwise
  background calls go to a model name the proxy does not have.
- **`DISABLE_PROMPT_CACHING=1` is required.** Claude Code marks prompts with `cache_control`;
  LiteLLM turns that into a Gemini explicit-cache call (`:cachedContents`), which Argon does not
  support, and the request 404s. Vertex **implicit** caching still applies server-side: in our
  runs most input tokens came back as cache reads.
- `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` strips beta headers that a proxy cannot honour.
- The Claude **desktop app** is not covered yet. It reads the same settings file, but it has its
  own "third-party inference" setting and we did not test it.

---

## Troubleshooting

Every one of these happened during the build. The fix is already in the files; this table is
for when you deviate.

| Symptom | Cause | Fix |
|---|---|---|
| `Publisher model ... locations/us-central1/... was not found` | Called the location-less express URL | Use `projects/<id>/locations/global/...` (the `api_base` in argon.yaml) |
| `Thinking budget is not supported for this model. Use thinking level instead.` | Request carried `thinkingBudget` | Use `thinkingLevel` LOW/MEDIUM/HIGH; LiteLLM does this already |
| Proxy: `Missing dependency No module named 'backoff'` | LiteLLM installed without `[proxy]` | `uv tool install 'litellm[proxy]' ...` |
| Proxy: `No module named 'google'` on count_tokens | Google SDK missing | add `--with google-genai` |
| Proxy refuses to start: `no master key is set` | Expected, we run keyless on localhost | `general_settings.dangerously_permit_weak_or_unset_master_key: true` |
| Claude Code: `"gemini-4-argon" isn't described by this version's model catalog` | Unknown model ID | `modelPicker` row with `behavesAs` in settings.json |
| Claude Code: 404 with `...gemini-4-argon:cachedContents` in proxy log, then 429s | `cache_control` → explicit cache (unsupported) → cooldown | `DISABLE_PROMPT_CACHING=1` and `router_settings.disable_cooldowns: true` |
| Claude Code: `There's an issue with the selected model` | Same as above, surfaced by the client | Same |
| Claude Code `-p` says `Input must be provided either through stdin` | A list flag swallowed the prompt | Pipe the prompt on stdin, or put the prompt before flags |
| Codex desktop: `Work browser access requires an authenticated account` / `Could not start this chat` | App treats a non-OpenAI provider as signed out | `requires_openai_auth = true` on the provider and a keyless proxy |
| Codex: `provider auth cannot be combined with requires_openai_auth` (CLI), or desktop says config couldn't be loaded | Both `auth`/`env_key` and `requires_openai_auth` on one provider | Remove the `auth` block / `env_key` |
| Codex desktop ignores the new model | Config read only at launch | Quit the ChatGPT app completely (Cmd-Q) and reopen |
| Codex desktop model picker only shows "Custom" | Normal for custom providers | Nothing; the configured model is used |
| Codex: MCP servers missing with the custom provider | Upstream Codex limitation | None yet (openai/codex issues 19363, 26977, 45396) |
| `/v1/messages/count_tokens` 404 through the proxy | LiteLLM count path for the `gemini/` provider | Cosmetic; Claude Code falls back to its own estimate |

Logs: `~/.config/litellm/argon.log` (every request, with upstream errors), Codex desktop logs
in `~/Library/Logs/com.openai.codex/`, Codex CLI sessions in `~/.codex/sessions/`.

---

## Cost notes (read before you leave it running)

- Argon list price on Vertex: **$2 / M input, $10 / M output until 30 Nov 2026, then $4 / $20**.
  Thinking tokens are billed as output. The pricing footnote says the intro price is delivered as
  **50 % credits back on net spend**, so if you pay with promotional credit, check the billing
  report after day one before assuming the $2/$10 rate.
- Non-global regions cost 10 % more. `global` is used here.
- Implicit caching: cached input is $0.10 / M. Explicit caching is not supported on Argon.
- Codex carries a big baseline context (its prompt, plugins, tool schemas). In our test a trivial
  three-turn task used ~360k input tokens, a third from cache. Claude Code turns were ~110k
  input tokens with most of it cached. Gemini CLI is far cheaper per turn than either.
- Set a Google Cloud budget alert on the project before sharing this with anyone.

## Security notes

- The proxy listens on `127.0.0.1:4000` only and has no master key. Do not change `--host`.
- Your Vertex key lives in `~/.config/litellm/vertex-api-key` with mode 600 and nowhere else.
  Never paste it into chat tools or commit it. `.gitignore` here blocks the key files anyway.
- Codex desktop sends your ChatGPT token to the proxy; it goes to localhost and is discarded.

## Going back

- Codex: delete the two top-level lines (`model`, `model_provider`) in `~/.codex/config.toml`
  and relaunch the desktop app. Keep the provider block; it is inert.
- Claude Code: just use `claude` instead of `claude-argon`. The `modelPicker` row is harmless.
- Proxy: `pkill -f argon.yaml`.
- `setup.sh` leaves backups: `~/.codex/config.toml.bak-argon-<timestamp>` and
  `~/.claude/settings.json.bak-argon-<timestamp>`.

## FAQ

### Why does Codex still need a ChatGPT login?
Only because of the desktop app. `requires_openai_auth = true` is the switch that makes the app
start threads on a custom provider, and that switch means Codex authenticates requests with your
ChatGPT token. The token never leaves your machine. If you only want the **CLI** and have no
ChatGPT account, see `docs/cli-only-variant.md`.

### Can Codex or Claude Code call Vertex directly?
No. Codex needs a Responses endpoint, Claude Code needs a Messages endpoint. Vertex has neither
for Gemini. Claude Code's built-in "Vertex" option is for Claude models hosted on Vertex, not
Gemini.

### What about Gemini CLI and Antigravity?
Gemini CLI can use Vertex natively (`GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT`,
`GOOGLE_CLOUD_LOCATION=global`, `GEMINI_MODEL=gemini-4-argon`, auth via
`gcloud auth application-default login`), but its README states it is not optimised for Argon
and we did not test it here. Antigravity has no bring-your-own-key or bring-your-own-endpoint
support; Argon there comes with Google AI Pro/Ultra, not with Cloud credits.

## Versions this was verified with

| Tool | Version |
|---|---|
| macOS | 26.2 (arm64) |
| Codex CLI | 0.153.3 (standalone), 0.163.0-alpha bundled in ChatGPT.app 26.1013 |
| Claude Code | 2.1.296 |
| LiteLLM | 1.105.1 (`litellm[proxy]` + google-genai 2.31.0, Python 3.12) |
| uv | 0.12.13 |
| Model | `gemini-4-argon`, GA on Vertex AI since 13 Oct 2026 |

## Repository layout

```
setup.sh                     one-shot installer, macOS/Linux (idempotent)
setup.ps1                    one-shot installer, Windows PowerShell (idempotent)
scripts/patch_*.py           the config patching both installers share (run via uv, Python 3.12)
proxy/argon.yaml.template    LiteLLM config (replace __PROJECT__)
proxy/start-argon.sh|.ps1    proxy start scripts
codex/config-snippet.toml    lines for ~/.codex/config.toml
claude/settings-snippet.json modelPicker row for ~/.claude/settings.json
claude/claude-argon.zsh|.ps1 shell functions for Claude Code
tests/test_proxy.py          end-to-end proxy check (stdlib only)
docs/windows.md              Windows differences, autostart, WSL
docs/cli-only-variant.md     Codex CLI without a ChatGPT login (master-key variant)
```

MIT licensed. Not affiliated with Google, OpenAI or Anthropic.
