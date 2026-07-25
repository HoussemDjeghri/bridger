#!/usr/bin/env bash
# SessionEnd hook: drop this peer's heartbeat so others see it as "queued"
# immediately rather than waiting for the beat to go stale. The registration
# itself stays: messages sent to this peer keep queueing for its next start.
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
bridger="$plugin_root/bin/bridger"

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
[ -n "${cwd:-}" ] && [ -d "$cwd" ] || cwd="$PWD"

(cd "$cwd" && "$bridger" offline 2>/dev/null) || true

# Per-session state the delivery hooks leave behind (what has been reported,
# whether the arm-the-watcher block already fired). Scoped to this session, so
# it is litter the moment the session ends.
sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
if [ -n "${sid:-}" ]; then
  BRIDGER_ROOT="${BRIDGER_ROOT:-$HOME/.claude/bridger}"
  rm -f "$BRIDGER_ROOT/reported-$sid" "$BRIDGER_ROOT/armed-nudge-$sid"
fi
