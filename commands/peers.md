---
description: List bridger peers — who is addressable, where, and what they're doing
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" peers
```

Show the output to the user. Each line is `name [status] directory @branch — summary`:
`listening` means that session's watcher is live; `queued` means messages will
wait on disk until it next starts. Both can be messaged.

If the current directory is not registered, offer `/bridger:register <name>` —
the bridger is opt-in, so only registered directories appear here.
