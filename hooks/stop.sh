#!/usr/bin/env bash
# Stop hook: do not let a registered session go idle deaf.
#
# End of turn is the exact moment the watcher stops being optional. While the
# agent is working, the PostToolUse hook can poll between tool calls; while the
# human is present, UserPromptSubmit can. Once the turn ends, neither fires
# again — an idle session is reached only by the watcher, whose output
# re-invokes the agent. Without it the session is addressable but deaf until
# someone comes back and types, which for an unattended session may be hours.
#
# A hook cannot start the watcher itself (a process it spawns has nowhere to
# deliver to). It can refuse to let the turn end until the agent has: block
# once, with the instruction as the reason.
#
# Once per session, never a nag: the marker is written before blocking, so the
# turn that follows is free regardless of what the agent did. An agent that
# ignores the instruction gets the softer per-turn reminders from deliver.sh
# instead of an unresolvable block. stop_hook_active is honoured on top of
# that, and Claude Code force-ends a turn after 8 consecutive blocks.
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bridger="$plugin_root/bin/bridger"
BRIDGER_ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
IFS=$'\t' read -r cwd sid active < <(
  jq -r '[.cwd // "", .session_id // "", (.stop_hook_active // false | tostring)] | @tsv' \
    <<<"$payload" 2>/dev/null || true
)
[ "${active:-false}" = "true" ] && exit 0
[ -n "${cwd:-}" ] && [ -d "$cwd" ] || cwd="$PWD"
BRIDGER_SESSION_ID="${sid:-}"
export BRIDGER_SESSION_ID

nudged="$BRIDGER_ROOT/armed-nudge-${sid:-nosession}"
[ -f "$nudged" ] && exit 0

me=$(cd "$cwd" && "$bridger" whoami 2>/dev/null) || exit 0
listed=$(cd "$cwd" && "$bridger" peers 2>/dev/null) || exit 0
grep -q "^$me \[listening\]" <<<"$listed" && exit 0

mkdir -p "$BRIDGER_ROOT"; : > "$nudged"

jq -nc --arg r "This session is registered as bridger peer '$me' but has no watcher running, so it is about to go idle unable to receive anything. Nothing else delivers to an idle session. Before finishing: run CLI \`$bridger wait --follow\` as a persistent background task (Monitor tool if available, otherwise a background Bash task) and leave it running for the rest of the session. Each line it emits is one incoming message \"#<seq> <from> <type>: <body>\" — answer an 'ask' from your own context with CLI \`$bridger send <from> answer \"<text>\" --ref <seq>\`. Then finish your turn as normal." \
  '{decision: "block", reason: $r}'
