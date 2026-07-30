# Roadmap

The bar for every item: it must serve a real coordinator/worker channel
between long-lived sessions, and it must not risk that channel to please a
hypothetical user. Fancy features that fail that test get cut, not queued.

Nothing is scheduled. These are revisited only on real need:

- `doctor` / `gc` — environment check and thread cleanup.
- Structured payload schemas — typed bodies (diff, file-ref, task) with
  validation on receipt.
- MCP server variant — expose send/poll/ask as MCP tools over the same files.
- Cross-machine transport — pluggable mailbox backend plus an auth story.
- Native integration — adopt Claude Code's session-to-session APIs as a
  transport if one ships, keeping the file bus as the offline fallback.

## Accepted costs — audited, measured, deliberately not fixed

Found by the plugin-wide audit and closed as cost or diagnostic quality, not
correctness. None of these can lose or misroute a message. Reopen one only if it
shows up in real use; the reproduction and the measurement for each are in the
audit reports under
`~/.claude/projects/-Users-houssem-Documents-bridger/audit/`.

- **The delivery hooks' marker gate is unscoped.** `find "$BRIDGER_ROOT/threads"
  -name '*.json' -newer "$marker"` matches traffic between *any* two peers, so one
  unrelated message in flight puts every session on the machine back on the full
  path. It was filed at 0.129s idle vs **3.31s** busy, at 51 peers — a
  delivery-failure risk against the 5s hook timeout. **Re-measured at 0.15.0 on the
  same fixture: 0.239s idle, 0.543s busy, 0.509s on the first call of a session,
  0.262s for a session that is not a peer at all.** The registry read and the
  by-name `peers` lookup took the full path apart, so the timeout is no longer
  reachable at any plausible peer count and the scoping is not worth its risk.
  Spec: `cycle5-hooks.md` `## C6`.
- **`poll --peek` has no `--limit`.** `deliver.sh` shows at most 5 lines but scans
  the whole unread run. Design is worked out and sound (`cycle6-delivery.md`), but
  0.14.0 removed both reasons it was urgent — the fork-per-message cost and the
  `ARG_MAX` cliff. Building it now would add a flag with two ways to lose mail
  (a limit on a consuming poll, a limit counted in files rather than selections)
  to bound a scan that costs 0.35s at 51 peers.

Everything else the audit found has now been read first-hand and either fixed or
listed above — there is no untriaged tail. What was fixed is in the CHANGELOG;
the reproduction for each is in the audit reports. The bar stays "can it lose or
misroute a message", and it is applied by reading the finding, not by assuming.
