#!/usr/bin/env python3
"""bridger monitor — read-only web view of the message bus.

Serves one page that renders $BRIDGER_ROOT the way a chat client renders
conversations: threads on the left, the selected conversation on the right,
plus a health bar that answers "is the plugin actually working".

READ-ONLY BY CONSTRUCTION. This process parses files and never writes one, and
never shells out to `bridger`: a consuming `bridger poll` advances
cursor-<name>, which would silently destroy a live session's pending-message
state. There is no POST route and no code path here that opens a file for
writing.

Binds loopback only. The snapshot carries full message bodies.

usage: server.py [--port N] [--root PATH] [--no-open] [--selftest]
"""

import argparse
import glob
import json
import os
import posixpath
import re
import shutil
import statistics
import sys
import tempfile
import time
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# A peer is "listening" while its watcher keeps the heartbeat fresh. Mirrors
# BEAT_STALE_SECS at bin/bridger:103 — keep the two in step.
BEAT_STALE_SECS = 15

# An 'ask' with no reply older than this is a stalled round trip, not one still
# in flight. A fixed heuristic, roughly twice the `bridger ask` default of 300s
# (bin/bridger:667) — it deliberately ignores a per-call --timeout or
# $BRIDGER_ASK_TIMEOUT override, so a longer-running ask can be flagged early.
STALE_ASK_SECS = 600

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(HERE)
LOGO_PATH = os.path.join(PLUGIN_ROOT, "assets", "logo.png")


def default_root():
    """Where bridger keeps its state. Mirrors bin/bridger.

    `or` treats an empty string like an unset one, which for the variable that
    picks WHICH BUS to read would silently point a caller at the user's real
    ~/.claude/bridger. The CLI refuses that; refuse it identically here, or the
    two sides disagree about which bus they are even looking at.
    """
    root = os.environ.get("BRIDGER_ROOT")
    if root is not None and not root:
        raise SystemExit(
            "bridger: BRIDGER_ROOT is set but empty — refusing to fall back to "
            "~/.claude/bridger (unset it to use the default)"
        )
    return root or os.path.expanduser("~/.claude/bridger")


def claude_config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def parse_ts(text):
    """bridger timestamps are `date -u +%Y-%m-%dT%H:%M:%SZ` (bin/bridger:67)."""
    if not text:
        return None
    try:
        naive = datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
    return naive.replace(tzinfo=timezone.utc).timestamp()


def file_age(path, now):
    """Seconds since mtime, or None when the file is absent."""
    try:
        return now - os.stat(path).st_mtime
    except OSError:
        return None


def dir_gone(path):
    """Mirrors dir_gone (bin/bridger): is this path provably absent?

    Not `not os.path.isdir(path)`, which is also False when a parent turned
    untraversable and swallows the PermissionError that says so. A live session
    may be reading inside, and `reap --force` would strand its mail. "I cannot
    look" has to answer False, the way it does for a pid we may not signal.
    """
    # os.path.exists, not lexists: bash's `[ -e ]` follows symlinks, so a dangling
    # link or a symlink loop has to answer the same on both sides. `or "."` for
    # the same reason — dirname bottoms out at "" here and at "." in bash, and a
    # relative cwd would otherwise disagree.
    if not path:
        return False
    if os.path.exists(path):
        return False
    parent = os.path.dirname(path) or "."
    while not os.path.exists(parent) and parent not in ("/", "."):
        parent = os.path.dirname(parent) or "."
    return os.access(parent, os.X_OK)


def watcher_alive(beat_path):
    """Mirrors watcher_alive (bin/bridger): the beat holds the watcher's pid, so
    a death shows immediately instead of at the end of the staleness window.

    An empty or non-numeric beat is a pre-0.12 watcher that only left an mtime —
    the CLI treats that as alive, and disagreeing here would report "queued" for
    a session `bridger peers` calls listening.
    """
    try:
        with open(beat_path, newline="") as handle:
            pid = handle.readline().rstrip("\n")
    except OSError:
        return False
    # bash's `case $pid in ''|*[!0-9]*)` is the definition of numeric, matched
    # literally. int() is looser than that in ways a beat file really hits: a
    # sign, a `_` digit separator, or the stray \r from a bus directory synced
    # through a Windows-aware tool all parse for int() and are rejected by the
    # CLI. Disagreeing means claiming a watcher runs where `peers` says none
    # does. A non-numeric beat is the pre-0.12 mtime-only case, not a fault.
    if not re.fullmatch(r"[0-9]+", pid):
        return True
    try:
        os.kill(int(pid), 0)
    except (OverflowError, OSError):
        # A pid too large for a C long raises OverflowError, and EPERM raises
        # PermissionError. bash `kill -0` exits nonzero for both, so both are
        # "not running" here — anything else 500s the endpoint or disagrees
        # with bin/bridger.
        return False
    return True


def beat_pid_alive(beat_path):
    """Mirrors beat_pid_alive (bin/bridger): is a watcher provably running?

    Differs from watcher_alive in what it does with "cannot tell". watcher_alive
    only refines a beat that is already fresh, so it assumes alive; this one
    decides whether an address is DEAD, so a missing beat or a beat with no pid
    answers False. Assuming a reader that is not there would keep a deleted
    worktree's registration alive forever.
    """
    try:
        with open(beat_path, newline="") as handle:
            pid = handle.readline().rstrip("\n")
    except OSError:
        return False
    # Same definition of numeric as watcher_alive and as bash — see there. Here
    # a non-numeric beat answers False: this decides whether an address is dead.
    if not re.fullmatch(r"[0-9]+", pid):
        return False
    # A pid too large for a C long raises OverflowError inside os.kill, which
    # would escape and 500 the whole endpoint. Bash's `kill -0` treats it as
    # "not a running process", so this must too.
    try:
        os.kill(int(pid), 0)
    except (OverflowError, OSError):
        # Includes EPERM. bash `kill -0` exits nonzero for a process it may not
        # signal, so reporting True here would disagree with bin/bridger — and
        # this answer decides what `reap` offers to delete.
        return False
    return True


