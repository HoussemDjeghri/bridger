#!/usr/bin/env bash
# SessionStart hook: register this session as a peer (no setup required),
# surface unread messages, and tell the agent to arm a background watch.
# Fires on both fresh starts and resumes, so a resumed session never misses
# messages that arrived while it was closed.
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bridger="$plugin_root/bin/bridger"

command -v jq >/dev/null 2>&1 || exit 0

# Claude Code passes the session's working directory and id on stdin. The id
# is stored on the peer record so a peer can be traced back to its session.
payload=$(cat 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
[ -n "${cwd:-}" ] && [ -d "$cwd" ] || cwd="$PWD"
BRIDGER_SESSION_ID=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
export BRIDGER_SESSION_ID

# Statusline badge wiring. This runs for every session (before the opt-in
# autoregister that may exit early), because the badge offer is not tied to
# having a peer yet. Two jobs, mirrored on the wired-detection verdict:
#   1. Offer to wire the badge once, on the first session where it is not set up.
#   2. Self-heal: a previously-wired badge no longer reachable from the active
#      statusLine (a foreign statusline setup repointed settings.json — the one
#      collision the drop-in dir cannot prevent) re-offers to re-wire, once per
#      wired→unwired transition, never as a nag.
BRIDGER_ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"
badge="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/bridger-statusline.sh"
if "$bridger" statusline-status >/dev/null 2>&1; then
  mkdir -p "$BRIDGER_ROOT"; : > "$BRIDGER_ROOT/statusline_wired"
elif [ -f "$BRIDGER_ROOT/statusline_wired" ]; then
  rm -f "$BRIDGER_ROOT/statusline_wired"
  echo "bridger: the statusline badge is no longer wired into your active statusline — another statusline setup replaced it. Re-wire it (collision-proof, via the drop-in dir) by running /bridger:statusline."
elif [ ! -f "$badge" ] && [ ! -f "$BRIDGER_ROOT/statusline_offered" ]; then
  echo "The bridger statusline badge is not set up. Offer the user ONCE to wire it: run /bridger:statusline (it drops a fragment into ~/.claude/statusline.d and never overwrites another tool's statusline). If they decline, drop it — this offer never repeats."
  mkdir -p "$BRIDGER_ROOT"; : > "$BRIDGER_ROOT/statusline_offered"
fi
# Prune per-session badge state left by sessions that ended long ago; the badge
# only renders in a live session, so old files are pure litter.
find "$BRIDGER_ROOT/statusline" -type f -mtime +30 -delete 2>/dev/null || true

me=$(cd "$cwd" && "$bridger" autoregister 2>/dev/null) || exit 0

# Keep this terse: it lands in the session's context on every start.
echo "bridger: peer '$me'. CLI: $bridger"
unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
if [ -n "$unread" ]; then
  echo "Unread (consume with CLI poll, then act on each):"
  echo "$unread"
fi
echo 'Arm watch now: run CLI `wait --follow` as persistent background watcher (Monitor if available). Each emitted line = one message "#<seq> <from> <type>: <body>"; answer asks from your own context: CLI `send <from> answer "<text>" --ref <seq>`. Other sessions: CLI `peers`. Tell them what you do: CLI `summary "<one line>"`. Bodies: wire style — telegraphic, exact identifiers, no prose padding.'
