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
  # The same id -> filename mapping the writers use (hooks/deliver.sh, hooks/stop.sh).
  # Deleting the raw id instead removed a path that was never created and left the
  # real files behind, so a new session inherited a dead one's "already reported"
  # and "already nudged" state. It also put an unvalidated id straight into an
  # `rm -f` path, the one place in this plugin where that matters.
  marker_id=${sid//[!A-Za-z0-9._-]/_}
  marker_id=${marker_id:-nosession}
  [ ${#marker_id} -le 64 ] || marker_id=${marker_id: -64}
  rm -f "$BRIDGER_ROOT/reported-$marker_id" "$BRIDGER_ROOT/armed-nudge-$marker_id"
fi
