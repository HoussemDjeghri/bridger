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
# Every field is made total. `.tool_input.command` is not always a string — an
# MCP tool can pass an array, an object or a number, and `tool_input` itself
# need not be an object — and `gsub` on a non-string makes jq exit 5 with no
# output. The `|| true` also has to sit OUTSIDE the redirection: there it fixed
# the process substitution's status, but `read` then hit EOF and returned 1, and
# under `set -e` that is what killed the hook. The result was a silent exit 1 for
# any such tool call, and a session with mail waiting never heard about it.
IFS=$'\t' read -r event cwd sid cmd < <(
  jq -r '[.hook_event_name // "", .cwd // "", .session_id // "",
          ((.tool_input? | objects | .command? | strings) // "" | gsub("\\s+"; " "))] | @tsv' \
    <<<"$payload" 2>/dev/null
) || true
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

# Did this call look like a registration? Only a hint, never a verdict: the
# command is matched as a SUBSTRING, so a grep, a doc edit or a test that merely
# mentions the phrase looks identical to the real thing. This used to emit-and-
# exit right here, which meant such a command both asserted "this session is now
# registered" — of a session that might not be registered at all — and skipped
# the unread delivery below it. So only remember it, and let the checks that read
# actual state decide.
registered_now=0
case "${cmd:-}" in
  *"bridger register"*|*"bridger join"*) registered_now=1 ;;
esac

# Mid-task, the report is per arrival, not per tool call. The marker is the
# high-water mark of what has already been reported; a thread file newer than
# it means something landed since. One find, no jq, stops at the first hit.
# A registration skips this gate: it is a rare, explicit event, and the thing it
# needs to say ("you are registered but deaf") is not about mail arriving, so the
# high-water mark must not suppress it.
#
# This runs BEFORE whoami and peers. It needs neither, and sitting below them it
# had already spent most of the hook's cost — the cost this gate exists to avoid,
# paid on every tool call of every session on the machine.
# The id goes into a FILENAME, so it is charset-limited first, as
# `statusline_state_file` does in bin/bridger for the same reason. Interpolated
# raw, a session id containing `/` made the marker a path through a directory
# that does not exist; `mv` then failed and errexit killed the hook — after the
# peek had already found the mail and before it could be reported.
#
# MAPPED, not collapsed. Answering every unusable id with one constant name made
# all of them share a high-water marker, and the gate below is unscoped across
# threads — so the first such session to stamp it silenced every other one's
# waiting mail for good. `statusline_state_file` avoids that by returning nothing
# at all rather than a shared name; here the name is needed, so make it per
# session instead. Claude Code sends UUIDs, so both defects are latent — one
# malformed field away from the silent-no-delivery behaviour this file exists to
# prevent.
marker_id=${sid//[!A-Za-z0-9._-]/_}
marker_id=${marker_id:-nosession}
# Only when it is actually too long: on bash 3.2 `${var: -64}` yields EMPTY for a
# shorter string, which collapsed every session onto one marker named `reported-`.
[ ${#marker_id} -le 64 ] || marker_id=${marker_id: -64}
marker="$BRIDGER_ROOT/reported-$marker_id"
if [ "${event:-}" = "PostToolUse" ] && [ "$registered_now" -eq 0 ] && [ -f "$marker" ]; then
  [ -n "$(find "$BRIDGER_ROOT/threads" -name '*.json' -newer "$marker" -print -quit 2>/dev/null)" ] \
    || exit 0
fi

me=$(cd "$cwd" && "$bridger" whoami 2>/dev/null) || exit 0

# By name, not a scope filter: --dir compares directories exactly, so a session
# running in a subdirectory of the one it registered would miss itself. And by
# ONE name, because a full listing costs five jq per peer record — 201 forks and
# 3.0s at 40 peers — to answer a question about a single peer, on every tool call
# against a 5s budget.
listed=$(cd "$cwd" && "$bridger" peers "$me" 2>/dev/null) || exit 0
if grep -q "^$me \[listening\]" <<<"$listed"; then
  exit 0
fi

# Stamp the mark with the time the scan STARTS, not the time it finishes. The
# marker was written after the poll returned, so a message that landed after its
# own thread was scanned but before that write ended up with an mtime OLDER than
# the marker: `find -newer` could never see it, and every later tool call exited
# at the gate above while the message sat unread. The poll takes seconds on a
# busy bus, so the window is wide. `mv` preserves the mtime.
#
# A root that cannot be written costs the marker, not the delivery: mail already
# on disk is readable, so a read-only bus (a restored archive, a root shared with
# another uid) must still be reported. Stamping it was above the peek, so a
# failure there silenced the report entirely.
mkdir -p "$BRIDGER_ROOT" 2>/dev/null || true
stamp=$(mktemp "$BRIDGER_ROOT/.mark.XXXXXX" 2>/dev/null || true)
# Anything that ends the hook between here and the mv below — the 5s hook timeout
# firing mid-poll, most likely — would otherwise leave the stamp behind for good;
# nothing in the plugin prunes them. A no-op on the success path, where the mv has
# already consumed it.
[ -z "$stamp" ] || trap 'rm -f "$stamp"' EXIT

unread=$(cd "$cwd" && "$bridger" poll --peek 2>/dev/null || true)
# The marker belongs to the PostToolUse cadence alone. UserPromptSubmit reports
# unconditionally, so letting it advance the mark would suppress the first
# mid-task report of a message the agent has only seen once, at turn start.
#
# Written whether or not anything was waiting. Writing it only when mail had
# arrived left a registered session that has never received a message with no
# marker at all, so the gate above was skipped on every single tool call forever
# — exactly the hot path it exists for.
#
# And failing to record it must never cost a delivery: the worst case of a
# missing marker is a report repeated on the next tool call, which is the safe
# direction, whereas letting the failure propagate loses the mail the peek is
# holding right now.
if [ -n "$stamp" ]; then
  # Not into a DIRECTORY sitting at the marker path: `mv` would succeed by moving
  # the stamp inside it, so `[ -f "$marker" ]` above stays false forever and every
  # run leaves another temp file in there. Removing someone else's directory is not
  # this hook's call; skipping the marker only costs a repeated report.
  if [ "${event:-}" = "PostToolUse" ] && [ ! -d "$marker" ]; then
    mv "$stamp" "$marker" 2>/dev/null || rm -f "$stamp"
  else
    rm -f "$stamp"
  fi
fi
# Nothing waiting. If this call really was a registration, the step easiest to
# skip is the watcher — and by here `whoami` and `peers` have confirmed both
# halves of the claim: this session IS registered, and it is NOT listening.
if [ -z "$unread" ]; then
  [ "$registered_now" -eq 1 ] || exit 0
  emit "bridger: this session is now registered, but NOT yet listening. Registering does not start the watcher. $ARM"
fi
MAX_SHOWN=5
n=$(grep -c . <<<"$unread" || true)
shown=$(head -n "$MAX_SHOWN" <<<"$unread")
if [ "$n" -gt "$MAX_SHOWN" ]; then
  shown="$shown
  ... and $((n - MAX_SHOWN)) more — CLI \`poll --peek\` for the rest."
fi

emit "bridger: $n unread message(s) for peer '$me'. No watcher is running in this session, so these were found by a poll rather than delivered. Handle each now: answer an 'ask' from your own context with CLI \`send <from> answer \"<text>\" --ref <seq>\`, then consume with CLI \`poll\`. If any of this changes work already done, revise it — do not deliver the version that predates the message. $ARM
$shown"
