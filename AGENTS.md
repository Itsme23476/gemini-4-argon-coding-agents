# Instructions for AI agents applying this setup

If you are an AI coding agent (Codex, Claude Code, Gemini CLI, Cursor, or similar) asked to
install this on someone's machine, follow these rules before you change anything.

1. **Never switch every tool at once.** Ask the person which tool they want to keep on its normal
   provider, and leave it untouched until everything else is verified. One working, untouched
   agent is their way to debug the rest if something breaks.
2. **One tool at a time, in this order:** proxy, Codex CLI, Claude Code CLI, Codex desktop,
   Claude desktop. Stop after each step and let the person test it. Do not drive desktop-app
   user interfaces yourself.
3. **Say what each step switches.** Codex desktop reads the same config file as Codex CLI, so
   configuring one configures both. Claude desktop is either on the subscription or on the
   gateway for a whole launch, never both. Say this before applying either.
4. **Back up every file you touch** (setup.sh and setup.ps1 do this) and tell the person the
   revert path for each change. They are listed under "Going back" in README.md.
5. **Never print, paste, log or commit the Vertex API key.** It lives only in
   `~/.config/litellm/vertex-api-key` with mode 600.
6. **If a step fails, read before retrying:** the proxy log (`~/.config/litellm/argon.log`), the
   app logs named in README.md, and the troubleshooting table. Do not repeat the same action.
7. Prefer `./setup.sh` (or `.\setup.ps1`) over hand-editing; both are idempotent and tested.
