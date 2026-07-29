# Changelog

All notable changes to bridger are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and bridger uses
[semantic versioning](https://semver.org/).

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
