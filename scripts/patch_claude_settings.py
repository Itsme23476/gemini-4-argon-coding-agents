"""Add the gemini-4-argon modelPicker row to ~/.claude/settings.json. Idempotent.

usage: python patch_claude_settings.py <path-to-settings.json> <backup-stamp> <path-to-settings-snippet.json>
"""
import json
import os
import shutil
import sys

path, stamp, snippet = sys.argv[1:4]
exists = os.path.exists(path) and os.path.getsize(path) > 0
d = json.load(open(path, encoding="utf-8")) if exists else {}
if exists:
    shutil.copy(path, f"{path}.bak-argon-{stamp}")
row = json.load(open(snippet, encoding="utf-8"))["modelPicker"]["options"][0]
opts = d.setdefault("modelPicker", {}).setdefault("options", [])
opts[:] = [o for o in opts if o.get("model") != row["model"]] + [row]
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print("   claude settings ok: modelPicker row for gemini-4-argon present")
