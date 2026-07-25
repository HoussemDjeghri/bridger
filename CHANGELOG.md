# Changelog

All notable changes to bridger are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and bridger uses
[semantic versioning](https://semver.org/).

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

[0.9.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.9.0
[0.8.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.8.0
[0.7.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.1
[0.7.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.0
[0.6.2]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.2
[0.6.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.1
[0.6.0]: https://github.com/HoussemDjeghri/bridger/releases
