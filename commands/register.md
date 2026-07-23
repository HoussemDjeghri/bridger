---
description: Register this project directory as a named bridger peer
argument-hint: <name>
---

Register the current project as a bridger peer so other Claude Code sessions can message it.

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" register $ARGUMENTS
```

If no name was given, derive a short lowercase one from the directory name (letters, digits, single dashes) and use it. Report the registered name back to the user — they will type it in the other session to address this one.

After registering, arm the incoming-message watch: run `"${CLAUDE_PLUGIN_ROOT}/bin/bridger" wait --follow` as a persistent background watcher (Monitor tool if available, otherwise a background Bash task). Each line it emits is one incoming message.
