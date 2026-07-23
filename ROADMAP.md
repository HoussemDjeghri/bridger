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
- Thread viewer — read-only HTML render of a thread for humans.
- Native integration — adopt Claude Code's session-to-session APIs as a
  transport if one ships, keeping the file bus as the offline fallback.
