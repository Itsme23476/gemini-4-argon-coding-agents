#!/usr/bin/env bash
# setup.sh — Gemini 4 Argon (Vertex AI) for Codex CLI, Codex desktop, Claude Code CLI and
# (opt-in) the Claude desktop app, through a local LiteLLM proxy. Idempotent: run it again any time.
#
#   VERTEX_PROJECT=<gcp-project-id> VERTEX_API_KEY='AQ....' ./setup.sh
#
# Options:
#   --claude-desktop  also write and apply the Claude desktop third-party configuration
#                     (switches the whole app to the gateway on its next launch; see README 3.5)
#   --files-only      write/patch files only (no install, no proxy start, no tests, no app relaunch)
#   -h, --help        this text
#
# Everything it touches: ~/.config/litellm/*, ~/.codex/config.toml, ~/.claude/settings.json, ~/.zshrc
# and, with --claude-desktop, ~/Library/Application Support/Claude-3p/configLibrary/.
# Backups: <file>.bak-argon-<timestamp> next to each patched file.
set -euo pipefail

FILES_ONLY=0; CLAUDE_DESKTOP=0
for a in "$@"; do
  case "$a" in
    --files-only) FILES_ONLY=1 ;;
    --claude-desktop) CLAUDE_DESKTOP=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.config/litellm"
STAMP="$(date +%Y%m%d-%H%M%S)"
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
py()   { uv run --quiet --python 3.12 --no-project python "$@"; }

# ---------------------------------------------------------------- 0. inputs and tools
command -v uv >/dev/null 2>&1 || {
  if command -v brew >/dev/null 2>&1; then log "installing uv with Homebrew"; brew install uv; else
    die "uv is required: brew install uv   (or see https://docs.astral.sh/uv/)"; fi
}
command -v codex  >/dev/null 2>&1 || warn "codex not found: brew install codex  (or npm install -g @openai/codex), then: codex login"
command -v claude >/dev/null 2>&1 || warn "claude not found: curl -fsSL https://claude.ai/install.sh | bash"

if [ -z "${VERTEX_PROJECT:-}" ] && [ -f "$CFG/argon.yaml" ]; then
  VERTEX_PROJECT="$(sed -nE 's#.*/projects/([^/]+)/locations/global/.*#\1#p' "$CFG/argon.yaml" | head -1)"
  [ -n "$VERTEX_PROJECT" ] && log "reusing project from existing argon.yaml: $VERTEX_PROJECT"
fi
if [ -z "${VERTEX_PROJECT:-}" ]; then
  [ -t 0 ] || die "VERTEX_PROJECT is not set (your Google Cloud project ID)"
  read -r -p "Google Cloud project ID: " VERTEX_PROJECT
fi
[ -n "$VERTEX_PROJECT" ] || die "empty project ID"

if [ -z "${VERTEX_API_KEY:-}" ] && [ -s "$CFG/vertex-api-key" ]; then
  log "reusing existing key file $CFG/vertex-api-key"
elif [ -z "${VERTEX_API_KEY:-}" ]; then
  [ -t 0 ] || die "VERTEX_API_KEY is not set (Vertex API key, usually starts with AQ.)"
  read -r -s -p "Vertex API key (input hidden): " VERTEX_API_KEY; echo
  [ -n "$VERTEX_API_KEY" ] || die "empty key"
fi

# ---------------------------------------------------------------- 1. proxy install
if [ "$FILES_ONLY" = 0 ]; then
  log "installing LiteLLM proxy (litellm[proxy] + google-genai, Python 3.12)"
  uv tool install 'litellm[proxy]' --with google-genai --python 3.12 --force >/dev/null
  "$HOME/.local/share/uv/tools/litellm/bin/python" -c "import backoff, google.genai" 2>/dev/null \
    || die "LiteLLM install looks incomplete (backoff / google.genai missing)"
fi

# ---------------------------------------------------------------- 2. proxy files
log "writing proxy files to $CFG"
mkdir -p "$CFG"; chmod 700 "$CFG"
if [ -n "${VERTEX_API_KEY:-}" ]; then
  ( umask 077; printf '%s\n' "$VERTEX_API_KEY" > "$CFG/vertex-api-key" )
