# Codex CLI only, without a ChatGPT login

The default setup uses `requires_openai_auth = true` so the **desktop app** starts threads on the
custom provider. That makes Codex send your ChatGPT token to the proxy, so you must be signed in
with `codex login`.

If you only use the **CLI** and do not want a ChatGPT account involved, use this variant instead.
It was the first configuration that worked in our build; it does **not** work in the desktop app.

## Proxy with a master key

Generate a key and keep it in a file:

```bash
umask 077 && openssl rand -hex 24 | sed 's/^/sk-argon-/' > ~/.config/litellm/argon-master-key
```

In `~/.config/litellm/argon.yaml`, replace the `general_settings` block with:

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

and add this line to `~/.config/litellm/start-argon.sh` before the `exec`:

```sh
export LITELLM_MASTER_KEY="$(cat "$D/argon-master-key")"
```

## Codex provider with an auth command

Replace `requires_openai_auth = true` with an `auth` block. Codex refuses a config that has both.

```toml
[model_providers.litellm]
name = "LiteLLM (Gemini 4 Argon on Vertex)"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.litellm.auth]
command = "/bin/cat"
args = ["/Users/YOU/.config/litellm/argon-master-key"]
timeout_ms = 5000
refresh_interval_ms = 0
```

(`env_key = "LITELLM_API_KEY"` also works for the CLI, but an environment variable exported in a
terminal is not visible to a GUI app, which is why the file-based `auth` command is nicer.)

## Claude Code

Set `ANTHROPIC_AUTH_TOKEN` in the `claude-argon` function to the contents of the master-key file:

```zsh
ANTHROPIC_AUTH_TOKEN="$(cat ~/.config/litellm/argon-master-key)" \
```

Everything else is identical to the main README.