def read_int(path):
    """A cursor file holds one integer. Absent or unreadable means 0 consumed."""
    try:
        # newline="" and rstrip("\n"): bash reads this as `cur=$(cat …)`, which
        # strips trailing newlines and nothing else, so a `\r` has to survive to
        # be judged — see below.
        with open(path, newline="") as handle:
            text = handle.read().rstrip("\n")
    except (OSError, ValueError):    # includes UnicodeDecodeError on raw bytes
        return 0
    # Numeric means exactly what bash's `case $cur in ''|*[!0-9]*) cur=0` means,
    # as in watcher_alive above. int() is looser in ways a cursor file really
    # hits — a sign, a `_` separator, Unicode digits, surrounding whitespace, the
    # stray `\r` from a bus synced through a Windows-aware tool — and every one of
    # those disagreements HIDES queued mail: the monitor reports nothing waiting
    # for a session the CLI is about to hand messages to.
    return int(text) if re.fullmatch(r"[0-9]+", text) else 0


def _reject_constant(token):
    """json.load accepts the non-standard NaN/Infinity/-Infinity literals, and
    json.dumps re-emits them by default — so the server answered 200 with a body
    no browser can parse, and the page died with no status code, no log line and
    nothing to point at the file. jq maps the same value to null and carries on,
    so the CLI read the peer fine while the monitor served garbage. Refuse at the
    boundary instead, and let the existing one-file warning report it.
    """
    raise ValueError("%s is not valid JSON" % token)


# Every "this one file is unreadable, degrade to a warning" handler catches the
# same three. RecursionError is the non-obvious one: it is a RuntimeError, so
# deeply nested JSON slipped past handlers that named only OSError and ValueError
# and 500'd the whole request — the exact blast radius they exist to prevent.
# Named once, because it was widened in two of the four places and the other two
# kept the bug.
UNREADABLE = (OSError, ValueError, RecursionError)


def _load_json(handle):
    return json.load(handle, parse_constant=_reject_constant)


def _load_object(path):
    """Read JSON that must be an object.

    A hand-edited file can be valid JSON of the wrong shape (`[]`, `null`, `5`),
    which json.load accepts and the next `.get()` turns into an AttributeError
    escaping as a 500. Raise ValueError instead, so the callers' existing
    "unreadable file" path handles it.
    """
    with open(path) as handle:
        record = _load_json(handle)
    if not isinstance(record, dict):
        raise ValueError("expected a JSON object, got %s" % type(record).__name__)
    return record


def read_peers(root, now, warnings):
    """Peer records plus the derived heartbeat status."""
    peers = []
    # glob.escape: the root is part of the pattern, so a directory like
    # /home/me/proj[1] would silently match nothing (or the wrong tree).
    for path in sorted(glob.glob(os.path.join(glob.escape(root), "peers", "*.json"))):
        name = os.path.basename(path)[: -len(".json")]
        try:
            record = _load_object(path)
        except UNREADABLE as err:
            # write_peer now lands atomically, so this is a hand-edited or
            # truncated record rather than a mid-write read. Either way it is one
            # peer: report it and keep serving the rest.
            warnings.append("peer %s unreadable: %s" % (name, err))
            continue
        beat = os.path.join(root, "peers", name + ".beat")
        age = file_age(beat, now)
        # The filename is the address, matching bin/bridger's listing. Trusting
        # .name would also carry a list or dict through to compute_metrics, whose
        # set of names needs them hashable — one bad record, endpoint-wide 500.
        record["name"] = name
        record["beat_age"] = age
        # Mirrors peer_status (bin/bridger), in its order. Liveness first: both
        # halves of that check — a fresh beat AND a live pid, since mtime alone
        # would call a killed watcher "listening" for 15s more. Only then
        # "missing": the registered directory no longer exists AND no watcher
        # process is running for the name. That is a housekeeping hint for
        # `reap`, never a reachability verdict — such a peer may still be a live
        # session reading from the removed path.
        #
        # isinstance: a hand-written record can carry a list or dict cwd, which
        # os.path.* raises TypeError on. That escapes the _load_object except
        # above and 500s the whole endpoint — one bad peer taking every peer,
        # thread and metric dark. A non-string cwd is no path we can prove absent,
        # so it stays queued, same as bin/bridger sees it.
        cwd = record.get("cwd")
        gone = isinstance(cwd, str) and dir_gone(cwd)
        record["status"] = ("listening"
                            if age is not None and age < BEAT_STALE_SECS and watcher_alive(beat)
                            else "missing"
                            if gone and not beat_pid_alive(beat)
                            else "queued")
        record["last_seen_age"] = _age_of(record.get("last_seen"), now)
        peers.append(record)
    return peers


def _age_of(ts_text, now):
    stamp = parse_ts(ts_text)
    return None if stamp is None else now - stamp


def read_threads(root, warnings):
    """One entry per peer pair, messages in seq order, delivery state resolved."""
    threads = []
    for directory in sorted(glob.glob(os.path.join(glob.escape(root), "threads", "*"))):
        pair = os.path.basename(directory)
        if not os.path.isdir(directory) or "--" not in pair:
            continue
        names = _split_pair(pair, warnings)
        if names is None:
            continue
        left, right = names
        messages = _read_messages(directory, pair, warnings)
        cursors = {
            left: read_int(os.path.join(directory, "cursor-" + left)),
            right: read_int(os.path.join(directory, "cursor-" + right)),
        }
        undelivered = {left: 0, right: 0}
        for message in messages:
            recipient = message["to"]
            delivered = message["seq"] <= cursors.get(recipient, 0)
            message["delivered"] = delivered
            if not delivered and recipient in undelivered:
                undelivered[recipient] += 1
        threads.append(
            {
                "id": pair,
                "a": left,
                "b": right,
                "messages": messages,
                "cursors": cursors,
                "undelivered": undelivered,
                "queued": undelivered[left] + undelivered[right],
                "last_ts": messages[-1]["ts"] if messages else None,
            }
        )
    threads.sort(key=lambda thread: parse_ts(thread["last_ts"]) or 0, reverse=True)
    return threads


NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


def _is_name(text):
    """Mirrors valid_name (bin/bridger:69-74): a doubled dash is forbidden, but
    a single trailing dash is not."""
    return "--" not in text and NAME_RE.match(text) is not None


def _split_pair(pair, warnings):
    """Recover the two peer names from a `<a>--<b>` directory name.

    thread_dir joins the sorted names with "--" (bin/bridger:151-154), and a
    name is allowed to END in a single dash — only a doubled dash is rejected
    (bin/bridger:69-74). So peers "ab-" and "abc" produce "ab---abc", where
    splitting on the first "--" silently yields "ab" and "-abc": neither is a
    real peer, so every cursor lookup misses and every message in that thread
    reads as permanently queued. Pick the split that satisfies the invariants
    rather than assuming the first one does.

    At most one split can ever satisfy them, so the first match is the answer:
    if a later "--" also split cleanly it would sit either inside the right half
    (which then contains "--") or immediately after this one (leaving the right
    half starting with a dash) — _is_name rejects both.
    """
    at = pair.find("--")
    while at >= 0:
        left, right = pair[:at], pair[at + 2:]
        if _is_name(left) and _is_name(right):
            return left, right
        at = pair.find("--", at + 1)
    warnings.append("thread %s is not a <a>--<b> pair — skipped" % pair)
    return None


def _read_messages(directory, pair, warnings):
    """Messages are immutable files named %05d.json; .msg.XXXXXX temps are not."""
    messages = []
    for path in sorted(glob.glob(os.path.join(glob.escape(directory), "[0-9]*.json"))):
        name = os.path.basename(path)
        stem = name[: -len(".json")]
        # ASCII digits only, exactly like bash's `case $stem in ''|*[!0-9]*)`.
        # Two separate bugs lived in the gap between `str.isdigit()` and `int()`,
        # which agree on neither end. `isdigit()` is true for the whole Unicode
        # digit category while `int()` accepts only the decimal one, so `0³.json`
        # (the glob anchors the first character only) passed this guard and then
        # raised ValueError from `int(stem)` OUTSIDE every handler — a 500 for the
        # entire snapshot, the exact blast radius these handlers exist to prevent.
        # And an Arabic-Indic stem like `3٤.json` satisfies BOTH, so it was
        # accepted silently: bin/bridger's `[0-9]` filter cannot see that file, so
        # the monitor rendered a message the CLI will never deliver and counted it
        # as queued mail no cursor can ever reach, with no warning at all.
        if not re.fullmatch(r"[0-9]+", stem):
            warnings.append("message %s/%s is not a numbered message — skipped" % (pair, name))
            continue
        try:
            with open(path) as handle:
                record = _load_json(handle)
            # int() inside the handler too: on 3.11+ it refuses a stem past
            # sys.get_int_max_str_digits(), and that ValueError would escape.
            messages.append(_normalize(record, int(stem)))
        except UNREADABLE as err:
            warnings.append("message %s/%s unreadable: %s" % (pair, name, err))
            continue
    messages.sort(key=lambda message: message["seq"])
    return messages


def _normalize(record, seq):
    """Coerce one stored message into the shape the rest of the app may assume.

    The seq comes from the FILENAME, not from the record, because that is what
    bridger itself treats as authoritative: max_seq reads it off the basename
    (bin/bridger:156-164) and the atomic hard-link write is what assigns it
    (bin/bridger:586). Trusting the body instead would let a hand-edited file
    disagree with the cursor it is compared against.

    The rest of the fields are filled in here, at the trust boundary. A record
    can carry a null where the CLI would always write a string, and every later
    consumer — the delivery comparison, the browser — would trip over it.
    """
    if not isinstance(record, dict):
        record = {}
    ref = record.get("ref")

    def text(value):
        """`x or ""` only replaces FALSY values, so a list or a dict went
        straight through. A non-string `to` then reached `cursors.get(recipient)`
        and raised TypeError on an unhashable key — which is neither OSError nor
        ValueError, so it escaped every per-file handler and 500'd the entire
        snapshot: one hand-edited message blanked peers, threads, metrics and the
        health bar together. A non-string `body` or `from` instead reached the
        browser, where `.replace` / `.split` threw inside the render and pinned
        the page on "reconnecting" while it kept showing the last good snapshot.
        "" is also the honest rendering: `jq 'select(.to == $me)'` never matches
        a non-string `to`, so the CLI cannot deliver such a message either.
        """
        return value if isinstance(value, str) else ""

    message = {
        "seq": seq,
        "from": text(record.get("from")),
        "to": text(record.get("to")),
        "type": text(record.get("type")),
        "body": text(record.get("body")),
        "ts": record.get("ts") if isinstance(record.get("ts"), str) else None,
    }
    if isinstance(ref, int) and not isinstance(ref, bool):
        message["ref"] = ref
    return message


def round_trips(threads, now):
    """ask -> answer pairing. `ref` is a seq, so matching is per thread."""
    latencies = []
    unanswered = []
    asks = 0
    for thread in threads:
        replies = {}
        for message in thread["messages"]:
            ref = message.get("ref")
            if ref is not None and ref not in replies:
                replies[ref] = message
        for message in thread["messages"]:
            if message.get("type") != "ask":
                continue
            asks += 1
            sent = parse_ts(message.get("ts"))
            reply = replies.get(message.get("seq"))
            if reply is not None:
                answered_at = parse_ts(reply.get("ts"))
                if sent is not None and answered_at is not None:
                    latencies.append(answered_at - sent)
            elif sent is not None and now - sent > STALE_ASK_SECS:
                unanswered.append(
                    {
                        "thread": thread["id"],
                        "seq": message.get("seq"),
                        "from": message.get("from"),
                        "to": message.get("to"),
                        "age": now - sent,
                    }
                )
    return {
        "asks": asks,
        "answered": len(latencies),
        "median_latency": statistics.median(latencies) if latencies else None,
        "stale": unanswered,
    }