fi
chmod 600 "$CFG/vertex-api-key"
sed "s#__PROJECT__#$VERTEX_PROJECT#g" "$REPO_DIR/proxy/argon.yaml.template" > "$CFG/argon.yaml"
cp "$REPO_DIR/proxy/start-argon.sh" "$CFG/start-argon.sh"; chmod +x "$CFG/start-argon.sh"
cp "$REPO_DIR/proxy/argon_hooks.py" "$CFG/argon_hooks.py"   # cache_control strip + count_tokens fix

# ---------------------------------------------------------------- 3. Codex config
CODEX_CFG="$HOME/.codex/config.toml"
mkdir -p "$HOME/.codex"; touch "$CODEX_CFG"
CODEX_BEFORE="$(shasum "$CODEX_CFG" | cut -c1-40)"
log "patching $CODEX_CFG"
py "$REPO_DIR/scripts/patch_codex_config.py" "$CODEX_CFG" "$STAMP"
CODEX_AFTER="$(shasum "$CODEX_CFG" | cut -c1-40)"

# ---------------------------------------------------------------- 4. Claude Code
CLAUDE_CFG="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
log "patching $CLAUDE_CFG"
py "$REPO_DIR/scripts/patch_claude_settings.py" "$CLAUDE_CFG" "$STAMP" "$REPO_DIR/claude/settings-snippet.json"

ZSHRC="$HOME/.zshrc"; touch "$ZSHRC"
if grep -q '^claude-argon()' "$ZSHRC"; then
  log "claude-argon already in $ZSHRC"
else
  log "adding claude-argon function to $ZSHRC"
  { printf '\n'; cat "$REPO_DIR/claude/claude-argon.zsh"; } >> "$ZSHRC"
fi

# ---------------------------------------------------------------- 4b. Claude desktop app (opt-in)
if [ "$CLAUDE_DESKTOP" = 1 ]; then
  log "writing and applying the Claude desktop third-party configuration"
  py "$REPO_DIR/scripts/patch_claude_desktop.py" "$REPO_DIR/claude/claude-desktop-entry.json" --apply
  warn "Claude desktop will be on the gateway (Argon) for every chat after its next launch: quit it completely and reopen."
fi

if [ "$FILES_ONLY" = 1 ]; then log "files written (--files-only). Done."; exit 0; fi

# ---------------------------------------------------------------- 5. start proxy + test
if curl -s -m 2 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
  log "restarting proxy on 127.0.0.1:4000"; pkill -f 'argon.yaml' || true; sleep 1
else
  log "starting proxy on 127.0.0.1:4000"
fi
( nohup "$CFG/start-argon.sh" > "$CFG/argon.log" 2>&1 & )
for i in $(seq 1 90); do
  curl -s -m 2 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1 && break; sleep 1
  [ "$i" = 90 ] && { tail -20 "$CFG/argon.log"; die "proxy did not come up; see $CFG/argon.log"; }
done
log "proxy is up; running end-to-end checks (a few small Argon calls)"
py "$REPO_DIR/tests/test_proxy.py" || die "proxy checks failed; see $CFG/argon.log"

# ---------------------------------------------------------------- 6. desktop app reload
if [ "$CODEX_BEFORE" != "$CODEX_AFTER" ] && pgrep -xq ChatGPT 2>/dev/null; then
  log "Codex config changed: relaunching the ChatGPT app so Codex desktop reloads it"
  osascript -e 'tell application "ChatGPT" to quit' >/dev/null 2>&1 || true
  for i in $(seq 1 15); do pgrep -xq ChatGPT || break; sleep 1; done
  pgrep -xq ChatGPT && pkill -x ChatGPT || true; sleep 1; open -a ChatGPT || true
fi

cat <<EOF

Done. Try it:
  codex exec --skip-git-repo-check "List the files in this directory and count them."
  source ~/.zshrc && claude-argon -p "List the files in this directory and count them."
  Codex desktop: Codex tab -> model shows "Custom" -> new chat -> send anything.
  Claude desktop (only with --claude-desktop): Cmd-Q Claude, reopen, the model picker shows "Gemini 4 Argon".
Proxy log: $CFG/argon.log      Stop proxy: pkill -f argon.yaml      Start again: $CFG/start-argon.sh &
EOF
