#!/bin/sh
# Starts the LiteLLM proxy for Gemini 4 Argon on 127.0.0.1:4000.
# The Vertex key is read from a mode-600 file so it never appears in shell history or config.
set -e
D="$HOME/.config/litellm"
export VERTEX_API_KEY="$(cat "$D/vertex-api-key")"
export LITELLM_TELEMETRY=False
exec "$HOME/.local/bin/litellm" --config "$D/argon.yaml" --host 127.0.0.1 --port 4000 "$@"