def compute_metrics(peers, threads, root, now):
    """Everything the health bar shows. No instrumentation exists in bridger, so
    each of these is derived from state files."""
    listening = [peer for peer in peers if peer["status"] == "listening"]
    # A healthy hook leaves no trace: deliver.sh and stop.sh exit early once a
    # watcher is listening. So plugin health reads off message flow plus the
    # negative markers — armed-nudge-<sid> means the Stop hook had to block a
    # session that reached end-of-turn with nothing receiving for it.
    nudges = glob.glob(os.path.join(glob.escape(root), "armed-nudge-*"))
    # Deaf means "cannot hear what is actually waiting for it". A peer with no
    # watcher and nothing pending is just a closed session, not a fault — the
    # name stays addressable and the next session picks the messages up.
    #
    # Keyed off the names with pending mail rather than the registry, because
    # `bridger leave` deletes peers/<name>.json but keeps the thread
    # (bin/bridger:393): messages stranded for a departed name are exactly the
    # case this is meant to surface, and it would be invisible from the
    # registry side.
    waiting = {}
    for thread in threads:
        for name, count in thread["undelivered"].items():
            waiting[name] = waiting.get(name, 0) + count
    listening_names = {peer["name"] for peer in listening}
    deaf = sorted(
        name for name, count in waiting.items()
        if count > 0 and name not in listening_names
    )
    stamps = [
        parse_ts(message.get("ts"))
        for thread in threads
        for message in thread["messages"]
    ]
    stamps = [stamp for stamp in stamps if stamp is not None]
    return {
        "peers": len(peers),
        "listening": len(listening),
        "queued": sum(thread["queued"] for thread in threads),
        "threads": len(threads),
        # Messages, not timestamped messages: `stamps` drops anything whose `ts`
        # is missing or unparseable, so the flow tile read "0 messages" and turned
        # amber on a bus whose thread header, counting the same list, said 3. The
        # series below legitimately needs stamps; this number does not.
        "messages": sum(len(thread["messages"]) for thread in threads),
        "deaf": deaf,
        "nudges": len(nudges),
        "last_hour": sum(1 for stamp in stamps if now - stamp < 3600),
        "last_day": sum(1 for stamp in stamps if now - stamp < 86400),
        "newest_age": now - max(stamps) if stamps else None,
        "round_trips": round_trips(threads, now),
    }


def check_wiring(root):
    """Static "can this plugin even run" checks, none of which bridger reports."""
    settings_path = os.path.join(claude_config_dir(), "settings.json")
    plugin_name = _plugin_field("name") or "bridger"
    enabled = None
    plugin_key = None
    try:
        plugins = _load_object(settings_path).get("enabledPlugins", {})
        if not isinstance(plugins, dict):
            raise ValueError("enabledPlugins is not an object")
        for key, value in plugins.items():
            if key.split("@")[0] == plugin_name:
                plugin_key, enabled = key, bool(value)
                break
        if plugin_key is None:
            enabled = False
    except UNREADABLE:
        # No settings file, or one we cannot parse: report unknown rather than
        # claiming the plugin is disabled.
        pass
    return {
        # Every hook opens with `command -v jq || exit 0`, so a missing jq makes
        # the whole plugin an invisible no-op.
        "jq": shutil.which("jq"),
        "root": root,
        "root_exists": os.path.isdir(root),
        "plugin_key": plugin_key,
        "plugin_enabled": enabled,
        "plugin_version": _plugin_field("version"),
    }


def _plugin_field(key):
    """Read one field out of the shipped plugin manifest, so the monitor never
    restates a fact the manifest already owns."""
    try:
        return _load_object(os.path.join(PLUGIN_ROOT, ".claude-plugin", "plugin.json")).get(key)
    except UNREADABLE:
        return None


def snapshot(root, now=None):
    """Full state, rebuilt from disk on every request.

    ponytail: no mtime cache, no incremental scan. A rescan is a few globs and
    a json.load per message; add a cache only once a real tree makes it slow.
    """
    now = time.time() if now is None else now
    warnings = []
    peers = read_peers(root, now, warnings)
    threads = read_threads(root, warnings)
    return {
        "generated": now,
        "peers": peers,
        "threads": threads,
        "metrics": compute_metrics(peers, threads, root, now),
        "wiring": check_wiring(root),
        "warnings": warnings,
    }


# The loopback bind is the whole access-control story, and a browser can defeat
# it without ever leaving the user's machine: any site whose domain resolves to
# 127.0.0.1 reaches this server under its own origin, and /api/state hands back
# every message body. Only a Host the user could have typed is served.
ALLOWED_HOSTS = ("127.0.0.1", "localhost", "::1")


def _host_of(header):
    """The name out of a Host header, without the port. IPv6 arrives bracketed
    as `[::1]:8787`, where splitting on the first colon would give `[`.

    Anything that is not a host[:port] answers "" — an allowlist must not be fed
    a value assembled by discarding the parts that did not fit. Brackets used to
    be taken as "IPv6, trust what is inside", so `[localhost]`, `[127.0.0.1]` and
    `[::1]evil.example` were all served, as was `127.0.0.1:evil.example`. No
    browser produces those (they fail URL parsing before a request is made), so
    this was looseness rather than a hole — but this function IS the access
    control, and it should not depend on the client being a browser.
    """
    # Lower-cased: a Host header is case-insensitive per RFC 9110, so a user who
    # types LOCALHOST in the address bar is naming an allowed host. Folding case
    # on an allowlist can only ever refuse the same set or fewer.
    header = header.strip().lower()
    if header.startswith("["):
        host, closed, rest = header[1:].partition("]")
        if not closed or ":" not in host:
            return ""          # brackets are for IPv6 literals, nothing else
        if rest and not re.fullmatch(r":[0-9]+", rest):
            return ""          # junk after the bracket, or a "port" that is not one
        return host
    host, sep, port = header.partition(":")
    if sep and not re.fullmatch(r"[0-9]+", port):
        return ""
    return host


