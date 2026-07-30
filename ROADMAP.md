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
  path. Measured at 51 peers: 0.129s idle vs 3.31s with one unrelated message.
  Was a delivery-failure risk while the full path cost ~204 forks; at 9 forks
  (0.14.0) it is a cost. Scoping it to `threads/*$me*` needs `$me`, which
  0.14.0's registry read made cheap. Spec: `cycle5-hooks.md` `## C6`.
- **`poll --peek` has no `--limit`.** `deliver.sh` shows at most 5 lines but scans
  the whole unread run. Design is worked out and sound (`cycle6-delivery.md`), but
  0.14.0 removed both reasons it was urgent — the fork-per-message cost and the
  `ARG_MAX` cliff.
- **`session-start.sh`'s "this session is *now* registered" is unbounded and can be
  wrong.** It fires on registrations that are not this session's. Noise, not
  misdelivery. Cycle-3 F5.

Not yet triaged against this bar: identity C1/C5/C6/C7, hooks C7/C8, delivery
C5-2/5/6/9/10/11/12, monitor F8/F10. Read each before filing it here — the point
of the bar is that it is applied, not assumed.
