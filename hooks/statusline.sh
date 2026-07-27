#!/bin/bash
# bridger — statusline badge script for Claude Code.
# Per-session badge, registration AND liveness:
#   [⇄ BRIDGER:<name>]           registered, watcher live — messages announce themselves
#   [⇄ BRIDGER:<name> ⚠ queued]  registered and DEAF — messages land on disk, nothing says so
# Nothing at all when this session is not registered. Session-scoped: the
# registration writes a per-session state file (the registered name inside);
# no file means no badge (not registered, or a session from another setup).
#
# The queued state is the one worth rendering: registering and arming the
# watcher are separate acts, so a session can sit registered and unaware for an
# hour. A badge is the only passive detector — it catches a watcher that died
# mid-session, which no boot-time prose can.
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
ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"
STATE="$ROOT/statusline"
[ -d "$STATE" ] || exit 0

sid=$(head -c 4096 2>/dev/null | tr -d '\n' | sed -n 's/.*"session_id" *: *"\([A-Za-z0-9._-]*\)".*/\1/p')
[ -n "$sid" ] && [ -f "$STATE/$sid" ] || exit 0

name=$(head -c 64 "$STATE/$sid" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-')
[ -n "$name" ] || exit 0

# Liveness from the same heartbeat file `bridger peers` reads: the watcher
# rewrites it every cycle, so a missing or stale beat means no watcher. Two
# stats, no `bridger` subprocess — this runs on every statusline refresh.
# 15s must match BEAT_STALE_SECS in bin/bridger.
# GNU stat first: BSD stat rejects -c with nothing on stdout, while GNU stat
# takes `-f %m` as "filesystem status of a file named %m" and prints a block
# before failing — that garbage would poison the arithmetic below.
beat="$ROOT/peers/$name.beat"
mtime=$(stat -c %Y "$beat" 2>/dev/null || stat -f %m "$beat" 2>/dev/null || echo 0)
case "$mtime" in *[!0-9]*|'') mtime=0 ;; esac

# The beat also holds the watcher's pid: `kill -0` turns a death into an
# immediate flip instead of one the badge only notices 15s later. Both builtins,
# so this costs no extra process. An empty beat is a pre-0.12 watcher — mtime
# is all it left behind.
pid=""
[ -f "$beat" ] && { read -r pid < "$beat" || true; }
alive=1
case "$pid" in ''|*[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null || alive=0 ;; esac

if [ "$alive" = 1 ] && [ $(( $(date +%s) - mtime )) -lt 15 ]; then
  printf '\033[38;5;75m[⇄ BRIDGER:%s]\033[0m' "$name"
else
  printf '\033[38;5;203m[⇄ BRIDGER:%s ⚠ queued]\033[0m' "$name"
fi
