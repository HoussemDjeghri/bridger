#!/usr/bin/env bash
# UserPromptSubmit hook: deliver waiting messages when nothing else will.
#
# The bridge's normal delivery path is the watcher (`wait --follow`), which the
# agent has to start itself — a hook cannot do it, since a process spawned here
# has nowhere to deliver to once the hook's output has been consumed. So the
# watcher is the one step that stays discretionary, and when it is missing
# (never armed, died, session resumed) incoming messages sit on disk unread:
# a peer's answer or a coordinating session's ruling lands mid-task and is
# silently invisible, and the work continues on stale facts.
#
# This closes that hole from the other side. It runs on every user turn, is
# executed by the harness rather than chosen by the model, and surfaces what is
# waiting. Deliberately a no-op when a watcher IS running — that path already
# pushes each message, and a second copy would only spend context.
#
# --peek, never poll: consuming here would advance the cursor out from under a
# watcher and drop the message before the agent ever saw it. Peeking means the
# same unread is re-shown each turn until the agent acts on it, which is the
# intended pressure — capped, so a large backlog cannot flood the context.
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bridger="$plugin_root/bin/bridger"

command -v jq >/dev/null 2>&1 || exit 0

# Same stdin contract as the other hooks: Claude Code passes the session's
# working directory and id. The id makes identity resolve to the peer THIS
# session registered, never to another session's name left in the directory.
payload=$(cat 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
[ -n "${cwd:-}" ] && [ -d "$cwd" ] || cwd="$PWD"
BRIDGER_SESSION_ID=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
export BRIDGER_SESSION_ID

me=$(cd "$cwd" && "$bridger" whoami 2>/dev/null) || exit 0

# Unscoped listing, matched by name: --dir compares directories exactly, so a
# session running in a subdirectory of the one it registered would miss itself.
listed=$(cd "$cwd" && "$bridger" peers 2>/dev/null) || exit 0
if grep -q "^$me \[listening\]" <<<"$listed"; then
  exit 0
fi

unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
[ -n "$unread" ] || exit 0

MAX_SHOWN=5
n=$(grep -c . <<<"$unread" || true)
echo "bridger: $n unread message(s) for peer '$me'. No watcher is running in this session, so nothing will push these into context on its own — they were found by a poll on this turn and will be re-shown every turn until you act. Handle each now: answer an 'ask' from your own context with CLI \`send <from> answer \"<text>\" --ref <seq>\`, then consume with CLI \`poll\`. If any of this changes work already done, revise it rather than delivering the stale version. Arm the watcher (CLI \`wait --follow\`, backgrounded) so the next one arrives without waiting for a turn."
head -n "$MAX_SHOWN" <<<"$unread"
if [ "$n" -gt "$MAX_SHOWN" ]; then
  echo "  ... and $((n - MAX_SHOWN)) more — CLI \`poll --peek\` for the rest."
fi

exit 0
