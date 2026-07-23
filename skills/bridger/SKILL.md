---
name: bridger
description: Coordinate with another Claude Code session over the bridge — discover peers, ask them, answer their questions — INSTEAD of guessing or asking the user. Trigger this the moment the task depends on something another repo's session knows: a dependency/library that changed and this code consumes it, an API or schema contract owned by a different session, a monorepo service another session is editing, a migration to a new version, or coordinating a planner/implementer split. Also trigger when an incoming bridge message (a terse line "#<seq> <from> <type>: <body>") appears in a watcher notification and must be answered.
---

# Talking to peer sessions over the bridger

The bridger is a file-based message bus between Claude Code sessions. Each
session is a named peer; messages are immutable JSON files in a per-pair
thread. The CLI lives at `${CLAUDE_PLUGIN_ROOT}/bin/bridger`.

## Message format

Delivered messages are one terse line each:
`#<seq> <from> <type>[ re#<ref>]: <body>` — e.g. `#3 my-library answer re#2: use authenticate()`.
`re#<ref>` marks a reply to that seq. Types by convention: `chat` (no reply
expected), `ask` (peer should reply), `answer` (reply, carries ref).
On disk each message is full JSON (`{seq, from, to, type, body, ts, ref?}`);
`poll --json` / `ask --json` emit that form when fields are needed.

## When a message arrives (watcher notification or `poll` output)

1. Read the type and body from the line.
2. `ask` → answer it **from your own live context** — that is the whole point
   of the bridger; the asking session cannot see this repo or conversation.
   Read your own files if needed, then:
   `bridger send <from> answer "<text>" --ref <seq>`
3. If you cannot answer without more information from the asker, send a
   counter-question instead: `bridger send <from> ask "<question>" --ref <seq>`.
   The asker treats a reply of type `ask` as "answer this first".
4. `chat` → surface it to the user; reply only if it requests something.
5. Never leave an `ask` unanswered silently — if you genuinely cannot answer,
   say so in an `answer` message.

## Wire style — how to write message bodies

Bodies are read by the peer AGENT, not by a person. Optimize for the agent
parsing it exactly, in the fewest tokens; a human skimming `bridger log` is
secondary. Rules:

- Telegraphic. Drop greetings, hedging, filler, framing ("I was wondering
  if you could..."). Start with the payload.
- NEVER drop precision. Exact identifiers always survive compression: full
  symbol names, `path/to/file.ts:42`, versions, error text quoted verbatim.
  A short vague message is worse than a long exact one.
- Structure over prose. `key: value` lines, `->` for renames/moves, `!` for
  breaking, `?` prefix for each thing you need answered.
- One message = one intent. Two unrelated questions are two asks, so each
  reply correlates cleanly by ref.
- Address only who it concerns: `send w1,w3` or `send @all`. A message to an
  uninvolved peer wastes that session's context.
- In an ask, state the answer shape you want: "reply: list of `old -> new`",
  "reply: yes|no + reason".
- Answers mirror the question's structure and add nothing else. If the
  answer is a value, send the value.

Example — same content, wire style:

    verbose (~60 tokens):
      "Hi! I noticed you recently made some changes to the auth module.
       Could you let me know which functions changed and how I should
       update my calls? Thanks!"

    wire (~25 tokens):
      "? auth module breaking changes since v1.x. reply: list old -> new
       + call-site notes"

    answer:
      "login() -> authenticate(cfg: Config); getUser() -> getCurrentUser(),
       returns UserProfile; refreshToken() removed (auto). callers: replace
       try/catch AuthError -> AuthException"

## Asking a peer

`bridger ask <peer> "<question>" --timeout 120` blocks until the matching
reply (ref == your ask's seq) and prints it. While waiting, unrelated
consumed messages are echoed to stderr — handle them after the ask resolves.

## Automate this — recognize the pattern, then act without being asked

The point of the bridge is to ask a peer instead of guessing. When any of
these appear mid-task, run `bridger peers` first (see who is registered and
what they are working on from their summaries), then `ask` the right one:

- **You're about to guess at something another session owns.** A function
  signature, an API response shape, a config key, why a value changed — and a
  registered peer authored it. Ask; don't infer from a stale file or a diff.
- **A dependency changed under you.** Build breaks or types don't line up
  after a version bump, and the library's repo has a peer. Ask it for the
  breaking changes and the migration, then apply them.
- **The user points at "the other session" / another repo.** "update our app
  to the new lib", "match the backend's new contract". Resolve the peer and ask.
- **Cross-service work in a monorepo.** Your change touches a boundary another
  session is editing. Coordinate before you both land conflicting edits.
- **You finished work a coordinating session is waiting on.** Notify it
  (`send <peer> chat "..."`) so it can proceed.

Decision rule: if the missing fact lives in another **session's live context**
(not in this repo, not derivable from the diff), that is a bridge `ask`, not a
guess and not a question for the user. If it lives in a **file or command
output here**, just read it — don't bridge for what you can look up.

Before asking, set your own summary once (`bridger summary "<one line>"`) so
the peer you're contacting can see who you are in its own `peers` list.

## Housekeeping

- `bridger peers` — who is addressable: name, live status (`listening` /
  `queued` — both receive), directory, branch, self-set summary. The bridger is
  opt-in: only registered directories appear.
- `bridger summary "<one line>"` — describe what this session is doing so
  other agents pick the right peer.
- `bridger status` — identity, peers, unread counts.
- `bridger poll --peek` — inspect unread without consuming.
- `bridger log <peer>` — full audit trail of a thread.
- Only one session per peer name should be open at a time; the cursor that
  tracks read position assumes a single consumer.
