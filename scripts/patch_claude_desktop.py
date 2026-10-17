"""Write the Claude desktop app's third-party ("3P") configuration for the Argon proxy. Idempotent.

usage: python patch_claude_desktop.py <claude-desktop-entry.json> [--apply] [--library-dir DIR]

The desktop app keeps its third-party connection configurations in a small "config library":
    <dir>/_meta.json            {"appliedId": "<uuid>", "entries": [{"id": "<uuid>", "name": "..."}]}
    <dir>/<uuid>.json           the flat settings of one configuration (same keys as the
                                Developer > Configure Third-Party Inference screen)
where <dir> is
    macOS    ~/Library/Application Support/Claude-3p/configLibrary
    Windows  %LOCALAPPDATA%\\Claude-3p\\configLibrary
    Linux    ~/.config/Claude-3p/configLibrary   (untested)

This script adds (or updates) an entry named "Argon via LiteLLM" from the JSON file given, keeps
every other entry (creating an empty "Default" one if the library is empty, so you can always go
back), and only changes which configuration is applied when --apply is passed. The app reads the
library at launch: quit it completely and reopen after running this.
"""
import json
import os
import shutil
import sys
import time
import uuid

ENTRY_NAME = "Argon via LiteLLM"


def library_dir():
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/Claude-3p/configLibrary")
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        return os.path.join(base, "Claude-3p", "configLibrary")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "Claude-3p", "configLibrary")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    entry_path = argv[0]
    apply = "--apply" in argv
    lib = library_dir()
    if "--library-dir" in argv:
        lib = argv[argv.index("--library-dir") + 1]
    os.makedirs(lib, exist_ok=True)
    meta_p = os.path.join(lib, "_meta.json")
    stamp = time.strftime("%Y%m%d-%H%M%S")

    meta = None
    if os.path.exists(meta_p):
        shutil.copy(meta_p, f"{meta_p}.bak-argon-{stamp}")
        try:
            meta = json.load(open(meta_p, encoding="utf-8"))
        except Exception:
            meta = None
    if not isinstance(meta, dict) or not isinstance(meta.get("entries"), list):
        meta = {"appliedId": "", "entries": []}
    if not meta["entries"]:
        default_id = str(uuid.uuid4())
        json.dump({}, open(os.path.join(lib, default_id + ".json"), "w", encoding="utf-8"))
        meta["entries"].append({"id": default_id, "name": "Default"})
        meta["appliedId"] = default_id
    previous = meta.get("appliedId") or meta["entries"][0]["id"]
    previous_name = next((e["name"] for e in meta["entries"] if e["id"] == previous), "?")

    existing = next((e for e in meta["entries"] if e.get("name") == ENTRY_NAME), None)
    aid = existing["id"] if existing else str(uuid.uuid4())
    entry = json.load(open(entry_path, encoding="utf-8"))
    with open(os.path.join(lib, aid + ".json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(entry, f, indent=2)
        f.write("\n")
    if not existing:
        meta["entries"].append({"id": aid, "name": ENTRY_NAME})
    if apply:
        meta["appliedId"] = aid
        meta.pop("hybridPointer", None)
    with open(meta_p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")

    with open(os.path.join(lib, "REVERT-argon.txt"), "w", encoding="utf-8") as f:
        f.write(
            "To put Claude Desktop back on its normal connection:\n"
            "1. Quit Claude completely (Cmd-Q on macOS, tray icon > Quit on Windows).\n"
            f'2. Edit {meta_p} and set "appliedId" to "{previous}" (the entry named "{previous_name}").\n'
            "3. Reopen Claude.\n"
            "Or open Developer > Configure Third-Party Inference in the app and pick that entry;\n"
            "clicking an entry there applies it and relaunches the app.\n"
        )
    print(f"   claude desktop: library {lib}")
    print(f"   entry '{ENTRY_NAME}' = {aid}; applied = "
          f"{'this entry' if apply else previous_name + ' (unchanged; pass --apply to switch)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
