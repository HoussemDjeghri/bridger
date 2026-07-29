---
description: Send a message to a peer session
argument-hint: <peer> <message>
---

Send a one-way message to another session's bridger inbox (no reply expected).

The first word of the arguments is the recipient — one peer, a comma list
(`w1,w3`: exactly those peers), or `@all` (every other peer); the rest is
the message.
Compose the body in wire style — telegraphic, exact identifiers, no prose
padding (see the bridger skill):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" send <peer> chat "<message>"
```

Arguments: $ARGUMENTS

If the send fails because this directory has no identity, register first (`/bridger:register`). Confirm to the user that the message landed (the command prints its sequence number).

A fan-out (`@all` or a comma list) prints one line per recipient — `<peer> <seq>`
on success, `<peer> FAILED` on failure — and exits nonzero if any recipient
failed. Read those lines before reporting: some peers can land while others do
not, so name the ones that failed rather than confirming the message went out.
