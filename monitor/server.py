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
    """Where bridger keeps its state. Mirrors bin/bridger:33."""
    return os.environ.get("BRIDGER_ROOT") or os.path.expanduser("~/.claude/bridger")


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


def watcher_alive(beat_path):
    """Mirrors watcher_alive (bin/bridger): the beat holds the watcher's pid, so
    a death shows immediately instead of at the end of the staleness window.

    An empty or non-numeric beat is a pre-0.12 watcher that only left an mtime —
    the CLI treats that as alive, and disagreeing here would report "queued" for
    a session `bridger peers` calls listening.
    """
    try:
        with open(beat_path) as handle:
            pid = handle.readline().strip()
    except OSError:
        return False
    if not pid.isdigit():
        return True
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except OSError:
        # EPERM: the process exists, it just is not ours to signal.
        return True
    return True


def read_int(path):
    """A cursor file holds one integer. Absent or unreadable means 0 consumed."""
    try:
        with open(path) as handle:
            return int(handle.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def _load_object(path):
    """Read JSON that must be an object.

    A hand-edited file can be valid JSON of the wrong shape (`[]`, `null`, `5`),
    which json.load accepts and the next `.get()` turns into an AttributeError
    escaping as a 500. Raise ValueError instead, so the callers' existing
    "unreadable file" path handles it.
    """
    with open(path) as handle:
        record = json.load(handle)
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
        except (OSError, ValueError) as err:
            # write_peer redirects with `>` rather than tmp+mv (bin/bridger:313),
            # so a read can land mid-write. Report it and keep serving the rest.
            warnings.append("peer %s unreadable: %s" % (name, err))
            continue
        beat = os.path.join(root, "peers", name + ".beat")
        age = file_age(beat, now)
        record["name"] = record.get("name") or name
        record["beat_age"] = age
        # Both halves of peer_status (bin/bridger): a fresh beat AND a live pid.
        # mtime alone would call a killed watcher "listening" for 15s more.
        record["status"] = ("listening"
                            if age is not None and age < BEAT_STALE_SECS and watcher_alive(beat)
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
        if not stem.isdigit():
            warnings.append("message %s/%s is not a numbered message — skipped" % (pair, name))
            continue
        try:
            with open(path) as handle:
                record = json.load(handle)
        except (OSError, ValueError) as err:
            warnings.append("message %s/%s unreadable: %s" % (pair, name, err))
            continue
        messages.append(_normalize(record, int(stem)))
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
    message = {
        "seq": seq,
        "from": record.get("from") or "",
        "to": record.get("to") or "",
        "type": record.get("type") or "",
        "body": record.get("body") or "",
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
        "messages": len(stamps),
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
    except (OSError, ValueError):
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
    except (OSError, ValueError):
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
    as `[::1]:8787`, where splitting on the first colon would give `[`."""
    if header.startswith("["):
        return header[1:].split("]")[0]
    return header.split(":")[0]


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
    for name, last_seen in (("alpha", "2026-07-26T11:59:00Z"),
                            ("beta", "2026-07-26T11:58:00Z"),
                            ("delta", "2026-07-26T11:57:00Z"),
                            ("ab-", "2026-07-26T11:56:00Z"),
                            ("abc", "2026-07-26T11:56:00Z")):
        with open(os.path.join(peers_dir, name + ".json"), "w") as handle:
            json.dump({"name": name, "cwd": "/tmp/" + name, "branch": "main",
                       "summary": "", "session": name + "-sess",
                       "created": last_seen, "last_seen": last_seen}, handle)
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
    assert metrics["listening"] == 1 and metrics["peers"] == 5, metrics
    assert metrics["queued"] == 3, metrics
    # beta has no watcher AND messages waiting. alpha also has one waiting but
    # is listening; delta has no watcher and nothing waiting. Only beta is deaf.
    assert metrics["deaf"] == ["beta"], metrics
    # The 11:00 message sits exactly an hour back, outside the window.
    assert metrics["last_hour"] == 5 and metrics["last_day"] == 6, metrics
    trips = metrics["round_trips"]
    assert trips == {"asks": 1, "answered": 1, "median_latency": 120.0, "stale": []}, trips

    # Both a half-written peer file and one that is valid JSON of the wrong
    # shape degrade to a warning. The second is what a hand edit produces, and
    # it used to reach `.get()` on a list and take the whole request down.
    for broken in ("{half-writ", "[]", "null"):
        with open(os.path.join(peers_dir, "gamma.json"), "w") as handle:
            handle.write(broken)
        degraded = snapshot(root, now=now)
        assert len(degraded["peers"]) == 5, (broken, degraded["peers"])
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
        json.dump({"name": "solo"}, handle)
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
    assert _host_of("127.0.0.1:8787") == "127.0.0.1"
    assert _host_of("localhost") == "localhost"
    assert _host_of("[::1]:8787") == "::1"
    assert _host_of("bridger.evil.example:8787") not in ALLOWED_HOSTS

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
