# Changelog

All notable changes to bridger are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and bridger uses
[semantic versioning](https://semver.org/).

## [0.15.0] — 2026-07-31

Thirty-two commits of audit work, and the shape of it is one sentence: every failure this plugin has is silent by construction, so the release is mostly about faults that used to pass without a word.

**A dangling symlink where a message should be stopped being invisible.** The scan's `[ -e ]` skipped it, so the message vanished from every listing with no warning. `max_seq` skipped it too, which was worse: the seq stayed "free", the atomic `ln` failed `EEXIST` while `[ -e ]` reported the target absent, and `send` took the not-a-collision branch and died — permanently, for every future message to that peer, with a permissions error that was false.

**A wedged thread now says so where it matters.** A message that cannot be read stops delivery for the whole thread; `poll --peek`, `poll --json` and a blocked `ask` all reported nothing. The delivery hook said "1 unread" for three that would never move, and `ask` waited out its full timeout for an answer that could not arrive. All three now carry the fault, and `status` reports `N+` rather than a floor presented as a fact.

**`ask bob` drained the whole bus.** It polled every thread, so carol's mail was consumed and her cursor advanced while the content went to stderr — which the delivery hook discards. It polls one thread now, and fails fast when that thread is stuck.

**Two sessions in one repository could take each other's identity.** session-start told a second tab that a live session's name was held by nobody, off a missing heartbeat that the rest of the codebase explicitly refuses to read as death; the loser's badge then kept rendering the name in green, off the *new* owner's heartbeat. Reclaiming a `missing` name is still allowed — it is the only way a deleted worktree is ever recovered — but it now says which directory held the name, how much mail moves with it, and that a session still open there has just lost both. It no longer inherits the previous holder's summary, which is the column agents pick a peer by.

**The monitor stopped disagreeing with the CLI about what it is looking at.** One fifo anywhere in the bus blocked a request thread in `open()` forever; the page polls every two seconds, so an open tab leaked roughly 1800 permanently-stuck threads an hour and answered 200 again the moment the fifo was gone. And a thread the CLI refuses to deliver rendered as a routine amber "2 queued" — it now reads `N+`, in red, and names the file.

**Under concurrency, a lock that was merely contended could fail the write.** `peer_lock` inferred "this can never succeed" from the lock being absent when it looked — which is also exactly what a holder releasing between two syscalls looks like. The write then died quoting mkdir's own "File exists", the error that proves the lock *was* held and waiting was right. Load-dependent: one failure per 150–360 writes in a standalone harness, and one self-check run in three. It asks the bus directly now, and a second obstruction can no longer be confused with a lock taken mid-check — 0 failures in 600 concurrent writes to one record.

Also: a derived name can no longer exceed the length its own validator accepts (which made a peer mute in both directions and broke `@all` for everyone else); `dormant` no longer offers an address-less record as reclaimable in every directory on the machine; a rename keeps the summary and the created stamp; a killed `poll` cleans up its scratch file; `send` into an unwritable thread names the bus instead of printing a raw `mkstemp` error; the stuck-thread notice names what was observed rather than asserting a permission that a full disk does not have; and the "this session is now registered" nudge — which fired off any command that merely mentioned the phrase — now claims only what it checked, once per session.

The self-check went from 81 assertions to 101, and the monitor's own from 46 checks to 59. Every fix here was mutation-verified: the guard was reverted in a fresh copy of the tree and the suite confirmed red before the fix was kept. One exception, stated because it is the honest one — the leaked scratch file is a signal race, so an assertion on it would be flaky in the direction that blocks a release; it was verified by hand against a mutant instead (0 leaked with the fix, 2 without, same six kills).

## [0.14.0] — 2026-07-30

A backlog used to be able to lock a session out of its own mail permanently. The unread scan forked one `jq` per unread message, and the delivery hooks — the only thing that reaches a session with no watcher — call it under a 5s timeout. Past roughly 1400 unread the hook was killed mid-scan on every single invocation, its output discarded, and because `--peek` deliberately never consumes, the backlog could not shrink. Every tool call and every prompt repeated the same timeout with the same zero bytes, with no error anywhere.

The scan now selects the whole unread run in one batched `jq`, chunked so the argv cannot outgrow `ARG_MAX` at any bus-root depth. **`poll --peek` over 3000 unread: 10s → 0s.**

The same budget was being spent on peer count. Identity resolution ran two `jq` plus a `basename` per peer record and every hook call resolves identity three times; on top of that both hooks rendered a listing of *every* peer to answer "is my own watcher alive". At 81 peers that put the hook over its timeout, where it is killed before it can stamp its marker — so the next tool call repeats the work and it never converges. **One `deliver.sh` call at 40 peers: 204 `jq` forks / ~3.0s → 9 forks / under 0.01s.**

A watcher could also lose its own name by being busy. The heartbeat is refreshed once per loop, outside the poll, so a poll longer than the 15s staleness window made a demonstrably running watcher read `[queued]` — senders were told it was not listening, the badge flipped, and a second session in the same directory could take its name and its read cursor while the live watcher went on consuming the mail. The refusal now keys on the pid that was on disk the whole time, and the beat stays fresh across a long poll.

`peers` takes an optional name and lists just that peer.

- fix(poll): one `jq` for the unread run instead of one per message — past ~1400 unread the delivery hook was killed on every call and delivered nothing, permanently
- fix(poll): the batched scan chunks its argv, so a deep bus root has no `ARG_MAX` cliff of its own
- fix(poll): a non-object message is reported instead of being consumed in silence — `jq` exits 0 on a runtime `error()` across a multi-file argv, so the guard was inert for any run of two or more messages
- fix(poll): one file per seq, scanned in that seq's order — out of order, a wedge marked messages read that had never been delivered
- fix(poll): a thread that cannot be written no longer wedges in silence
- fix(identity): a watcher whose process is alive keeps its name through a stale heartbeat; a second session can no longer take a busy watcher's name and cursor
- fix(identity): the heartbeat stays fresh across a long poll, and only for the watcher — a plain CLI poll must never claim a watcher the session lacks
- fix(identity): a peer directory whose path contains a newline is refused rather than shifting every field that follows it
- fix(peers): a record with no directory addresses nothing, instead of answering for every directory on the machine
- fix(peers): a lock that cannot be taken fails instead of spinning in silence
- fix(hooks): per-session markers — one session's report no longer silences every other session's waiting mail
- fix(hooks): badge state never outranks the mail
- fix(monitor): one bad file no longer 500s the web view
- perf(identity): the peer registry is read once, not twice per record — `whoami` at 40 peers, 80 `jq` forks → 1
- perf(hooks): the hooks ask about one peer instead of all of them
- feat(peers): `bridger peers <name>` lists a single peer

Self-check: 81 assertions, up from 52 at 0.13.0.

## [0.13.0] — 2026-07-29

A deleted worktree used to leave its peer behind forever: `leave` resolves the peer from `$PWD`, which is impossible once that directory is gone, so the name sat in every listing with no way to remove it.

**`bridger reap`** lists those registrations; `--force` drops them, keeping their threads on disk exactly as `leave` does. Dry run by default, printing how much unread mail each still holds — an unmounted volume looks identical to a deleted one, so the call is the operator's.

`peers` grows a third status, **`missing`**: a queued peer whose registered directory is provably absent and for which no watcher is running.

Nothing routes on it, deliberately. A process keeps its working directory when that directory is unlinked, so a session in a removed worktree goes on resolving its name, polling and sending. `@all` still reaches a `missing` peer, `ask` still waits for it, `send` still stores for it.

- fix(peers): one malformed record no longer aborts the listing — it was hiding every peer sorting after it, and silencing unread reports for every session through `deliver.sh`/`stop.sh`
- fix(poll): an empty cursor no longer reads as "everything delivered", which advanced to the top and lost the thread's mail silently
- fix(poll): one unparseable message no longer wedges a thread forever; only a parse error skips a message, while a transiently unreadable one refuses to advance the cursor rather than consume it
- fix(identity): resolution keys off the filename that is the actual address, and no longer carries a failed record's predecessor into scope
- fix(peers): concurrent writers of one record can no longer commit interleaved garbage

## [0.12.0] — 2026-07-27

- feat(monitor): see every conversation and the bus health in a browser
- feat(watcher): make a deaf session visible

## [0.11.0] — 2026-07-25

A send succeeds whether or not anything is reading at the other end, and it reported only the sequence number. From the sender's side, "hasn't replied yet" and "cannot hear me" looked identical — so a session could send five messages to a peer that never armed a watch and get no hint it was talking to itself.

**`send` now warns when the target is not listening**, with the count of messages from you still unread — so the first send says it, not the fifth:

```
warning: 'exec' is not listening — no watcher is running there, and 1 message(s)
from you are unread. It will read them on its next activity, not now. Sending
more will not reach it any sooner.
```

On stderr specifically: stdout stays the bare sequence number that callers and the multi-recipient path parse.

**`status` grows the other direction.** Alongside each peer's live status, `unread-by-them` is how much of what you have said has not landed yet. Growing means you are not being heard.

```
peer: exec [queued]  unread: 0  unread-by-them: 5
```

The bundled skill turns that into a rule: treat the warning as a stop signal, don't queue more behind it, check `unread-by-them`, and escalate to the user by name when blocked on that peer — a human can bring that session back, the agent cannot.

Completes the arc of v0.9.0 and v0.10.0, which made the receiving side reliable. This is the sending side finally being told the truth.

## [0.10.0] — 2026-07-25

Registering a session made it addressable but not reachable. Receiving needs a watcher (`wait --follow`), and starting it was one line of prose at the end of a command doc — skip it and the session is registered and deaf. Joined to the channel, muted.

The watcher can only be started by the agent: delivery works by its output re-invoking the agent, so a watcher spawned by the CLI or a hook would keep the heartbeat fresh with nobody reading it — a peer advertising `listening` while messages pile up unseen. Honest and unarmed beats armed and lying. So arming stays the agent's job, and this release makes it hard to skip rather than optional.

**`Stop` hook** — a registered session with no watcher is blocked once at the end of its turn, with the command to run as the reason. End of turn is exactly where the watcher stops being optional: nothing else reaches an idle session. Once per session, and the marker is written before blocking, so an agent that ignores it still gets its turn back instead of looping.

**`PostToolUse` hook** — waiting messages are surfaced between tool calls. This closes the case the work started from: a ruling landing while a spec was being written, unseen until the session ended. Reported once per arrival rather than per tool call, gated by a single `find -newer` so the no-op path stays cheap. It also injects the arm-the-watcher instruction next to a `bridger register` call's own result.

**`/bridger:register`** now leads with the watcher as half of registering, and confirms the watch is armed rather than just the name registered.

The `UserPromptSubmit` hook from v0.9.0 is now one of three cadences on the same script (`hooks/deliver.sh`). Its marker no longer advances the `PostToolUse` high-water mark — that was suppressing the first mid-task report of a message seen once at turn start.

Docs stop describing the watcher as a fallback. It is the primary delivery path; the hooks are what cover its absence.

## [0.9.0] — 2026-07-25

A session could conclude that a live, answering peer was unreachable — and then write a whole deliverable against stale facts. Two causes, both closed.

**`queued` no longer reads as "nobody home".** Peer status measures exactly one thing: whether that peer's watcher process is running. Registering does not start one, so `queued` covered both a closed session and a live session that never armed a watch. The distinction was documented only in `bridger help` and the command docs — never in the output a session reads mid-task. `bridger peers` now prints it inline whenever it lists a queued peer other than yourself.

**Unread messages can no longer sit silently.** With no watcher running, nothing polled after session start, so a peer's answer or a coordinating session's ruling landing mid-task stayed invisible until the next session. A new `UserPromptSubmit` hook surfaces what is waiting on every user turn. It is a no-op while a watcher is already pushing, and it peeks rather than polls — it can never consume a message out from under the agent.

Arming the watcher stays the agent's job: a process spawned from a hook has nowhere to deliver to once the hook's output is consumed. The docs now say that plainly, and mark the new hook as a backstop that does not cover the stretch between two user turns — re-poll before committing to a long deliverable that depends on a peer.

Also updated: the bridger skill, `/bridger:peers`, the `SessionStart` guidance, and README troubleshooting. Self-checks cover the new hook end to end.

## [0.8.0] — 2026-07-25

- feat(statusline): register self-wires the badge into a live drop-in dispatcher
- chore: drop shadow marketplace manifest

## [0.7.1] — 2026-07-24

- fix(identity): per-session identity — never inherit a directory's names

## [0.7.0] — 2026-07-24

- feat(statusline): live per-session badge showing the registered peer name
  (`[⇄ BRIDGER:<name>]`), wired as a collision-proof drop-in fragment that
  coexists with other tools' statusline badges. `register` lights it on the
  next tick; `leave` clears it. `/bridger:statusline` wires it (never
  overwriting a foreign statusline); the SessionStart hook offers it once and
  self-heals if another setup unwires it. The registered name is sanitized to
  a safe charset before it reaches the terminal.

## [0.6.2] — 2026-07-23

### Changed
- `bridger ask` now waits **300s** for a reply by default (was 120s). A peer
  reasoning at high effort could be cut off mid-answer under the old default.

### Added
- `BRIDGER_ASK_TIMEOUT` environment variable sets the default reply-wait for a
  whole session — export it once for an unattended run. Precedence:
  `--timeout` flag > `BRIDGER_ASK_TIMEOUT` > 300s.

### Fixed
- The `/bridger:ask` command no longer pins a 120s timeout; it inherits the
  default and honors `BRIDGER_ASK_TIMEOUT`.
- A non-numeric timeout is now rejected with a clear message instead of failing
  cryptically later.

## [0.6.1] — 2026-07-23

### Changed
- README reframed around sessions rather than folders: any two Claude Code
  sessions on one machine can talk. Added the flagship "parallel worktrees, one
  architect" use case, a comparison with subagents, and the coordinator/worker
  effort-split pattern.

### Added
- `scripts/release.sh` — bumps the version, syncs the README badge, runs the
  self-checks, then commits and tags a release in one step.

## [0.6.0] — 2026-07-18

### Fixed
- Two sessions in the **same directory** (same branch, no worktree) can now hold
  distinct identities and message each other. Identity resolves by Claude Code
  session id first and the directory second, so sessions no longer collapse into
  a single peer when they share a folder.

### Changed
- A registered name is a unique live address: while a session holds it with a
  fresh heartbeat, a second session is refused that name; once the holder goes
  away, the name can be taken over — how a restarted session reclaims its role.

[0.15.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.15.0
[0.14.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.14.0
[0.13.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.13.0
[0.12.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.12.0
[0.11.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.11.0
[0.10.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.10.0
[0.9.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.9.0
[0.8.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.8.0
[0.7.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.1
[0.7.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.0
[0.6.2]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.2
[0.6.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.1
[0.6.0]: https://github.com/HoussemDjeghri/bridger/releases
