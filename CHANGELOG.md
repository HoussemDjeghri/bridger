# Changelog

All notable changes to bridger are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and bridger uses
[semantic versioning](https://semver.org/).

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

[0.7.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.1
[0.7.0]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.7.0
[0.6.2]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.2
[0.6.1]: https://github.com/HoussemDjeghri/bridger/releases/tag/v0.6.1
[0.6.0]: https://github.com/HoussemDjeghri/bridger/releases
