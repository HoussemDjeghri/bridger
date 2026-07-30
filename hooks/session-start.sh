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

BRIDGER_ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"

me=$(cd "$cwd" && "$bridger" autoregister 2>/dev/null) || me=""

# Statusline badge wiring, evaluated AFTER autoregister: registering self-wires
# the badge whenever a drop-in dispatcher is already live, so asking first would
# offer what has just been done. Runs for every session even so — the offer is
# not tied to having a peer. Two jobs, mirrored on the wired-detection verdict:
#   1. Offer to wire the badge once, on the first session where it is not set up
#      (only reachable when there is no dispatcher — otherwise it self-wired).
#   2. Self-heal: a previously-wired badge no longer reachable from the active
#      statusLine (a foreign statusline setup repointed settings.json — the one
#      collision the drop-in dir cannot prevent) re-offers to re-wire, once per
#      wired→unwired transition, never as a nag.
badge="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/bridger-statusline.sh"
# Every write here is allowed to fail. A root that cannot be written (owned by
# another uid, a restored archive, a full disk) used to kill this hook under
# errexit ABOVE everything it exists to say — the peer's name, the dormant names,
# the unread list, the arm-the-watcher instruction — while the mail itself sat on
# disk perfectly readable. Badge bookkeeping never outranks the delivery report;
# the offer repeating is the safe direction.
if "$bridger" statusline-status >/dev/null 2>&1; then
  mkdir -p "$BRIDGER_ROOT" 2>/dev/null || true
  { : > "$BRIDGER_ROOT/statusline_wired"; } 2>/dev/null || true
elif [ -f "$BRIDGER_ROOT/statusline_wired" ]; then
  rm -f "$BRIDGER_ROOT/statusline_wired" 2>/dev/null || true
  echo "bridger: the statusline badge is no longer wired into your active statusline — another statusline setup replaced it. Re-wire it (collision-proof, via the drop-in dir) by running /bridger:statusline."
elif [ ! -f "$badge" ] && [ ! -f "$BRIDGER_ROOT/statusline_offered" ]; then
  echo "The bridger statusline badge is not set up. Offer the user ONCE to wire it: run /bridger:statusline (it drops a fragment into ~/.claude/statusline.d and never overwrites another tool's statusline). If they decline, drop it — this offer never repeats."
  mkdir -p "$BRIDGER_ROOT" 2>/dev/null || true
  { : > "$BRIDGER_ROOT/statusline_offered"; } 2>/dev/null || true
fi
# Prune per-session badge state left by sessions that ended long ago; the badge
# only renders in a live session, so old files are pure litter.
find "$BRIDGER_ROOT/statusline" -type f -mtime +30 -delete 2>/dev/null || true

# No identity for this session (opt-in and this directory was never registered
# by THIS session). Identity is per session and never inherited, so a session
# reopened where it — or another session — once had a name does not silently
# resume it. If names WERE registered here and no live session wears them,
# surface them: the user may want to reclaim one (with its queued messages) or
# pick a fresh name. This lands in the session's context; the user still acts.
if [ -z "$me" ]; then
  dormant=$(cd "$cwd" && "$bridger" dormant 2>/dev/null || true)
  if [ -n "$dormant" ]; then
    echo "bridger: this directory has registered peer name(s) that no live session holds. Identity is per session — nothing is adopted automatically. Offer the user to reclaim one (which also delivers the messages queued to it) via CLI \`register <name>\`, or to register a fresh name. Reclaimable (queued unread):"
    printf '%s\n' "$dormant" | while IFS="$(printf '\t')" read -r nm cnt; do
      echo "  $nm ($cnt queued)"
    done
    echo "CLI: $bridger"
  fi
  exit 0
fi

# Keep this terse: it lands in the session's context on every start.
echo "bridger: peer '$me'. CLI: $bridger"
unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
if [ -n "$unread" ]; then
  echo "Unread (consume with CLI poll, then act on each):"
  echo "$unread"
fi
echo 'Arm watch NOW, before other work: run CLI `wait --follow` as persistent background task (Monitor if available). Registering made this session addressable; the watcher is what makes it able to RECEIVE, and it is the only thing that reaches this session once your turn ends. Hooks surface unread messages while you are working, but an idle session with no watcher is deaf. If it may have died, re-run CLI `poll --peek` before committing to any long deliverable that depends on a peer.'
echo 'Each watcher line = one message "#<seq> <from> <type>: <body>"; answer asks from your own context: CLI `send <from> answer "<text>" --ref <seq>`. Other sessions: CLI `peers` — its status column is watcher liveness, NOT reachability; a "queued" peer still receives, so ask it. Tell them what you do: CLI `summary "<one line>"`. Bodies: wire style — telegraphic, exact identifiers, no prose padding.'
