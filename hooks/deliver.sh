#!/usr/bin/env bash
# Delivery backstop for the two moments the watcher is not covering.
#
# The bridge's primary delivery path is the watcher (`wait --follow`): a
# background task whose output re-invokes the agent, which is the only thing
# that reaches an IDLE session. It has to be started by the agent — a process
# spawned from a hook has nowhere to deliver to — so it can be missing, and
# when it is, messages sit on disk unread while work continues on stale facts.
#
# This hook covers the two states a missing watcher leaves blind, and is a
# no-op whenever the watcher is running:
#
#   PostToolUse      the agent is mid-task, between tool calls. Reports each
#                    message ONCE, when it arrives — repeating it on every
#                    subsequent tool call would be noise, and the arrival is
#                    what the agent needs to react to.
#   UserPromptSubmit the human just typed. Reports everything still waiting,
#                    every turn, until it is acted on — here the repetition IS
#                    the pressure, and it is bounded by one message per turn.
#
# It also injects the arm-the-watcher instruction next to the result of a
# `bridger register` call, so the instruction lands at the moment of
# registering rather than only in the command's markdown.
#
# --peek, never poll: consuming here would advance the cursor out from under
# the agent (or a watcher) and drop the message before it was ever read.
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bridger="$plugin_root/bin/bridger"
BRIDGER_ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"

command -v jq >/dev/null 2>&1 || exit 0

# One jq pass for every field this hook can need: it runs after every tool
# call, so the cost of the no-op path is the cost of the hook.
payload=$(cat 2>/dev/null || true)
IFS=$'\t' read -r event cwd sid cmd < <(
  jq -r '[.hook_event_name // "", .cwd // "", .session_id // "",
          (.tool_input.command // "" | gsub("\\s+"; " "))] | @tsv' \
    <<<"$payload" 2>/dev/null || true
)
[ -n "${cwd:-}" ] && [ -d "$cwd" ] || cwd="$PWD"
BRIDGER_SESSION_ID="${sid:-}"
export BRIDGER_SESSION_ID

# Claude Code reads context from stdout differently per event: UserPromptSubmit
# takes plain text, PostToolUse needs it inside hookSpecificOutput.
emit() { # text
  if [ "${event:-}" = "PostToolUse" ]; then
    jq -nc --arg t "$1" \
      '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}'
  else
    printf '%s\n' "$1"
  fi
  exit 0
}

ARM='Arm the watcher NOW, before anything else: run CLI `wait --follow` as a persistent background task (Monitor tool if available, otherwise a background Bash task). It is what delivers messages to this session while it sits idle — nothing else does. Each line it emits is one message "#<seq> <from> <type>: <body>".'

# The registration just happened, so there is nothing to deliver yet — the one
# useful thing to say is the step that is easiest to skip.
case "${cmd:-}" in
  *"bridger register"*|*"bridger join"*)
    emit "bridger: this session is now registered, but NOT yet listening. Registering does not start the watcher. $ARM"
    ;;
esac

me=$(cd "$cwd" && "$bridger" whoami 2>/dev/null) || exit 0

# Unscoped listing matched by name: --dir compares directories exactly, so a
# session running in a subdirectory of the one it registered would miss itself.
listed=$(cd "$cwd" && "$bridger" peers 2>/dev/null) || exit 0
if grep -q "^$me \[listening\]" <<<"$listed"; then
  exit 0
fi

# Mid-task, the report is per arrival, not per tool call. The marker is the
# high-water mark of what has already been reported; a thread file newer than
# it means something landed since. One find, no jq, stops at the first hit.
marker="$BRIDGER_ROOT/reported-${sid:-nosession}"
if [ "${event:-}" = "PostToolUse" ] && [ -f "$marker" ]; then
  [ -n "$(find "$BRIDGER_ROOT/threads" -name '*.json' -newer "$marker" -print -quit 2>/dev/null)" ] \
    || exit 0
fi

unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
[ -n "$unread" ] || exit 0
# The marker belongs to the PostToolUse cadence alone. UserPromptSubmit reports
# unconditionally, so letting it advance the mark would suppress the first
# mid-task report of a message the agent has only seen once, at turn start.
[ "${event:-}" = "PostToolUse" ] && { mkdir -p "$BRIDGER_ROOT"; : > "$marker"; }

MAX_SHOWN=5
n=$(grep -c . <<<"$unread" || true)
shown=$(head -n "$MAX_SHOWN" <<<"$unread")
if [ "$n" -gt "$MAX_SHOWN" ]; then
  shown="$shown
  ... and $((n - MAX_SHOWN)) more — CLI \`poll --peek\` for the rest."
fi

emit "bridger: $n unread message(s) for peer '$me'. No watcher is running in this session, so these were found by a poll rather than delivered. Handle each now: answer an 'ask' from your own context with CLI \`send <from> answer \"<text>\" --ref <seq>\`, then consume with CLI \`poll\`. If any of this changes work already done, revise it — do not deliver the version that predates the message. $ARM
$shown"
