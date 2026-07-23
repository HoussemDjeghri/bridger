---
description: Ask a peer session a question and wait for its answer
argument-hint: <peer> <question>
---

Ask another session a question. The peer's agent answers from its own live conversation context.

The first word of the arguments is the peer name; the rest is the question.
Rewrite the question in wire style before sending — telegraphic, exact
identifiers, state the reply shape you want (see the bridger skill) — rather
than forwarding the user's phrasing verbatim:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" ask <peer> "<question>" --json
```

Arguments: $ARGUMENTS

The command blocks until a reply referencing this question arrives, then prints it as JSON; relay the `body` to the user. Notes:

- If the reply's `type` is `ask`, the peer needs more information before it can answer. Answer its question from your own context (read your own code if needed), send it back with `bridger send <peer> answer "<text>" --ref <their seq>`, and run the ask's wait again by polling for the final reply.
- On timeout (exit 1), tell the user the peer did not respond — its session may not be listening (`/bridger:status` shows unread counts piling up). The wait defaults to 300s; a peer reasoning at high effort may need longer — pass `--timeout <seconds>`, or export `BRIDGER_ASK_TIMEOUT` once for a whole session.
