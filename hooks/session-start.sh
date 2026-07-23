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

me=$(cd "$cwd" && "$bridger" autoregister 2>/dev/null) || exit 0

# Keep this terse: it lands in the session's context on every start.
echo "bridger: peer '$me'. CLI: $bridger"
unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
if [ -n "$unread" ]; then
  echo "Unread (consume with CLI poll, then act on each):"
  echo "$unread"
fi
echo 'Arm watch now: run CLI `wait --follow` as persistent background watcher (Monitor if available). Each emitted line = one message "#<seq> <from> <type>: <body>"; answer asks from your own context: CLI `send <from> answer "<text>" --ref <seq>`. Other sessions: CLI `peers`. Tell them what you do: CLI `summary "<one line>"`. Bodies: wire style — telegraphic, exact identifiers, no prose padding.'
