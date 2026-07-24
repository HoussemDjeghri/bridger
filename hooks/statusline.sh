#!/bin/bash
# bridger — statusline badge script for Claude Code.
# Per-session badge, a pure reflection of registration:
#   [⇄ BRIDGER:<name>]   this session is registered under <name>
# Nothing at all when this session is not registered. Session-scoped: the
# registration writes a per-session state file (the registered name inside);
# no file means no badge (not registered, or a session from another setup).
#
# Wiring: `/bridger:statusline` drops this as a fragment in ~/.claude/statusline.d/
# (run by a dispatcher your statusLine points at) so it coexists with other
# tools' badges instead of fighting over Claude Code's single statusLine slot.
# It reads the statusline JSON on stdin for the session id. Standalone use:
#   "statusLine": { "type": "command", "command": "bash /path/to/bridger-statusline.sh" }
# The stable copy at ~/.claude/hooks/bridger-statusline.sh survives plugin updates.
#
# Runs on every statusline refresh: no jq, no sourcing. The session id is
# charset-limited before it touches a path, and the registered name — dynamic,
# session-supplied content — is stripped to a safe charset before it reaches
# the terminal, so nothing hostile can inject ANSI escapes or control chars.
set -u
STATE="${BRIDGER_ROOT:-$HOME/.claude/bridger}/statusline"
[ -d "$STATE" ] || exit 0

sid=$(head -c 4096 2>/dev/null | tr -d '\n' | sed -n 's/.*"session_id" *: *"\([A-Za-z0-9._-]*\)".*/\1/p')
[ -n "$sid" ] && [ -f "$STATE/$sid" ] || exit 0

name=$(head -c 64 "$STATE/$sid" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-')
[ -n "$name" ] || exit 0

printf '\033[38;5;75m[⇄ BRIDGER:%s]\033[0m' "$name"
