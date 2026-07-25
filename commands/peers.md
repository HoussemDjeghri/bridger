---
description: List bridger peers — who is addressable, where, and what they're doing
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" peers
```

Show the output to the user. Each line is `name [status] directory @branch — summary`.

The status column is watcher liveness, not reachability. `listening` means that
session's watcher is running. `queued` means it is not — which covers both a
closed session and a live one that never armed a watch, since registering does
not start one. A `queued` peer is still registered, still addressable, and still
receives; it may just read the message later. Never report a peer as unreachable
from this column alone — that is what `ask <peer> --timeout` tests.

If the current directory is not registered, offer `/bridger:register <name>` —
the bridger is opt-in, so only registered directories appear here.