class MonitorHandler(BaseHTTPRequestHandler):
    server_version = "bridger-monitor"

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        if not self._host_allowed():
            self.send_error(421, "unexpected Host header")
            return
        path = posixpath.normpath(self.path.split("?", 1)[0])
        if path == "/":
            self._send_page()
        elif path == "/api/state":
            self._send_state()
        elif path == "/logo.png":
            self._send_logo()
        else:
            self.send_error(404, "not found")

    def _host_allowed(self):
        return _host_of(self.headers.get("Host", "")) in ALLOWED_HOSTS

    def _send_logo(self):
        """The plugin's mark, at a fixed path. Not a static directory: this is
        one hard-coded file, so there is nothing for a traversal to walk."""
        try:
            with open(LOGO_PATH, "rb") as handle:
                body = handle.read()
        except OSError:
            # An install without assets/ still renders; the markup drops the img.
            self.send_error(404, "no logo")
            return
        self._respond(body, "image/png")

    def _send_page(self):
        try:
            with open(os.path.join(HERE, "index.html"), "rb") as handle:
                body = handle.read()
        except OSError as err:
            self.send_error(500, "cannot read index.html: %s" % err)
            return
        self._respond(body, "text/html; charset=utf-8")

    def _send_state(self):
        try:
            body = json.dumps(snapshot(self.server.bridger_root)).encode()
        except Exception as err:  # noqa: BLE001 - the request boundary
            # One unreadable state file must cost this request, not the worker
            # thread: the page polls every two seconds and would otherwise see
            # the whole monitor go dark until the file is removed by hand.
            self.send_error(500, "cannot read %s: %s" % (self.server.bridger_root, err))
            return
        self._respond(body, "application/json")

    def _respond(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        """Silence the per-request line; the page polls every two seconds."""


def serve(root, port, open_browser):
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), MonitorHandler)
    except OSError as err:
        raise SystemExit("cannot bind 127.0.0.1:%d (%s) — try --port N" % (port, err))
    httpd.bridger_root = root
    url = "http://127.0.0.1:%d" % port
    print("bridger monitor  %s  (read-only, ctrl-c to stop)" % url)
    print("watching %s" % root)
    if not os.path.isdir(root):
        print("warning: %s does not exist yet — no peers have registered" % root)
    if open_browser:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        httpd.server_close()


