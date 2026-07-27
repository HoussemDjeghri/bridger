---
description: Open the read-only web view of peers, threads and bus health
argument-hint: [--port N]
---

Start the monitor as a background task, so this session stays usable:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" monitor --no-open $ARGUMENTS
```

Report the URL it prints (default `http://127.0.0.1:8787`) and tell the user to
open it. It serves on loopback only and needs `python3`.

The monitor is read-only: it parses the state files and never writes one, so it
does not consume unread messages or advance any cursor. Leaving it running does
not affect any session. Stop it by killing the background task.
