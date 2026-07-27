---
description: Wire the always-visible bridger peer-name statusline badge
---

Wire the bridger statusline badge — the name this session is registered as, plus
whether it can actually hear:

- `[⇄ BRIDGER:<name>]` — registered, watcher live.
- `[⇄ BRIDGER:<name> ⚠ queued]` — registered and deaf: messages land on disk and
  nothing announces them. Arm `wait --follow` (re-run `/bridger:register`).
- nothing at all — this session is not registered.

Usually nothing to do: when a drop-in dispatcher already runs the statusline,
`register` wires the badge itself (it only adds a fragment, so the badge lights
in the same session). This command is for the cases registration will not touch
on its own — no statusline at all, or one that does not read the drop-in dir.
Run:

`"${CLAUDE_PLUGIN_ROOT}/bin/bridger" statusline`

It installs the badge as a **drop-in fragment** (`~/.claude/statusline.d/50-bridger.sh`)
and wires it without ever overwriting another tool's statusline. Then:

- **Exit 0** — done. Relay its confirmation line to the user. If this was the
  first-ever wiring (it just installed the dispatcher and pointed
  `settings.json` at it), the badge appears in the **next** Claude Code session
  — changing `.statusLine.command` is not hot-reloaded. From then on it is live:
  `bridger register <name>` lights the badge on the next statusline tick with no
  restart, and `bridger leave` clears it.
- **Output starts with `NEEDS-CHOICE`** (followed by a tab and the user's current
  statusline command) — the user already runs their own statusline that does not
  include the badge, and bridger will not overwrite it. Show them that command
  and offer two ways to add the badge:

  1. **Convert to the drop-in dispatcher (recommended — collision-proof).** So no
     future statusline setup can strand any badge:
     - Copy `${CLAUDE_PLUGIN_ROOT}/hooks/statusline-dispatch.sh` to
       `~/.claude/hooks/statusline-dispatch.sh`.
     - Move their current behavior into a fragment `~/.claude/statusline.d/10-mine.sh`
       — a small script that runs their old command with the statusline JSON on
       stdin (their badge keeps its place; the `10-` prefix renders it first).
     - Point `settings.json` `.statusLine.command` at
       `bash "$HOME/.claude/hooks/statusline-dispatch.sh"`.

  2. **Chain (quick, less robust).** If their command runs a script file, append
     to that script, before its final print:

     ```bash
     bridger_badge=$(bash "$HOME/.claude/hooks/bridger-statusline.sh" <<<"$input" 2>/dev/null)
     [ -n "$bridger_badge" ] && printf ' %s' "$bridger_badge"
     ```

  Never overwrite a statusline command you don't understand — ask first.

After wiring, confirm `jq . ~/.claude/settings.json` still parses.