def selftest():
    """Build a synthetic root and check the derived state the UI depends on."""
    root = tempfile.mkdtemp(prefix="bridger-monitor-test.")
    now = parse_ts("2026-07-26T12:00:00Z")
    peers_dir = os.path.join(root, "peers")
    thread_dir = os.path.join(root, "threads", "alpha--beta")
    os.makedirs(peers_dir)
    os.makedirs(thread_dir)

    # delta is a session that closed cleanly with nothing waiting for it: no
    # beat, no pending messages. It must not read as a fault.
    #
    # Every cwd here is a real directory: a peer whose directory is absent reads
    # "missing", so pointing these at paths that happen not to exist would make
    # the whole fixture unreachable and the status checks below vacuous.
    worktrees = os.path.join(root, "wt")
    for name, last_seen in (("alpha", "2026-07-26T11:59:00Z"),
                            ("beta", "2026-07-26T11:58:00Z"),
                            ("delta", "2026-07-26T11:57:00Z"),
                            ("ab-", "2026-07-26T11:56:00Z"),
                            ("abc", "2026-07-26T11:56:00Z")):
        cwd = os.path.join(worktrees, name)
        os.makedirs(cwd)
        with open(os.path.join(peers_dir, name + ".json"), "w") as handle:
            json.dump({"name": name, "cwd": cwd, "branch": "main",
                       "summary": "", "session": name + "-sess",
                       "created": last_seen, "last_seen": last_seen}, handle)
    # A deleted worktree: the record outlives its directory. `register` refuses a
    # missing directory and identity resolves only from a real cwd, so this name
    # can never be worn again — it must not read as a merely closed session.
    with open(os.path.join(peers_dir, "vanished.json"), "w") as handle:
        json.dump({"name": "vanished", "cwd": os.path.join(worktrees, "vanished"),
                   "branch": "main", "summary": "", "session": "vanished-sess",
                   "created": "2026-07-26T10:00:00Z",
                   "last_seen": "2026-07-26T10:00:00Z"}, handle)
    # alpha's watcher is running; beta never armed one. The beat mtime is set
    # explicitly so the check does not depend on the wall clock.
    beat = os.path.join(peers_dir, "alpha.beat")
    open(beat, "w").close()
    os.utime(beat, (now - 1, now - 1))

    messages = [
        {"seq": 1, "from": "alpha", "to": "beta", "type": "chat",
         "body": "hi", "ts": "2026-07-26T11:00:00Z"},
        {"seq": 2, "from": "beta", "to": "alpha", "type": "ask",
         "body": "which branch?", "ts": "2026-07-26T11:10:00Z"},
        {"seq": 3, "from": "alpha", "to": "beta", "type": "answer",
         "body": "main", "ts": "2026-07-26T11:12:00Z", "ref": 2},
        {"seq": 4, "from": "alpha", "to": "beta", "type": "chat",
         "body": "still there?", "ts": "2026-07-26T11:30:00Z"},
    ]
    for message in messages:
        with open(os.path.join(thread_dir, "%05d.json" % message["seq"]), "w") as handle:
            json.dump(message, handle)
    with open(os.path.join(thread_dir, "cursor-alpha"), "w") as handle:
        handle.write("4\n")
    with open(os.path.join(thread_dir, "cursor-beta"), "w") as handle:
        handle.write("1\n")
    # A temp file mid-send must not be mistaken for a message.
    open(os.path.join(thread_dir, ".msg.ABC123"), "w").close()
    # The filename carries the seq, so a record whose body disagrees (or omits
    # it entirely) is still placed correctly rather than poisoning the sort.
    with open(os.path.join(thread_dir, "00005.json"), "w") as handle:
        json.dump({"seq": None, "from": "beta", "to": "alpha", "type": "chat",
                   "body": None, "ref": None, "ts": "2026-07-26T11:35:00Z"}, handle)
    # A digit-leading name that is not a plain number is not a message.
    with open(os.path.join(thread_dir, "00006x.json"), "w") as handle:
        handle.write("{}")
    # The filename is authoritative even when the body states a DIFFERENT seq —
    # a body-first reader would place this at 2 and compare the wrong cursor.
    with open(os.path.join(thread_dir, "00004.json")) as handle:
        four = json.load(handle)
    four["seq"] = 2
    with open(os.path.join(thread_dir, "00004.json"), "w") as handle:
        json.dump(four, handle)

    # A name may end in a single dash, so this pair directory carries three
    # dashes at the boundary and a first-occurrence split reads it wrong.
    dashed = os.path.join(root, "threads", "ab---abc")
    os.makedirs(dashed)
    with open(os.path.join(dashed, "00001.json"), "w") as handle:
        json.dump({"seq": 1, "from": "abc", "to": "ab-", "type": "chat",
                   "body": "hi", "ts": "2026-07-26T11:50:00Z"}, handle)
    with open(os.path.join(dashed, "cursor-ab-"), "w") as handle:
        handle.write("1\n")

    state = snapshot(root, now=now)
    by_name = {peer["name"]: peer for peer in state["peers"]}
    assert by_name["alpha"]["status"] == "listening", by_name["alpha"]
    assert by_name["beta"]["status"] == "queued", by_name["beta"]
    assert by_name["delta"]["status"] == "queued", by_name["delta"]
    assert by_name["vanished"]["status"] == "missing", by_name["vanished"]
    # Deleting a worktree does not kill the session inside it, and that watcher
    # keeps delivering. A stale beat naming a live pid is still a live reader, so
    # the absent directory must NOT win: this is "queued", never "missing".
    orphan_beat = os.path.join(peers_dir, "orphan.beat")
    with open(os.path.join(peers_dir, "orphan.json"), "w") as handle:
        json.dump({"name": "orphan", "cwd": os.path.join(worktrees, "orphan"),
                   "branch": "main", "summary": "", "session": "orphan-sess",
                   "created": "2026-07-26T10:00:00Z",
                   "last_seen": "2026-07-26T10:00:00Z"}, handle)
    with open(orphan_beat, "w") as handle:
        handle.write(str(os.getpid()))
    os.utime(orphan_beat, (now - BEAT_STALE_SECS - 60, now - BEAT_STALE_SECS - 60))
    orphan = {p["name"]: p for p in snapshot(root, now=now)["peers"]}["orphan"]
    assert orphan["status"] == "queued", orphan
    os.remove(os.path.join(peers_dir, "orphan.json"))
    os.remove(orphan_beat)

    # A hand-written record can carry a non-string cwd. os.path.* raises
    # TypeError on it, which escapes the unreadable-peer handler and 500s the
    # whole endpoint — one bad record hiding every peer, thread and metric.
    # "queued", not "missing": no path here is no proof a directory is gone, and
    # that is what bin/bridger's peer_cwd answers for the same record.
    with open(os.path.join(peers_dir, "weird.json"), "w") as handle:
        json.dump({"name": "weird", "cwd": ["/tmp"], "session": ""}, handle)
    weird = {p["name"]: p for p in snapshot(root, now=now)["peers"]}["weird"]
    assert weird["status"] == "queued", weird
    os.remove(os.path.join(peers_dir, "weird.json"))

    # The name comes from the FILENAME. A list .name would reach compute_metrics'
    # set of listening names, where it is unhashable — endpoint-wide 500.
    with open(os.path.join(peers_dir, "listy.json"), "w") as handle:
        json.dump({"name": ["a", "b"], "cwd": worktrees, "session": ""}, handle)
    listy = {p["name"]: p for p in snapshot(root, now=now)["peers"]}["listy"]
    assert listy["name"] == "listy", listy
    os.remove(os.path.join(peers_dir, "listy.json"))

    # Pid forms int() accepts and bash's `case $pid in *[!0-9]*)` rejects. The
    # two implementations must classify them identically or the monitor points
    # at `reap` for a peer the CLI refuses to list.
    for junk in ("+424", "-424", "4_242", "424\r"):
        with open(os.path.join(peers_dir, "pidjunk.beat"), "w") as handle:
            handle.write(junk + "\n")
        beat = os.path.join(peers_dir, "pidjunk.beat")
        assert watcher_alive(beat) is True, junk
        assert beat_pid_alive(beat) is False, junk
    os.remove(os.path.join(peers_dir, "pidjunk.beat"))

    # An untraversable parent is not proof of absence — see dir_gone. The
    # symlink and relative cases are where this drifted from bash's `[ -e ]`.
    locked = os.path.join(root, "locked")
    os.makedirs(os.path.join(locked, "inner"), exist_ok=True)
    assert dir_gone(os.path.join(locked, "nope")) is True
    dangling = os.path.join(root, "dangling")
    if not os.path.lexists(dangling):
        os.symlink(os.path.join(root, "no-such-target"), dangling)
    assert dir_gone(dangling) is True, "a dangling symlink follows through to absent, as `[ -e ]` does"
    assert dir_gone("") is False and dir_gone("/") is False
    os.chmod(locked, 0o000)
    try:
        assert dir_gone(os.path.join(locked, "inner")) is False
        assert dir_gone(os.path.join(locked, "nope")) is False
    finally:
        os.chmod(locked, 0o755)

    thread = next(t for t in state["threads"] if t["id"] == "alpha--beta")
    assert len(thread["messages"]) == 5, thread["messages"]
    assert [m["seq"] for m in thread["messages"]] == [1, 2, 3, 4, 5], thread["messages"]
    assert any("not a numbered message" in w for w in state["warnings"]), state["warnings"]
    # Null fields are filled in at the boundary so no later consumer has to,
    # and a null ref never reaches the page as a link to nowhere.
    stray = next(m for m in thread["messages"] if m["seq"] == 5)
    assert stray["body"] == "" and "ref" not in stray, stray
    # beta consumed through seq 1, so seq 3 and 4 (addressed to beta) wait; and
    # alpha's cursor stops at 4, so the stray seq 5 waits for alpha.
    assert thread["undelivered"] == {"alpha": 1, "beta": 2}, thread["undelivered"]
    assert thread["queued"] == 3
    assert [m["delivered"] for m in thread["messages"]] == [True, True, False, False, False]

    dashed_thread = next(t for t in state["threads"] if t["id"] == "ab---abc")
    assert (dashed_thread["a"], dashed_thread["b"]) == ("ab-", "abc"), dashed_thread
    # cursor-ab- is at 1, so its one message must read as delivered, not queued.
    assert dashed_thread["messages"][0]["delivered"] is True, dashed_thread
    assert dashed_thread["queued"] == 0, dashed_thread

    metrics = state["metrics"]
    assert metrics["listening"] == 1 and metrics["peers"] == 6, metrics
    assert metrics["queued"] == 3, metrics
    # beta has no watcher AND messages waiting. alpha also has one waiting but
    # is listening; delta has no watcher and nothing waiting. Only beta is deaf.
    assert metrics["deaf"] == ["beta"], metrics
    # The 11:00 message sits exactly an hour back, outside the window.
    assert metrics["last_hour"] == 5 and metrics["last_day"] == 6, metrics
    trips = metrics["round_trips"]
    assert trips == {"asks": 1, "answered": 1, "median_latency": 120.0, "stale": []}, trips

    # A cursor the CLI cannot parse means "nothing consumed" on BOTH sides. int()
    # accepted every one of these — a `\r` from a bus synced through a
    # Windows-aware tool, whitespace, a sign, a `_` separator, a Unicode digit —
    # while bash's `case $cur in *[!0-9]*)` resets to 0, and each disagreement
    # made the monitor report mail as delivered that poll is about to hand over.
    beta_cursor = os.path.join(thread_dir, "cursor-beta")
    for junk in ("1\r", " 1 ", "+1", "1_0", "١"):
        with open(beta_cursor, "w", newline="") as handle:
            handle.write(junk)
        unparsed = next(t for t in snapshot(root, now=now)["threads"] if t["id"] == "alpha--beta")
        assert unparsed["undelivered"]["beta"] == 3, (junk, unparsed["undelivered"])
    with open(beta_cursor, "w") as handle:
        handle.write("1\n")

    # Both a half-written peer file and one that is valid JSON of the wrong
    # shape degrade to a warning. The second is what a hand edit produces, and
    # it used to reach `.get()` on a list and take the whole request down.
    for broken in ("{half-writ", "[]", "null"):
        with open(os.path.join(peers_dir, "gamma.json"), "w") as handle:
            handle.write(broken)
        degraded = snapshot(root, now=now)
        assert len(degraded["peers"]) == 6, (broken, degraded["peers"])
        assert any("gamma" in warn for warn in degraded["warnings"]), (broken, degraded["warnings"])

    # `bridger leave` removes peers/<name>.json but keeps the thread. Messages
    # stranded for a departed name still have nobody listening for them.
    os.remove(os.path.join(peers_dir, "beta.json"))
    departed = snapshot(root, now=now)
    assert "beta" not in {peer["name"] for peer in departed["peers"]}, departed["peers"]
    assert departed["metrics"]["deaf"] == ["beta"], departed["metrics"]

    # The root is spliced into a glob pattern, so a metacharacter in the path
    # would otherwise match nothing (or a neighbouring directory) in silence.
    tricky = os.path.join(root, "br[1]")
    os.makedirs(os.path.join(tricky, "peers"))
    with open(os.path.join(tricky, "peers", "solo.json"), "w") as handle:
        json.dump({"name": "solo", "cwd": tricky}, handle)
    assert [p["name"] for p in snapshot(tricky, now=now)["peers"]] == ["solo"]

    # peer_status needs a live pid as well as a fresh beat, or a killed watcher
    # reads as "listening" for another 15 seconds. The empty beat above covers
    # the pre-0.12 watcher that left only an mtime.
    solo_beat = os.path.join(tricky, "peers", "solo.beat")
    dead_pid = 99999
    while True:
        try:
            os.kill(dead_pid, 0)
        except ProcessLookupError:
            break
        except OSError:
            pass          # EPERM: alive, just not ours
        dead_pid -= 1
    for pid, expected in ((dead_pid, "queued"), (os.getpid(), "listening"), ("", "listening")):
        with open(solo_beat, "w") as handle:
            handle.write(str(pid))
        os.utime(solo_beat, (now - 1, now - 1))
        status = snapshot(tricky, now=now)["peers"][0]["status"]
        assert status == expected, (pid, status)

    # Only a Host the user could have typed is served, so a domain that resolves
    # to 127.0.0.1 cannot read the bus from a page the user is merely visiting.
    #
    # Asserted through the DECISION, and then through a real request. The version
    # of this block that compared _host_of's return value stayed green with the
    # guard deleted from do_GET outright — the one mutation that matters here,
    # since /api/state carries every message body on the bus.
    def host_allowed(host):
        handler = MonitorHandler.__new__(MonitorHandler)
        handler.headers = {} if host is None else {"Host": host}
        return handler._host_allowed()

    for host in ("127.0.0.1:8787", "127.0.0.1", "localhost", "LOCALHOST:8787",
                 "LocalHost", "[::1]:8787", "[::1]", " localhost "):
        assert host_allowed(host) is True, host
    # Everything else a browser or an attacker can put there must be refused.
    # This is the server's only access control and /api/state carries every
    # message body, so the allowlist has to stay an allowlist. The bracketed and
    # bogus-port forms are not browser-producible — they fail URL parsing before a
    # request is made — but this decision must not depend on the client being a
    # browser.
    for denied in ("", None, "localhost.", "127.0.0.1.", "0.0.0.0", "127.1",
                   "attacker.example", "::ffff:127.0.0.1", "127.0.0.1.evil.example",
                   "localhost@evil.example", "127.0.0.2:8787",
                   "[localhost]", "[127.0.0.1]", "[evil.example]", "[::1]evil.example",
                   "[localhost]:evil", "[::1", "127.0.0.1:evil.example"):
        assert host_allowed(denied) is False, denied

    # And the guard has to RUN, ahead of routing. Nothing above proves that: the
    # deletion that matters is the two lines in do_GET, and only a real request
    # over a socket can see them missing. Served out of a sandbox root, never the
    # user's own bus.
    import http.client
    import threading

    guarded = ThreadingHTTPServer(("127.0.0.1", 0), MonitorHandler)
    guarded.bridger_root = root
    threading.Thread(target=guarded.serve_forever, daemon=True).start()
    try:
        port = guarded.server_address[1]
        for host, expected in (("127.0.0.1:%d" % port, 200), ("evil.example", 421),
                               ("127.0.0.1.evil.example", 421), ("[localhost]", 421)):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.putrequest("GET", "/api/state", skip_host=True, skip_accept_encoding=True)
            conn.putheader("Host", host)
            conn.endheaders()
            status = conn.getresponse().status
            conn.close()
            assert status == expected, (host, status, expected)
    finally:
        guarded.shutdown()
        guarded.server_close()

    # A message field that is not a string must be coerced HERE. A list `to`
    # reached cursors.get() as an unhashable key and raised TypeError — neither
    # OSError nor ValueError, so it escaped every per-file handler and 500'd the
    # whole snapshot; a list `body` reached the browser and pinned the page on
    # "reconnecting" while it kept displaying the last good state.
    hostile = tempfile.mkdtemp(prefix="bridger-monitor-hostile.")
    os.makedirs(os.path.join(hostile, "peers"))
    hostile_thread = os.path.join(hostile, "threads", "alpha--beta")
    os.makedirs(hostile_thread)
    with open(os.path.join(hostile_thread, "00007.json"), "w") as handle:
        json.dump({"to": ["beta"], "from": {"a": 1}, "type": 3, "body": ["x"],
                   "ts": "2026-07-26T11:40:00Z"}, handle)
    bad = snapshot(hostile, now=now)["threads"][0]["messages"][0]
    assert bad == {"seq": 7, "from": "", "to": "", "type": "", "body": "",
                   "ts": "2026-07-26T11:40:00Z", "delivered": False}, bad

    # NaN/Infinity are accepted by json.load and re-emitted by json.dumps, so the
    # server answered 200 with a body no browser can parse — and jq maps the same
    # value to null, so the CLI read the file fine while the page died silently.
    with open(os.path.join(hostile, "peers", "nanny.json"), "w") as handle:
        handle.write('{"cwd": "/tmp", "drift": NaN}')
    # RecursionError is a RuntimeError, so deeply nested JSON slipped past the
    # per-file handlers and 500'd the request the same way.
    with open(os.path.join(hostile, "peers", "deep.json"), "w") as handle:
        handle.write("[" * 100000 + "]" * 100000)
    degraded = snapshot(hostile, now=now)
    json.dumps(degraded, allow_nan=False)
    for name in ("nanny", "deep"):
        assert any(name in warning for warning in degraded["warnings"]), degraded["warnings"]

    # A filename is a filename on both sides of the bus. `str.isdigit()` and
    # `int()` disagree at both ends of the Unicode digit category, and each gap
    # was its own bug: a superscript stem passed the guard and then raised out of
    # every handler (500 for the whole snapshot), while an Arabic-Indic stem
    # passed both and became a message bin/bridger's `[0-9]` filter cannot see —
    # rendered as real, counted as queued mail no cursor can ever reach, silently.
    for stem, seq in (("0³", None), ("3٤", 34)):
        with open(os.path.join(hostile_thread, stem + ".json"), "w") as handle:
            json.dump({"to": "beta", "from": "alpha", "type": "chat", "body": "x",
                       "ts": "2026-07-26T11:40:00Z"}, handle)
        state = snapshot(hostile, now=now)          # must not raise
        assert any(stem in warning for warning in state["warnings"]), state["warnings"]
        seqs = [message["seq"] for message in state["threads"][0]["messages"]]
        assert seq not in seqs, (stem, seqs)

    # The flow tile counts MESSAGES. Counting only the ones with a parseable `ts`
    # made it read 0, and turn amber, on a bus whose thread header — counting the
    # same list one function away — read 3.
    with open(os.path.join(hostile_thread, "00008.json"), "w") as handle:
        json.dump({"to": "beta", "from": "alpha", "type": "chat", "body": "y",
                   "ts": 1785000000}, handle)      # a number: parse_ts gives None
    counted = snapshot(hostile, now=now)["metrics"]
    assert counted["messages"] == 2, counted
    assert counted["last_day"] < counted["messages"], counted

    # check_wiring and _plugin_field read files OUTSIDE the bus, on every request,
    # and kept the narrower handler when the other two were widened. The 500 they
    # produced also blamed $BRIDGER_ROOT, which is not the file at fault.
    config = os.path.join(hostile, "cfg")
    os.makedirs(config)
    with open(os.path.join(config, "settings.json"), "w") as handle:
        handle.write("[" * 100000 + "]" * 100000)
    previous = os.environ.get("CLAUDE_CONFIG_DIR")
    os.environ["CLAUDE_CONFIG_DIR"] = config
    try:
        assert snapshot(hostile, now=now)["wiring"]["plugin_enabled"] is None
    finally:
        if previous is None:
            del os.environ["CLAUDE_CONFIG_DIR"]
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = previous
    shutil.rmtree(hostile)

    shutil.rmtree(root)
    print("PASS: bridger monitor self-check green")


def main(argv=None):
    parser = argparse.ArgumentParser(description="read-only web view of the bridger message bus")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--root", default=None, help="BRIDGER_ROOT to watch")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser")
    parser.add_argument("--selftest", action="store_true", help="run self-checks and exit")
    args = parser.parse_args(argv)
    if args.selftest:
        selftest()
        return 0
    serve(args.root or default_root(), args.port, not args.no_open)
    return 0


if __name__ == "__main__":
    sys.exit(main())
