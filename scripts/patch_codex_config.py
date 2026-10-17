"""Patch ~/.codex/config.toml for the Gemini 4 Argon provider. Idempotent.

usage: python patch_codex_config.py <path-to-config.toml> <backup-stamp>

- puts `model` / `model_provider` at the very top (top-level keys must precede tables)
- removes any previous [model_providers.litellm] and [model_providers.litellm.auth] tables
- appends the provider block with requires_openai_auth = true (no auth block: Codex rejects both)
- validates the result with tomllib before writing; backup written next to the file
"""
import re
import shutil
import sys
import tomllib

path, stamp = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read() if __import__("os").path.exists(path) else ""
if src:
    shutil.copy(path, f"{path}.bak-argon-{stamp}")

DROP_TABLES = {"model_providers.litellm", "model_providers.litellm.auth"}
out, table, first_header_seen = [], None, False
for ln in src.splitlines():
    m = re.match(r"^\s*\[([^\]]+)\]\s*$", ln)
    if m:
        table = m.group(1).strip().strip('"')
        first_header_seen = True
        if table in DROP_TABLES:
            while out and out[-1].lstrip().startswith("# Gemini 4 Argon"):
                out.pop()  # drop the comment line we add above the block
            continue
        out.append(ln)
        continue
    if table in DROP_TABLES:
        continue
    if not first_header_seen and re.match(r"^\s*(model|model_provider)\s*=", ln):
        continue  # re-added at the top below
    out.append(ln)

body = "\n".join(out).strip("\n")
head = 'model = "gemini-4-argon"\nmodel_provider = "litellm"\n'
tail = """
# Gemini 4 Argon on Vertex AI via local LiteLLM proxy (~/.config/litellm/start-argon.sh)
[model_providers.litellm]
name = "LiteLLM (Gemini 4 Argon on Vertex)"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
supports_websockets = false
requires_openai_auth = true
"""
new = head + ("\n" + body + "\n" if body else "") + tail
d = tomllib.loads(new)
assert d["model"] == "gemini-4-argon" and d["model_provider"] == "litellm"
assert "auth" not in d["model_providers"]["litellm"]
open(path, "w", encoding="utf-8", newline="\n").write(new)
print("   codex config ok: model/model_provider at top, litellm provider block present")
