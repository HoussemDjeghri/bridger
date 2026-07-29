---
description: List bridger peers — who is addressable, where, and what they're doing
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" peers
```

Show the output to the user. Each line is `name [status] directory @branch — summary`.

For `listening` and `queued`, the status column is watcher liveness, not
reachability. `listening` means that session's watcher is running. `queued`
means it is not — which covers both a closed session and a live one that never
armed a watch, since registering does not start one. A `queued` peer is still
registered, still addressable, and still receives; it may just read the message
later. Never report either of those as unreachable from this column alone —
that is what `ask <peer> --timeout` tests.

`missing` is `queued` plus two facts: that peer's registered directory no longer
exists, and no watcher process is running for the name (a watcher still running
keeps it `queued`, because someone is demonstrably there).
It is still addressable and still receives, and it is NOT proof the peer
is dead — a session whose worktree was removed keeps its working directory and
goes on polling and sending, so it may well read the message. Treat it as a
normal peer; do not skip it and do not report it as unreachable.

What it usually means is a leftover registration from a deleted worktree. If the
user asks about one, or several show up, offer to run `bridger reap` — it lists
each one with how much unread mail it still holds. `bridger reap --force` drops
them, keeping their threads as history. Point out the unread counts before
dropping anything: a session still open in a removed directory cannot be
detected, and dropping its registration strands its mail for good.

If the current directory is not registered, offer `/bridger:register <name>` —
the bridger is opt-in, so only registered directories appear here.
