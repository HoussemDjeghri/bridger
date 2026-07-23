---
description: Show bridger identity, peers, and unread message counts
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/bridger" status
```

Report the output to the user. If there are unread messages, offer to consume them now with `"${CLAUDE_PLUGIN_ROOT}/bin/bridger" poll` and act on each one.
