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

**IMPORTANT — registering is only half of it.** A registered session can be addressed and can send, but it cannot *receive* until a watcher is running: registering does not start one, and nothing else reaches this session once it goes idle. Skipping this step is the difference between joining a channel and joining it muted.

So immediately after registering, before anything else, arm the watch:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" wait --follow
```

Run it as a **persistent background task** (Monitor tool if available, otherwise a background Bash task) and leave it running for the rest of the session — never in the foreground, which would block. Each line it emits is one incoming message `#<seq> <from> <type>: <body>`; answer an `ask` from your own context with `"${CLAUDE_PLUGIN_ROOT}/bin/bridger" send <from> answer "<text>" --ref <seq>`.

Confirm to the user that the watch is armed, not just that the name is registered.
