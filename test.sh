#!/usr/bin/env bash
# Self-check for the bridger CLI. Runs against a throwaway BRIDGER_ROOT and
# throwaway working directories — never touches ~/.claude.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bridger="$here/bin/bridger"

BRIDGER_ROOT=$(mktemp -d)
work=$(mktemp -d)
export BRIDGER_ROOT
trap 'rm -rf "$BRIDGER_ROOT" "$work"' EXIT

# Determinism: identity resolution is session-aware, so the suite must not
# inherit a real CLAUDE_CODE_SESSION_ID from the shell that runs it (that would
# make id-less cases behave differently inside vs. outside a Claude Code
# session). Tests that exercise session semantics set the id explicitly, per
# call. The default here is id-less — the plain-CLI path.
unset CLAUDE_CODE_SESSION_ID BRIDGER_SESSION_ID 2>/dev/null || true

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# Block until <name> actually reads [listening], or give up after ~15s.
#
# `wait --follow` is a separate process that has to start bash, resolve its
# identity and write its first heartbeat before any of that is observable. A
# fixed `sleep 3` races that startup, so every assertion built on it becomes a
# coin flip on a loaded machine — CI, or a release (scripts/release.sh gates the
# tag on this suite), or simply several copies of this suite running at once. A
# gate that flakes is worse than no gate: it either blocks a good release or
# teaches everyone to re-run until green. Poll the real precondition instead.
await_listening() { # name
  local name="$1" i
  for i in $(seq 1 150); do
    grep -q "^$name \[listening\]" <<<"$("$bridger" peers 2>/dev/null)" && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$work/liba/sub" "$work/app"

# --- register + whoami ------------------------------------------------------
"$bridger" register liba "$work/liba" >/dev/null
"$bridger" register app "$work/app" >/dev/null

[ "$(cd "$work/liba" && "$bridger" whoami)" = "liba" ] || fail "whoami exact cwd"
[ "$(cd "$work/liba/sub" && "$bridger" whoami)" = "liba" ] || fail "whoami subdirectory"
[ "$(cd "$work/app" && "$bridger" whoami)" = "app" ] || fail "whoami second peer"
if (cd /tmp && "$bridger" whoami >/dev/null 2>&1); then fail "whoami matches unregistered dir"; fi
if "$bridger" register "bad--name" "$work" >/dev/null 2>&1; then fail "register accepts '--' in name"; fi

# A name is interpolated straight into peer_file()/beat_file() paths, so the
# charset check is the only thing keeping records inside BRIDGER_ROOT. It used
# to be a `grep -Eq`, and grep is LINE-oriented: -q succeeds when ANY line
# matches, so a name carrying an embedded newline passed on one of its lines and
# the rest of it became path. `register $'../../../x\ny'` then wrote a peer
# record into any directory the user can write to.
esc="$work/escape"; mkdir -p "$esc"
for evil in "../../../../../../../../../../../..$esc/pwned
x" "x
../../../../../../../../../../../..$esc/pwned"; do
  if "$bridger" register "$evil" "$work/app" >/dev/null 2>&1; then
    fail "register accepted a name containing a newline"
  fi
done
[ -z "$(ls -A "$esc")" ] || fail "a crafted name wrote outside BRIDGER_ROOT: $(ls -A "$esc")"
if "$bridger" register "up/down" "$work/app" >/dev/null 2>&1; then fail "register accepts '/' in a name"; fi
pass "register + whoami"

# --- send + poll ------------------------------------------------------------
seq1=$(cd "$work/app" && "$bridger" send liba chat "hello lib")
[ "$seq1" = "1" ] || fail "first seq is 1 (got $seq1)"

out=$(cd "$work/liba" && "$bridger" poll)
[ "$out" = "#1 app chat: hello lib" ] || fail "poll terse line format (got: $out)"
[ -z "$(cd "$work/liba" && "$bridger" poll)" ] || fail "second poll not empty"
seqj=$(cd "$work/app" && "$bridger" send liba chat "json check")
outj=$(cd "$work/liba" && "$bridger" poll --json)
[ "$(jq -r .body <<<"$outj")" = "json check" ] || fail "poll --json delivers full object"
[ "$(jq -r .seq <<<"$outj")" = "$seqj" ] || fail "poll --json seq"

(cd "$work/app" && "$bridger" send liba chat "peek me" >/dev/null)
peek1=$(cd "$work/liba" && "$bridger" poll --peek)
peek2=$(cd "$work/liba" && "$bridger" poll --peek)
[ -n "$peek1" ] && [ "$peek1" = "$peek2" ] || fail "peek must not advance cursor"
[ -n "$(cd "$work/liba" && "$bridger" poll)" ] || fail "poll after peek still delivers"
pass "send + poll + peek cursor semantics"

# --- ask/answer roundtrip ---------------------------------------------------
(
  cd "$work/liba"
  for _ in $(seq 1 30); do
    # Capture first: piping straight into head could SIGPIPE the producer
    # under pipefail and silently kill this responder via set -e.
    msg=$("$bridger" poll --json)
    msg=$(head -n 1 <<<"$msg")
    if [ -n "$msg" ]; then
      s=$(jq -r .seq <<<"$msg")
      "$bridger" send app answer "42" --ref "$s" >/dev/null
      exit 0
    fi
    sleep 1
  done
  exit 1
) &
responder=$!

reply=$(cd "$work/app" && "$bridger" ask liba "meaning of life?" --timeout 40 --json)
wait "$responder" || fail "responder never saw the ask"
[ "$(jq -r .body <<<"$reply")" = "42" ] || fail "ask returns reply body"
[ "$(jq -r .type <<<"$reply")" = "answer" ] || fail "reply type"
pass "ask/answer roundtrip with ref matching"

# --- timeouts ---------------------------------------------------------------
if (cd "$work/app" && "$bridger" ask liba "void" --timeout 3 >/dev/null 2>&1); then
  fail "ask without responder must time out with nonzero exit"
fi
(cd "$work/liba" && "$bridger" poll >/dev/null)  # drain the stray asks
if (cd "$work/app" && "$bridger" wait --timeout 3 >/dev/null 2>&1); then
  fail "wait with no traffic must time out with nonzero exit"
fi
(cd "$work/liba" && "$bridger" send app chat "wake up" >/dev/null)
(cd "$work/app" && "$bridger" wait --timeout 10 >/dev/null) || fail "wait must return 0 when unread exists"
pass "ask/wait timeout paths"

# --- ask rejects a non-numeric timeout, from the flag or the env override ----
if (cd "$work/app" && "$bridger" ask liba "x" --timeout abc >/dev/null 2>&1); then
  fail "ask must reject a non-numeric --timeout"
fi
if (cd "$work/app" && BRIDGER_ASK_TIMEOUT=oops "$bridger" ask liba "x" >/dev/null 2>&1); then
  fail "ask must reject a non-numeric \$BRIDGER_ASK_TIMEOUT"
fi
pass "ask validates the timeout value (flag and env)"

# --- concurrent sends land with distinct seqs -------------------------------
before=$(ls "$BRIDGER_ROOT"/threads/app--liba/ | grep -c '\.json$')
(cd "$work/app" && "$bridger" send liba chat "race one" >/dev/null) &
(cd "$work/app" && "$bridger" send liba chat "race two" >/dev/null) &
wait
after=$(ls "$BRIDGER_ROOT"/threads/app--liba/ | grep -c '\.json$')
[ "$after" = "$((before + 2))" ] || fail "concurrent sends lost a message ($before -> $after)"
pass "concurrent sends, distinct seqs"

# --- opt-in by default --------------------------------------------------------
disc=$(mktemp -d)
mkdir -p "$disc/My_Service" "$disc/other/My_Service" "$disc/plain"

# Without the auto switch, an unregistered directory must stay unaddressable.
if (cd "$disc/plain" && "$bridger" autoregister >/dev/null 2>&1); then
  fail "autoregister must be off by default"
fi
# join is the explicit opt-in and needs no switch.
(cd "$disc/plain" && "$bridger" join >/dev/null)
[ "$(cd "$disc/plain" && "$bridger" whoami)" = "plain" ] || fail "join must register the directory"
pass "opt-in by default: autoregister refuses, join works"

# --- discovery under CLAUDE_BRIDGER_AUTO=1: names, scopes, status --------------
export CLAUDE_BRIDGER_AUTO=1

n1=$(cd "$disc/My_Service" && "$bridger" autoregister)
case "$n1" in my-service-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "auto name must be base + generated tag (got $n1)" ;; esac
[ "$(cd "$disc/My_Service" && "$bridger" autoregister)" = "$n1" ] || fail "autoregister must be idempotent (tag minted once per directory)"
n2=$(cd "$disc/other/My_Service" && "$bridger" autoregister)
[ "$n2" != "$n1" ] || fail "distinct directories must get distinct names"
case "$n2" in my-service-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "second auto name malformed (got $n2)" ;; esac
[ "$(cd "$disc/My_Service" && "$bridger" whoami)" = "$n1" ] || fail "autoregistered peer keeps its identity"
pass "autoregister mints durable tagged names, once per directory"

(cd "$disc/plain" && "$bridger" summary "building the parser") >/dev/null
listed=$(cd "$disc/plain" && "$bridger" peers)
grep -q "building the parser" <<<"$listed" || fail "peers shows summaries"
grep -q "plain \[queued\] (you)" <<<"$listed" || fail "peers marks self and queued status"
grep -q "my-service-" <<<"$listed" || fail "peers lists other peers on the machine"
# A reader holding only this output must not read "queued" as "unreachable".
grep -q "Reachability is proven by 'ask'" <<<"$listed" || fail "a queued other peer must draw the addressability note"
# Self-only listing: nothing actionable to explain, so no note (and --dir stays one line).
[ "$(cd "$disc/plain" && "$bridger" peers --dir | grep -c .)" = "1" ] || fail "--dir scopes to this directory, with no note for a queued self"
(cd "$disc/plain" && "$bridger" summary "still building") >/dev/null
grep -q "still building" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "summary is updatable"
pass "peers listing, summaries, and --dir scope"

# A running watcher marks its peer "listening"; a stopped one drops back to
# "queued" — via its own trap, and via the offline command the end-of-session
# hook calls. exec so the PID is the watcher itself and the trap can fire.
(cd "$disc/plain"; exec "$bridger" wait --follow >/dev/null 2>&1) &
watcher=$!
await_listening plain || fail "watcher never came up for peer plain"
grep -q "plain \[listening\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "watcher must mark peer listening"
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
grep -q "plain \[queued\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "stopped watcher must fall back to queued"

# A watcher killed without a chance to clean up: the beat goes stale on its own.
: > "$BRIDGER_ROOT/peers/plain.beat"
touch -t 202001010000 "$BRIDGER_ROOT/peers/plain.beat"
grep -q "plain \[queued\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "stale heartbeat must read as queued"

# SIGKILL leaves a beat file that is still fresh for up to BEAT_STALE_SECS. The
# recorded pid is what makes that death visible now rather than 15s from now.
( : ) & gone=$!; wait "$gone" 2>/dev/null || true   # a pid that is certainly dead
echo "$gone" > "$BRIDGER_ROOT/peers/plain.beat"
grep -q "plain \[queued\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" \
  || fail "a fresh beat whose pid is dead must read as queued"
# An empty beat is a pre-0.12 watcher with no pid recorded: fall back to mtime.
: > "$BRIDGER_ROOT/peers/plain.beat"
grep -q "plain \[listening\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" \
  || fail "a pid-less beat must still read as listening while fresh"
(cd "$disc/plain" && "$bridger" offline)
[ ! -e "$BRIDGER_ROOT/peers/plain.beat" ] || fail "offline must clear the heartbeat"
pass "heartbeat: listening while watched, queued when stopped or stale"

# Re-registering must not erase the summary, and register records the session id.
# Explicit register claims the session-less name `join` created — under the
# per-session model a different session never adopts it implicitly.
(cd "$disc/plain" && CLAUDE_CODE_SESSION_ID=sess-abc123 "$bridger" register plain >/dev/null)
[ "$(jq -r .session "$BRIDGER_ROOT/peers/plain.json")" = "sess-abc123" ] || fail "register must record its session id"
grep -q "still building" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "register must preserve the summary"
# An id-less refresh (a plain-CLI autoregister, resolves by directory) must not
# wipe the recorded session.
(cd "$disc/plain" && "$bridger" autoregister >/dev/null)
[ "$(jq -r .session "$BRIDGER_ROOT/peers/plain.json")" = "sess-abc123" ] || fail "id-less refresh must preserve the session id"
pass "re-registration preserves peer metadata and records the session id"

# --- opting out --------------------------------------------------------------
mkdir -p "$disc/private"
(cd "$disc/private" && "$bridger" autoregister >/dev/null)
(cd "$disc/private" && "$bridger" leave >/dev/null)
if (cd "$disc/private" && "$bridger" whoami >/dev/null 2>&1); then fail "leave must remove the identity"; fi
if (cd "$disc/private" && "$bridger" autoregister >/dev/null 2>&1); then fail "a directory that left must not auto-register again"; fi
[ -z "$(cd "$disc/plain" && "$bridger" peers | grep private || true)" ] || fail "a peer that left must not be listed"
(cd "$disc/private" && "$bridger" join >/dev/null)
[ "$(cd "$disc/private" && "$bridger" whoami)" = "private" ] || fail "join must restore the identity"

pass "leave / join under auto mode"

# --- explicit names override derived ones (the coordinator/worker case) ------
# Two checkouts of one project, each its own session: each auto-registers from
# its directory name, then takes an explicit role name. The rename must be
# clean, not additive.
mkdir -p "$disc/proj" "$disc/proj-worktree"
derived=$(cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" autoregister)
(cd "$disc/proj-worktree" && CLAUDE_CODE_SESSION_ID=sess-worker "$bridger" autoregister >/dev/null)
(cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" register lead >/dev/null)
(cd "$disc/proj-worktree" && CLAUDE_CODE_SESSION_ID=sess-worker "$bridger" register worker >/dev/null)
[ "$(cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" whoami)" = "lead" ] || fail "explicit name must win over the derived one"
[ "$(cd "$disc/proj-worktree" && CLAUDE_CODE_SESSION_ID=sess-worker "$bridger" whoami)" = "worker" ] || fail "second checkout keeps its own identity"
[ ! -f "$BRIDGER_ROOT/peers/$derived.json" ] || fail "derived name must be replaced, not kept alongside"
[ "$(cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" peers --dir | grep -c .)" = "1" ] || fail "one identity per directory"
(cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" send worker chat "roles work" >/dev/null)
[ "$(cd "$disc/proj-worktree" && CLAUDE_CODE_SESSION_ID=sess-worker "$bridger" poll)" = "#1 lead chat: roles work" ] || fail "renamed peers can talk"

# Once a name has history, silently renaming it would orphan the thread.
if (cd "$disc/proj" && CLAUDE_CODE_SESSION_ID=sess-lead "$bridger" register lead-2 >/dev/null 2>&1); then
  fail "renaming a peer with history must be refused"
fi
pass "explicit role names override derived names; history-bearing names are protected"

# --- two sessions in ONE directory: distinct identities by session id ---------
# A directory alone can't tell two sessions apart; the Claude Code session id
# can. Same folder, two names, and they hold a conversation — the case a dev
# hits working two sessions on one branch (no worktree).
mkdir -p "$disc/together"
(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-arch "$bridger" register arch >/dev/null)
(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-exec "$bridger" register exec >/dev/null)
[ "$(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-arch "$bridger" whoami)" = "arch" ] \
  || fail "same-folder: session A must resolve to its own name"
[ "$(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-exec "$bridger" whoami)" = "exec" ] \
  || fail "same-folder: session B must resolve to its own name"
(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-arch "$bridger" send exec chat "same dir hi" >/dev/null)
[ "$(cd "$disc/together" && CLAUDE_CODE_SESSION_ID=sess-exec "$bridger" poll)" = "#1 arch chat: same dir hi" ] \
  || fail "same-folder: two sessions in one directory must exchange messages"
pass "two sessions in one directory hold distinct identities and talk"

# --- same name, two sessions: live holder refuses, dead holder is taken over --
mkdir -p "$disc/role"
(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-1 "$bridger" register roleworker >/dev/null)
# A live holder (a running watcher keeps the heartbeat fresh) refuses a 2nd claim.
(cd "$disc/role"; exec env CLAUDE_CODE_SESSION_ID=sess-1 "$bridger" wait --follow >/dev/null 2>&1) &
watcher=$!
await_listening roleworker || fail "watcher never came up for peer roleworker"
if (cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" register roleworker >/dev/null 2>&1); then
  kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
  fail "a name held by a live session must be refused"
fi
kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
# Holder gone (heartbeat forced stale): a second session reclaims the name.
: > "$BRIDGER_ROOT/peers/roleworker.beat"; touch -t 202001010000 "$BRIDGER_ROOT/peers/roleworker.beat"
(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" register roleworker >/dev/null) \
  || fail "a dead holder's name must be reclaimable"
[ "$(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" whoami)" = "roleworker" ] \
  || fail "takeover must bind the name to the reclaiming session"
pass "same name: live holder refused, dead holder taken over"

# --- a register that is REFUSED must not have destroyed anything first -------
# The rename block ran before the refusal, so a register that was going to be
# rejected had already `rm -f`'d the caller's own peer record: the session ended
# up with no identity at all, its old name gone from the bus, and every peer that
# knew it by that name got "unknown peer". Decide first, then mutate.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  rf="$work/refused"; mkdir -p "$rf/a" "$rf/b"
  (cd "$rf/a" && CLAUDE_CODE_SESSION_ID=rs1 "$bridger" register keeper >/dev/null)
  (cd "$rf/b" && CLAUDE_CODE_SESSION_ID=rs2 "$bridger" register taken >/dev/null)
  (cd "$rf/b"; exec env CLAUDE_CODE_SESSION_ID=rs2 "$bridger" wait --follow >/dev/null 2>&1) &
  rw=$!
  await_listening taken || { kill "$rw" 2>/dev/null; fail "watcher never came up for peer taken"; }
  if (cd "$rf/a" && CLAUDE_CODE_SESSION_ID=rs1 "$bridger" register taken >/dev/null 2>&1); then
    kill "$rw" 2>/dev/null || true; wait "$rw" 2>/dev/null || true
    fail "a name held by a live session must be refused"
  fi
  kill "$rw" 2>/dev/null || true; wait "$rw" 2>/dev/null || true
  [ "$(cd "$rf/a" && CLAUDE_CODE_SESSION_ID=rs1 "$bridger" whoami 2>/dev/null)" = "keeper" ] \
    || fail "a refused register deleted the caller's own registration"
  pass "a refused register leaves the caller's own name intact"
  rm -rf "$BRIDGER_ROOT"
)

# --- a name registered elsewhere is somebody's address, not a free string ----
# `register` compared only the session id and the heartbeat, never the recorded
# directory, so any session could rebind a name held by a peer that simply had no
# watcher running — which the plugin's own docs call an ordinary state. That
# silently redirected every queued message and every future send to the taker,
# while the previous holder kept its $PWD, kept working, and never received
# again. The inherited summary made the listing look unchanged.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  tk="$work/takeover"; mkdir -p "$tk/home" "$tk/elsewhere" "$tk/sender"
  (cd "$tk/home" && CLAUDE_CODE_SESSION_ID=ts1 "$bridger" register holder >/dev/null)
  (cd "$tk/sender" && CLAUDE_CODE_SESSION_ID=ts2 "$bridger" register sender >/dev/null)
  (cd "$tk/sender" && CLAUDE_CODE_SESSION_ID=ts2 "$bridger" send holder chat "for the holder" >/dev/null 2>&1)

  if (cd "$tk/elsewhere" && CLAUDE_CODE_SESSION_ID=ts3 "$bridger" register holder >/dev/null 2>&1); then
    fail "a queued peer's name was taken over from another directory"
  fi
  [ "$(cd "$tk/home" && CLAUDE_CODE_SESSION_ID=ts1 "$bridger" whoami)" = "holder" ] \
    || fail "the original holder lost its identity to a takeover"
  grep -q "for the holder" <<<"$(cd "$tk/home" && CLAUDE_CODE_SESSION_ID=ts1 "$bridger" poll)" \
    || fail "the original holder lost its queued mail to a takeover"

  # A caller with NO session id skipped the live-holder refusal entirely, and
  # write_peer then kept the victim's session id on a record pointing at the
  # taker's directory — so the bus reported the name as live and held while its
  # watcher, still running, delivered nothing to anyone ever again.
  (cd "$tk/home"; exec env CLAUDE_CODE_SESSION_ID=ts1 "$bridger" wait --follow >/dev/null 2>&1) &
  tw=$!
  await_listening holder || { kill "$tw" 2>/dev/null; fail "watcher never came up for peer holder"; }
  if (cd "$tk/elsewhere" && env -u CLAUDE_CODE_SESSION_ID -u BRIDGER_SESSION_ID \
        "$bridger" register holder >/dev/null 2>&1); then
    kill "$tw" 2>/dev/null || true; wait "$tw" 2>/dev/null || true
    fail "a caller with no session id took a name held by a live watcher"
  fi
  # Same directory, same hole: two sessions sharing one folder is a documented
  # arrangement, so the id-less claim has to be refused there too — and there the
  # directory check above cannot help, because the directory matches.
  if (cd "$tk/home" && env -u CLAUDE_CODE_SESSION_ID -u BRIDGER_SESSION_ID \
        "$bridger" register holder >/dev/null 2>&1); then
    kill "$tw" 2>/dev/null || true; wait "$tw" 2>/dev/null || true
    fail "a caller with no session id took a listening name in its own directory"
  fi
  kill "$tw" 2>/dev/null || true; wait "$tw" 2>/dev/null || true

  # And the documented reclaim must still work: `missing` is the one status that
  # is evidence the holder is gone, so a deleted worktree can still be taken.
  rm -rf "$tk/home"
  (cd "$tk/elsewhere" && CLAUDE_CODE_SESSION_ID=ts3 "$bridger" register holder >/dev/null) \
    || fail "a name whose directory is gone must still be reclaimable"
  pass "a name registered to another directory cannot be silently taken"
  rm -rf "$BRIDGER_ROOT"
)

# --- concurrent registration on a bus that has ever seen a `leave` -----------
# optout_remove wrote a FIXED "<file>.tmp" shared by every concurrent writer: the
# winner renamed it away and each loser's `mv` failed with ENOENT. That mv was
# the last command of the function, which is the one shape where bash 3.2's
# errexit fires in the CALLER — so `register` died before write_peer and the
# session never joined the bus, reporting only an mv error that says nothing
# about registration. Measured at 64% of registrations lost.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  cr="$work/concreg"; mkdir -p "$cr"
  mkdir -p "$BRIDGER_ROOT/peers"
  for i in 1 2 3 4; do mkdir -p "$cr/c$i"; echo "/opted-out/$i" >> "$BRIDGER_ROOT/optout"; done
  for i in 1 2 3 4; do
    (cd "$cr/c$i" && CLAUDE_CODE_SESSION_ID="cs$i" "$bridger" register "cz$i" >/dev/null 2>&1) &
  done
  wait
  n=$(ls "$BRIDGER_ROOT/peers"/*.json 2>/dev/null | grep -c . || true)
  [ "$n" -eq 4 ] || fail "concurrent registration lost $((4 - n)) of 4 registrations"
  [ "$(grep -c . "$BRIDGER_ROOT/optout" || true)" -eq 4 ] \
    || fail "concurrent registration destroyed entries in the opt-out list"
  pass "concurrent registration does not lose registrations or the opt-out list"
  rm -rf "$BRIDGER_ROOT"
)

# --- no cross-session name adoption (the "wrong role" bug) -------------------
# A directory that accumulated peers from earlier sessions must not hand its
# names to an unrelated new session. Isolated root + AUTO off (opt-in mode).
(
  BRIDGER_ROOT=$(mktemp -d); bw=$(mktemp -d)
  export BRIDGER_ROOT
  unset CLAUDE_BRIDGER_AUTO
  mkdir -p "$bw/pitch"
  (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=old-arch "$bridger" register arch >/dev/null)
  (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=old-exec "$bridger" register exec >/dev/null)

  # A brand-new session in the same directory must NOT inherit arch or exec.
  got=$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=fresh "$bridger" autoregister 2>/dev/null || true)
  [ -z "$got" ] || fail "new session must not auto-adopt another session's peer (got: $got)"
  if (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=fresh "$bridger" whoami >/dev/null 2>&1); then
    fail "new session in a dir with foreign peers must have no identity until it registers"
  fi

  # Its own explicit name binds cleanly; the leftovers keep their own sessions.
  (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=fresh "$bridger" register barca >/dev/null)
  [ "$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=fresh "$bridger" whoami)" = "barca" ] \
    || fail "explicit register must bind the chosen name"
  [ "$(jq -r .session "$BRIDGER_ROOT/peers/arch.json")" = "old-arch" ] \
    || fail "a foreign peer must not be rebound by another session"

  # The owning session still resolves to its own peer (durable address kept).
  [ "$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=old-arch "$bridger" whoami)" = "arch" ] \
    || fail "the owning session must still resolve to its peer"

  # `join` binds to the joining session, so a LATER session does not inherit it.
  mkdir -p "$bw/lib"
  (cd "$bw/lib" && CLAUDE_CODE_SESSION_ID=joiner "$bridger" join >/dev/null)
  [ "$(jq -r .session "$BRIDGER_ROOT/peers/lib.json")" = "joiner" ] || fail "join must bind the peer to the joining session"
  got2=$(cd "$bw/lib" && CLAUDE_CODE_SESSION_ID=later "$bridger" autoregister 2>/dev/null || true)
  [ -z "$got2" ] || fail "a later session must not inherit a join'd name (got: $got2)"
  rm -rf "$BRIDGER_ROOT" "$bw"
)
pass "no cross-session name adoption; join binds; owning session still resolves"

# --- reclaim a dormant name + its queued messages ----------------------------
# arch is registered and gets a message; its holder dies; a NEW session reclaims
# the name and reads everything queued to it. The dormant hint lists it first.
(
  BRIDGER_ROOT=$(mktemp -d); bw=$(mktemp -d)
  export BRIDGER_ROOT
  unset CLAUDE_BRIDGER_AUTO
  mkdir -p "$bw/pitch" "$bw/coach"
  (cd "$bw/coach" && CLAUDE_CODE_SESSION_ID=coach-s "$bridger" register coach >/dev/null)
  (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=arch-old "$bridger" register arch >/dev/null)
  (cd "$bw/coach" && CLAUDE_CODE_SESSION_ID=coach-s "$bridger" send arch chat "tactics for arch" >/dev/null)

  # Holder dies: heartbeat forced stale. The name is now dormant + reclaimable.
  : > "$BRIDGER_ROOT/peers/arch.beat"; touch -t 202001010000 "$BRIDGER_ROOT/peers/arch.beat"
  d=$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=fresh "$bridger" dormant)
  [ "$d" = "$(printf 'arch\t1')" ] || fail "dormant must list the reclaimable peer with its queued count (got: $(printf %q "$d"))"

  # A new session reclaims the name and receives the queued message.
  (cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=arch-new "$bridger" register arch >/dev/null) \
    || fail "a dead holder's name must be reclaimable"
  [ "$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=arch-new "$bridger" whoami)" = "arch" ] \
    || fail "reclaimed name must bind to the new session"
  got=$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=arch-new "$bridger" poll)
  grep -q "tactics for arch" <<<"$got" || fail "reclaiming a name must deliver its queued messages (got: $got)"

  # Once reclaimed and owned, the caller's own name is not listed as dormant.
  [ -z "$(cd "$bw/pitch" && CLAUDE_CODE_SESSION_ID=arch-new "$bridger" dormant | grep '^arch')" ] \
    || fail "dormant must not list the caller's own peer"
  rm -rf "$BRIDGER_ROOT" "$bw"
)
pass "dormant name reclaimed by a new session; queued messages delivered"

unset CLAUDE_BRIDGER_AUTO
rm -rf "$disc"

# --- routing: comma lists and @all, isolated from uninvolved peers -----------
(
  BRIDGER_ROOT=$(mktemp -d); bw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$bw/lead" "$bw/w1" "$bw/w2" "$bw/w3"
  for p in lead w1 w2 w3; do "$bridger" register "$p" "$bw/$p" >/dev/null; done

  out=$(cd "$bw/lead" && "$bridger" send w1,w3 chat "targeted")
  [ "$(grep -c . <<<"$out")" = "2" ] || fail "comma routing must print one line per recipient"
  grep -q "^w1 " <<<"$out" || fail "comma routing output names each recipient"
  [ "$(cd "$bw/w1" && "$bridger" poll)" = "#1 lead chat: targeted" ] || fail "listed peer must receive"
  [ -z "$(cd "$bw/w2" && "$bridger" poll)" ] || fail "unlisted peer must see NOTHING"

  (cd "$bw/lead" && "$bridger" send @all chat "everyone" >/dev/null)
  for p in w1 w2 w3; do
    grep -q "everyone" <<<"$(cd "$bw/$p" && "$bridger" poll)" || fail "@all must reach $p"
  done
  if (cd "$bw/lead" && "$bridger" send @all chat x --from lead 2>/dev/null | grep -q "^lead "); then
    fail "@all must not send to self"
  fi
  if (cd "$bw/lead" && "$bridger" send @all,w1 chat x >/dev/null 2>&1); then
    fail "@all mixed into a peer list must be rejected"
  fi
  if (cd "$bw/lead" && "$bridger" ask w1,w2 "q" --timeout 2 >/dev/null 2>&1); then
    fail "ask must reject fan-out targets"
  fi

  # Delivered set == marked-read set: after a consuming poll, the cursor sits
  # exactly at the highest seq that poll printed, never beyond it.
  (cd "$bw/lead" && "$bridger" send w1 chat one >/dev/null && "$bridger" send w1 chat two >/dev/null)
  delivered=$(cd "$bw/w1" && "$bridger" poll --json)
  highest=$(jq -s 'map(.seq) | max' <<<"$delivered")
  [ "$(cat "$BRIDGER_ROOT"/threads/lead--w1/cursor-w1)" = "$highest" ] \
    || fail "cursor must equal the highest delivered seq"
  rm -rf "$BRIDGER_ROOT" "$bw"
)
pass "targeted comma routing + @all broadcast, no leakage, guards, cursor invariant"

# --- sub-second delivery ------------------------------------------------------
(
  BRIDGER_ROOT=$(mktemp -d); bw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$bw/a" "$bw/b"
  "$bridger" register pa "$bw/a" >/dev/null; "$bridger" register pb "$bw/b" >/dev/null
  start=$(date +%s)
  (sleep 0.3; cd "$bw/a" && "$bridger" send pb chat "fast" >/dev/null) &
  (cd "$bw/b" && "$bridger" wait --timeout 10 >/dev/null) || fail "wait missed the message"
  took=$(( $(date +%s) - start ))
  [ "$took" -le 2 ] || fail "delivery took ${took}s; sub-second poll is broken"
  wait
  rm -rf "$BRIDGER_ROOT" "$bw"
)
pass "wait notices a message within ~1s"

# --- log --json + governance mirror ------------------------------------------
jsonl=$(cd "$work/app" && "$bridger" log liba --json)
jq -es 'length > 0' <<<"$jsonl" >/dev/null || fail "log --json must emit valid JSON lines"

s1=$(cd "$work/app" && "$bridger" send liba stop "S-1: promote baseline? reply: yes|no")
(cd "$work/liba" && "$bridger" send app ruling "yes. conditions: baselines re-recorded" --ref "$s1" >/dev/null)
mirror1=$(cd "$work/app" && "$bridger" mirror liba)
grep -q "S-1: promote baseline" <<<"$mirror1" || fail "mirror must include stop messages"
grep -q "re #$s1" <<<"$mirror1" || fail "mirror must show the ruling's ref"
grep -q "hello lib" <<<"$mirror1" && fail "mirror must exclude non-governance types by default"
mirror2=$(cd "$work/app" && "$bridger" mirror liba)
[ "$mirror1" = "$mirror2" ] || fail "mirror must be deterministic"
[ "$mirror1" = "$(cd "$work/liba" && "$bridger" mirror app)" ] || fail "mirror must be identical from either side"
grep -q "hello lib" <<<"$(cd "$work/app" && "$bridger" mirror liba --types all)" || fail "--types all must include everything"
pass "log --json + deterministic governance mirror"

# --- log + status render without error --------------------------------------
# Capture first: with pipefail, grep -q's early exit would SIGPIPE the writer.
logout=$(cd "$work/app" && "$bridger" log liba)
grep -q "hello lib" <<<"$logout" || fail "log shows history"
statusout=$(cd "$work/app" && "$bridger" status)
grep -q "app" <<<"$statusout" || fail "status shows identity"
grep -q "unread-by-them:" <<<"$statusout" || fail "status must show what the peer has not read yet"
pass "log + status"

# --- a send to a peer that is not listening must say so ----------------------
# Otherwise the sender has no way to tell "hasn't replied yet" from "cannot
# hear me", and keeps queueing messages nobody is reading.
mkdir -p "$work/deaf"
"$bridger" register deaf "$work/deaf" >/dev/null
warned=$( (cd "$work/app" && "$bridger" send deaf chat "anyone there" >/dev/null) 2>&1 )
grep -q "'deaf' is not listening" <<<"$warned" || fail "send must warn when the target has no watcher (got: $warned)"
grep -q "1 message(s) from you are unread" <<<"$warned" || fail "the warning must count what is already waiting"
(cd "$work/app" && "$bridger" send deaf chat "still there" >/dev/null) 2>&1 \
  | grep -q "2 message(s) from you are unread" || fail "the backlog count must grow with each unheard send"

# The warning is stderr only: stdout stays the bare sequence number.
[ "$( (cd "$work/app" && "$bridger" send deaf chat "third") 2>/dev/null )" = "3" ] \
  || fail "the warning must not pollute the seq on stdout"

(cd "$work/deaf"; exec "$bridger" wait --follow >/dev/null 2>&1) &
dw=$!
await_listening deaf || fail "watcher never came up for peer deaf"
[ -z "$( (cd "$work/app" && "$bridger" send deaf chat "now?" >/dev/null) 2>&1 )" ] \
  || fail "send must not warn when the target is listening"
kill "$dw" 2>/dev/null || true
wait "$dw" 2>/dev/null || true
pass "send warns the sender when the target cannot hear it"

# --- a watcher that stops says so in the log ---------------------------------
# The watcher never exits on its own, so a death is always worth a line: one
# died twice mid-session with exit 144 and left nothing to read.
grep -q "deaf	signal=TERM" "$BRIDGER_ROOT/watcher.log" \
  || fail "a signalled watcher must record the signal (got: $(cat "$BRIDGER_ROOT/watcher.log" 2>/dev/null))"
grep -q "deaf	exit=" "$BRIDGER_ROOT/watcher.log" \
  || fail "a watcher exit must record its status"
pass "watcher records how it died"

# --- a registration whose directory no longer exists -------------------------
# A deleted worktree leaves a peer record that cannot be removed any other way:
# `leave` resolves the peer from $PWD, which is impossible once that directory
# is gone. It is flagged so `reap` can find it — but ONLY flagged. The peer stays
# fully addressable, because "the directory is gone" is not proof the peer is.
(
  BRIDGER_ROOT=$(mktemp -d); gw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$gw/lead" "$gw/live" "$gw/dead"
  for p in lead live dead; do "$bridger" register "$p" "$gw/$p" >/dev/null; done
  (cd "$gw/lead" && "$bridger" send dead chat "before it went" >/dev/null) 2>/dev/null
  rm -rf "$gw/dead"

  # Capture before grepping: `grep -q` stops at the first match and SIGPIPEs the
  # producer, which under pipefail fails the whole pipeline.
  listed=$("$bridger" peers)
  grep -q "^dead \[missing\]" <<<"$listed" \
    || fail "a peer whose directory is deleted must read [missing] (got: $listed)"
  grep -q "^live \[queued\]" <<<"$listed" \
    || fail "a closed peer whose directory still exists must stay [queued]"
  grep -q "reap" <<<"$listed" || fail "the listing must point at the command that clears these"

  # Still a normal peer in every routing decision. It may be a live session
  # reading from the removed path, and nothing here can tell.
  [ "$( (cd "$gw/lead" && "$bridger" send dead chat "still queued") 2>/dev/null )" = "2" ] \
    || fail "a targeted send must still be stored for a peer whose directory is gone"
  out=$(cd "$gw/lead" && "$bridger" send @all chat "everyone" 2>/dev/null)
  grep -q "^live " <<<"$out" || fail "@all must reach a peer whose directory exists"
  grep -q "^dead " <<<"$out" \
    || fail "@all must NOT skip a peer whose directory is gone — it may still be reading"

  # Dry run by default: the operator decides, on the unread counts.
  dry=$("$bridger" reap)
  grep -q "^dead" <<<"$dry" || fail "reap must list a peer whose directory is gone (got: $dry)"
  [ -f "$BRIDGER_ROOT/peers/dead.json" ] || fail "reap without --force must delete nothing"
  "$bridger" reap --force >/dev/null
  [ ! -f "$BRIDGER_ROOT/peers/dead.json" ] || fail "reap --force must drop the registration"
  [ -f "$BRIDGER_ROOT/peers/live.json" ] || fail "reap must not touch a peer whose directory exists"
  [ -d "$BRIDGER_ROOT/threads/dead--lead" ] || fail "reap must keep the thread on disk as history"
  grep -q "nothing to reap" <<<"$("$bridger" reap)" \
    || fail "reap must say so when there is nothing to reap"
  rm -rf "$BRIDGER_ROOT" "$gw"
)
pass "a deleted directory is flagged for reap without changing how the peer is addressed"

# --- a session in a deleted directory is still a real peer -------------------
# THE regression this whole feature can cause. Deleting a worktree does not kill
# the session inside it: a process keeps its cwd — and $PWD, which is what
# resolve_identity compares — when the directory is unlinked. Such a session goes
# on resolving its name, polling and sending, WITHOUT any watcher armed, which
# this bus treats as ordinary. Anything that treats "directory gone" as "peer
# dead" silently drops a session that is reading.
(
  BRIDGER_ROOT=$(mktemp -d); sw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$sw/lead" "$sw/open"
  "$bridger" register lead "$sw/lead" >/dev/null
  BRIDGER_SESSION_ID=sopen "$bridger" register open "$sw/open" >/dev/null
  # The session keeps running with that directory as its cwd while it is removed.
  (
    cd "$sw/open"
    rm -rf "$sw/open"
    export BRIDGER_SESSION_ID=sopen
    [ "$("$bridger" whoami)" = "open" ] || { echo "whoami" > "$sw/broke"; exit 0; }
    "$bridger" send lead chat "I am alive and reading" >/dev/null 2>&1 \
      || { echo "send" > "$sw/broke"; exit 0; }
  )
  [ ! -f "$sw/broke" ] \
    || fail "a session in a removed directory must keep working (failed at: $(cat "$sw/broke"))"
  [ -n "$(cd "$sw/lead" && "$bridger" poll)" ] \
    || fail "a session in a removed directory must still be able to send"

  out=$(cd "$sw/lead" && "$bridger" send @all chat "broadcast" 2>/dev/null)
  grep -q "^open " <<<"$out" \
    || fail "@all must reach a session whose directory was removed (got: $out)"
  rm -rf "$BRIDGER_ROOT" "$sw"
)
pass "a watcherless session in a removed directory stays addressable and reachable by @all"

# --- a deleted directory does NOT unreach a watcher that is already running ---
# Deleting a worktree does not kill the session inside it. That watcher never
# re-resolves its identity (resolve_identity compares $PWD as a string, and a
# process keeps its cwd when the directory is unlinked) and the beat path is
# absolute, so it keeps delivering. Liveness therefore outranks the directory:
# flagging it as abandoned would let reap delete a live session's registration.
(
  BRIDGER_ROOT=$(mktemp -d); lw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$lw/lead" "$lw/wt"
  "$bridger" register lead "$lw/lead" >/dev/null
  BRIDGER_SESSION_ID=wtsess "$bridger" register wt "$lw/wt" >/dev/null
  (cd "$lw/wt"; exec env BRIDGER_SESSION_ID=wtsess "$bridger" wait --follow >"$lw/out" 2>&1) &
  watcher=$!
  await_listening wt || fail "watcher never came up for peer wt"
  rm -rf "$lw/wt"          # `git worktree remove` with the session still open

  [ "$("$bridger" peers | grep -c '^wt \[listening\]')" = "1" ] \
    || fail "a live watcher must stay [listening] when its directory is deleted (got: $("$bridger" peers))"
  out=$(cd "$lw/lead" && "$bridger" send @all chat "still here" 2>/dev/null)
  grep -q "^wt " <<<"$out" || fail "@all must not skip a peer whose watcher is running"
  grep -q "nothing to reap" <<<"$("$bridger" reap)" \
    || fail "reap must never offer to delete a peer whose watcher is running (got: $("$bridger" reap))"
  # Same reasoning as await_listening: poll for the delivery, don't guess how
  # long the watcher's poll cycle takes on a machine under load.
  for _ in $(seq 1 150); do
    grep -q "still here" "$lw/out" && break
    sleep 0.1
  done
  grep -q "still here" "$lw/out" \
    || fail "the live watcher must actually receive the broadcast (got: $(cat "$lw/out"))"

  # A watcher alive but too loaded to beat: no longer [listening], yet a reader
  # IS there. Only the live-pid half of the check separates this from abandoned,
  # and without this case that half can be deleted with the suite still green.
  kill -STOP "$watcher"
  touch -t 202001010000 "$BRIDGER_ROOT/peers/wt.beat"
  [ "$("$bridger" peers | grep -c '^wt \[queued\]')" = "1" ] \
    || fail "a live watcher whose beat went stale is [queued], never [missing] (got: $("$bridger" peers))"
  grep -q "nothing to reap" <<<"$("$bridger" reap)" \
    || fail "reap must not offer a peer whose watcher process is alive (got: $("$bridger" reap))"
  kill -CONT "$watcher"

  # Once that watcher dies the peer is flagged [missing] instead — the fact the
  # directory is gone, now that no watcher process is running for the name.
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  [ "$(cd "$lw/lead" && "$bridger" peers | grep -c '^wt \[missing\]')" = "1" ] \
    || fail "a dead watcher plus a deleted directory must read [missing] (got: $("$bridger" peers))"
  rm -rf "$BRIDGER_ROOT" "$lw"
)
pass "a running watcher outranks its deleted directory; flagged missing only once it dies"

# --- concurrent writers of one peer record must not corrupt it ---------------
# register racing register (or register racing summary) on the same name: a
# shared temp path would let both interleave into one inode, and the mv would
# then commit that garbage permanently — worse than the truncating `>` it
# replaced, because a listing that hits it dies with jq's exit 5 and shows
# NOTHING, hiding every other peer too.
(
  BRIDGER_ROOT=$(mktemp -d); cw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$cw/hot"
  "$bridger" register hot "$cw/hot" >/dev/null
  # Failures are recorded in a file, not a variable: `cmd || rc=1 &` backgrounds
  # the whole list, so the assignment would happen in a subshell and never reach
  # this one.
  fails="$cw/failures"
  for _ in $(seq 1 15); do
    ( "$bridger" register hot "$cw/hot" >/dev/null 2>&1 || echo x >> "$fails" ) &
    ( cd "$cw/hot" && "$bridger" summary "racing" >/dev/null 2>&1 || echo x >> "$fails" ) &
  done
  wait
  [ ! -s "$fails" ] \
    || fail "a concurrent register/summary on one peer must not fail ($(grep -c . "$fails") of 30 did)"
  jq -e . "$BRIDGER_ROOT/peers/hot.json" >/dev/null 2>&1 \
    || fail "the peer record must stay valid JSON under concurrent writers (got: $(cat "$BRIDGER_ROOT/peers/hot.json"))"
  [ "$("$bridger" peers | grep -c '^hot ')" = "1" ] \
    || fail "the listing must survive concurrent writers"
  rm -rf "$BRIDGER_ROOT" "$cw"
)
pass "concurrent register/summary on one peer leaves a valid record"

# --- reap's evidence has to be right, because it is all the operator gets -----
# The unread count is the whole basis for a destructive choice. Counting through
# the peer registry undercounts: a thread outlives its partner's registration
# (`leave` and `reap` both keep it), so mail from a departed correspondent — the
# most stranded mail there is — would be invisible to the number.
(
  BRIDGER_ROOT=$(mktemp -d); ew=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$ew/alice" "$ew/bob"
  "$bridger" register alice "$ew/alice" >/dev/null
  "$bridger" register bob "$ew/bob" >/dev/null
  (cd "$ew/alice" && for i in 1 2 3; do "$bridger" send bob chat "m$i" >/dev/null 2>&1; done)
  rm -rf "$ew/bob"
  (cd "$ew/alice" && "$bridger" leave >/dev/null)     # record goes, thread stays
  grep -q "3 unread" <<<"$("$bridger" reap)" \
    || fail "reap must count mail from a correspondent that has left (got: $("$bridger" reap))"

  # The operator is told to decide on this number, so an incomplete count must
  # say so rather than making a peer that holds mail look emptier than it is.
  if [ "$(id -u)" != "0" ]; then
    bad=$(ls "$BRIDGER_ROOT"/threads/*bob*/[0-9]*.json | head -1)
    chmod 000 "$bad"
    grep -q "[0-9]+ unread" <<<"$("$bridger" reap 2>/dev/null)" \
      || fail "an unreadable message must make reap's count a floor, not a silent undercount (got: $("$bridger" reap 2>/dev/null))"
    chmod 644 "$bad"
  fi

  # An unreadable record is not evidence a directory is gone. write_peer does
  # mktemp+mv without fsync, so a 0-byte record is the ordinary crash outcome —
  # for a peer whose directory is perfectly fine and whose session is running.
  mkdir -p "$ew/worker"
  "$bridger" register worker "$ew/worker" >/dev/null
  : > "$BRIDGER_ROOT/peers/worker.json"
  "$bridger" reap --force >/dev/null
  [ -f "$BRIDGER_ROOT/peers/worker.json" ] \
    || fail "reap --force must not delete a peer whose record merely cannot be read"

  # Nor one whose cwd is not a path at all. `jq -r` renders null as the STRING
  # "null" — a relative path, which resolves against the caller's directory and
  # reads as provably gone. Deleting on that is the same "I cannot tell" mistake.
  printf '{"name":"nullcwd","cwd":null}'  > "$BRIDGER_ROOT/peers/nullcwd.json"
  printf '{"name":"numcwd","cwd":12345}'  > "$BRIDGER_ROOT/peers/numcwd.json"
  printf '{"name":"arrcwd","cwd":["/x"]}' > "$BRIDGER_ROOT/peers/arrcwd.json"
  listed=$("$bridger" peers 2>/dev/null)
  for weird in nullcwd numcwd arrcwd; do
    grep -q "^$weird \[queued\]" <<<"$listed" \
      || fail "a record with a non-string cwd is queued, never missing (got: $listed)"
  done
  [ "$(grep -c '^arrcwd ' <<<"$listed")" = "1" ] \
    || fail "each peer must occupy exactly one line, whatever its record holds"
  "$bridger" reap --force >/dev/null
  for weird in nullcwd numcwd arrcwd; do
    [ -f "$BRIDGER_ROOT/peers/$weird.json" ] \
      || fail "reap --force must not delete a peer whose cwd is not a path ($weird)"
  done
  rm -rf "$BRIDGER_ROOT" "$ew"
)
pass "reap counts stranded mail and never reaps a peer it simply cannot read"

# --- dormant offers a name that can actually be reclaimed --------------------
# The filename is the address. session-start.sh renders this list as a reclaim
# offer, so a record whose .name drifted would offer a name with no registration
# and no mail, while the real backlog sits under the filename, never mentioned.
(
  BRIDGER_ROOT=$(mktemp -d); dw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$dw/proj" "$dw/other"
  "$bridger" register arch "$dw/proj" >/dev/null
  "$bridger" register mate "$dw/other" >/dev/null
  (cd "$dw/other" && "$bridger" send arch chat "queued for arch" >/dev/null 2>&1)
  tmp=$(mktemp)
  jq '.name = "notarch"' "$BRIDGER_ROOT/peers/arch.json" > "$tmp" && mv "$tmp" "$BRIDGER_ROOT/peers/arch.json"
  [ "$(cd "$dw/proj" && BRIDGER_SESSION_ID=fresh "$bridger" dormant)" = "$(printf 'arch\t1')" ] \
    || fail "dormant must offer the reachable name and its real backlog (got: $(cd "$dw/proj" && BRIDGER_SESSION_ID=fresh "$bridger" dormant))"
  listed=$("$bridger" peers)
  grep -q "^arch " <<<"$listed" \
    || fail "peers must list the name a message can be addressed to (got: $listed)"
  # `!` not `&&`: a bare `grep … && fail` aborts the block under set -e on the
  # no-match path, which is the passing one.
  ! grep -q "^notarch " <<<"$listed" \
    || fail "peers must not print an address nothing can reach (got: $listed)"
  rm -rf "$BRIDGER_ROOT" "$dw"
)
pass "dormant offers the name a session can actually reclaim"

# --- one bad file must never take the whole bus down ---------------------------
# jq exits 5 on an unparseable record, and under errexit that aborted the listing
# mid-loop: every peer sorting after it vanished, `peers` exited nonzero, and
# deliver.sh/stop.sh both do `peers || exit 0` — so one truncated file silenced
# unread reports for every session on the machine.
(
  BRIDGER_ROOT=$(mktemp -d); bw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$bw/alpha" "$bw/zulu"
  "$bridger" register alpha "$bw/alpha" >/dev/null
  "$bridger" register zulu "$bw/zulu" >/dev/null
  printf '{"name":"gam' > "$BRIDGER_ROOT/peers/gamma.json"   # a crash-truncated record
  listed=$("$bridger" peers 2>/dev/null) || fail "one unreadable record must not fail the listing"
  grep -q "^zulu " <<<"$listed" \
    || fail "a peer sorting after an unreadable record must still be listed (got: $listed)"
  grep -q "^alpha " <<<"$listed" || fail "peers before the bad record must still be listed"

  # The cursor is read back as an integer. Empty (advance_cursor truncates before
  # writing, so a concurrent reader can catch it mid-write) must mean "nothing
  # read yet" — reading it as "everything read" loses the mail permanently.
  (cd "$bw/alpha" && "$bridger" send zulu chat "keepme" >/dev/null 2>&1)
  thread=$(echo "$BRIDGER_ROOT"/threads/*zulu*)
  : > "$thread/cursor-zulu"
  [ -n "$(cd "$bw/zulu" && "$bridger" poll)" ] \
    || fail "an empty cursor must not mark every message read"

  # One unparseable message must not wedge the thread: jq's exit 5 used to kill
  # poll before advance_cursor, so every LATER message became unreachable and the
  # reader replayed the same prefix forever.
  (cd "$bw/alpha" && for i in 1 2 3; do "$bridger" send zulu note "n$i" >/dev/null 2>&1; done)
  thread=$(echo "$BRIDGER_ROOT"/threads/*zulu*)
  corrupt=$(ls "$thread"/[0-9]*.json | sed -n 2p)
  printf '{"to":"zulu"' > "$corrupt"                       # truncated mid-write
  got=$(cd "$bw/zulu" && "$bridger" poll 2>/dev/null)
  grep -q "n3" <<<"$got" \
    || fail "a message after an unparseable one must still be delivered (got: $got)"

  # ... but a message that is merely unreadable RIGHT NOW is a different case.
  # Skipping it would let advance_cursor mark a perfectly good message delivered
  # and destroy it. Wedging is the safe half: it clears itself on the next poll.
  if [ "$(id -u)" != "0" ]; then
    (cd "$bw/alpha" && for i in 1 2; do "$bridger" send zulu note "t$i" >/dev/null 2>&1; done)
    locked=$(ls "$thread"/[0-9]*.json | tail -2 | head -1)
    chmod 000 "$locked"
    (cd "$bw/zulu" && "$bridger" poll >/dev/null 2>&1) \
      && fail "a transiently unreadable message must not be passed over silently"
    chmod 644 "$locked"
    got=$(cd "$bw/zulu" && "$bridger" poll 2>/dev/null)
    grep -q "t1" <<<"$got" \
      || fail "a message unreadable on one poll must still arrive on the next (got: $got)"
  fi
  rm -rf "$BRIDGER_ROOT" "$bw"
)
pass "an unreadable record does not hide other peers, and an empty cursor loses no mail"

# --- "I cannot look" is not "it is gone" --------------------------------------
# [ ! -d ] is also false when a parent turned untraversable, and a live session
# may be reading inside. reap --force would then unregister a healthy peer and
# strand its mail on a directory that demonstrably exists.
(
  # root traverses a 0000 directory regardless, which would make this vacuous.
  [ "$(id -u)" = "0" ] && exit 0
  BRIDGER_ROOT=$(mktemp -d); pw=$(mktemp -d)
  export BRIDGER_ROOT
  mkdir -p "$pw/outer/inner" "$pw/other"
  "$bridger" register victim "$pw/outer/inner" >/dev/null
  "$bridger" register other "$pw/other" >/dev/null
  (cd "$pw/other" && "$bridger" send victim chat "mine" >/dev/null 2>&1)
  chmod 000 "$pw/outer"
  # chmod back no matter how the assertions go, or the temp dir cannot be removed.
  trap 'chmod 755 "$pw/outer" 2>/dev/null || true' EXIT
  listed=$("$bridger" peers)
  ! grep -q "^victim \[missing\]" <<<"$listed" \
    || fail "an untraversable parent is not proof the directory is gone (got: $listed)"
  "$bridger" reap --force >/dev/null
  [ -f "$BRIDGER_ROOT/peers/victim.json" ] \
    || fail "reap --force must not unregister a peer whose directory it merely cannot look at"
  chmod 755 "$pw/outer"
  rm -rf "$BRIDGER_ROOT" "$pw"
)
pass "an untraversable parent leaves a peer registered and unreaped"

# --- statusline badge + drop-in wiring ---------------------------------------
# Fully isolated: its own BRIDGER_ROOT (badge state) and CLAUDE_CONFIG_DIR
# (settings.json + statusline.d), so it never touches the real ~/.claude.
(
  badge="$here/hooks/statusline.sh"
  BRIDGER_ROOT=$(mktemp -d); cfg=$(mktemp -d); sw=$(mktemp -d)
  export BRIDGER_ROOT
  export CLAUDE_CONFIG_DIR="$cfg"
  mkdir -p "$sw/proj" "$sw/autowired" "$sw/foreign"

  render_badge() { printf '{"session_id":"%s"}' "$1" | bash "$badge"; }

  # Badge shows the name this session registered — written by register, no
  # statusLine rewrite; the badge reads the per-session state file each tick.
  (cd "$sw/proj" && CLAUDE_CODE_SESSION_ID=badge-sess "$bridger" register architect >/dev/null)
  out=$(render_badge badge-sess)
  case "$out" in *"BRIDGER:architect"*) ;; *) fail "badge must show the registered name (got: $out)" ;; esac
  # A different session with no registration gets no badge.
  [ -z "$(render_badge other-sess)" ] || fail "badge must be empty for an unregistered session"

  # Unregister → state file deleted → badge gone next tick.
  (cd "$sw/proj" && CLAUDE_CODE_SESSION_ID=badge-sess "$bridger" leave >/dev/null)
  [ -z "$(render_badge badge-sess)" ] || fail "badge must vanish after leave"
  pass "badge reflects registration: shows name, gone when unregistered"

  # Name sanitization: the state file is dynamic, session-supplied content. A
  # crafted name must not smuggle control chars / ANSI escapes to the terminal.
  mkdir -p "$BRIDGER_ROOT/statusline"
  # Whitelist keeps [A-Za-z0-9._-]: ESC, '[', BEL and ';' are dropped, the safe
  # bytes of the escape ("31m") survive as ordinary text — harmless, no injection.
  printf 'bad\033[31mX\007;Y' > "$BRIDGER_ROOT/statusline/evil-sess"
  out=$(render_badge evil-sess)
  case "$out" in *$'\007'*) fail "badge leaked a BEL control char from a crafted name" ;; esac
  # Strip the badge's own colour codes; what remains must be only the safe charset.
  clean=$(printf '%s' "$out" | sed "s/$(printf '\033')\[[0-9;]*m//g")
  [ "$clean" = "[⇄ BRIDGER:bad31mXY ⚠ queued]" ] || fail "badge must strip to a safe charset (got: $(printf %q "$clean"))"
  pass "badge sanitizes crafted names (no ANSI/control-char injection)"

  # Registered-but-deaf must be VISIBLE. The badge reads the same heartbeat
  # `peers` does, so it flips on watcher liveness, not on registration: a
  # watcher that was never armed, and one that died an hour ago leaving its
  # beat file behind, must both render "queued".
  (cd "$sw/proj" && CLAUDE_CODE_SESSION_ID=beat-sess "$bridger" register scribe >/dev/null)
  out=$(render_badge beat-sess)
  case "$out" in *"BRIDGER:scribe"*queued*) ;; *) fail "badge must read queued when no watcher was ever armed (got: $out)" ;; esac
  : > "$BRIDGER_ROOT/peers/scribe.beat"   # what the watcher rewrites every cycle
  out=$(render_badge beat-sess)
  case "$out" in
    *queued*) fail "badge must read listening while the heartbeat is fresh (got: $out)" ;;
    *"BRIDGER:scribe"*) ;;
    *) fail "badge must still show the name while listening (got: $out)" ;;
  esac
  touch -t 202001010000 "$BRIDGER_ROOT/peers/scribe.beat"   # watcher died, file left behind
  out=$(render_badge beat-sess)
  case "$out" in *queued*) ;; *) fail "a stale heartbeat (dead watcher) must render queued, not listening (got: $out)" ;; esac
  # SIGKILL: the beat stays fresh for up to 15s, but its pid is already gone.
  ( : ) & gone=$!; wait "$gone" 2>/dev/null || true
  echo "$gone" > "$BRIDGER_ROOT/peers/scribe.beat"
  out=$(render_badge beat-sess)
  case "$out" in *queued*) ;; *) fail "a fresh beat from a dead pid must render queued (got: $out)" ;; esac
  (cd "$sw/proj" && CLAUDE_CODE_SESSION_ID=beat-sess "$bridger" leave >/dev/null)
  pass "badge renders listening vs queued from the watcher heartbeat"

  # Fresh wiring: no settings.json → installs dispatcher + fragment, points at it.
  "$bridger" statusline >/dev/null
  [ -f "$cfg/statusline.d/50-bridger.sh" ]      || fail "wiring must drop the 50-bridger.sh fragment"
  [ -f "$cfg/hooks/bridger-statusline.sh" ]     || fail "wiring must install the stable badge copy"
  [ -f "$cfg/hooks/statusline-dispatch.sh" ]    || fail "wiring must install the dispatcher when none exists"
  grep -q statusline-dispatch "$cfg/settings.json" || fail "settings.json must point at the dispatcher"
  jq -e . "$cfg/settings.json" >/dev/null        || fail "settings.json must stay valid JSON"
  "$bridger" statusline-status >/dev/null 2>&1  || fail "wired-detection must be true after install"
  pass "statusline fresh install: dispatcher + fragment wired, detection true"

  # Idempotent: a second run finds itself wired and never prompts a choice.
  out=$("$bridger" statusline)
  case "$out" in *NEEDS-CHOICE*) fail "re-running on an already-wired setup must not prompt NEEDS-CHOICE" ;; esac
  pass "statusline re-wire is idempotent"

  # Foreign statusline: never overwrite it — surface NEEDS-CHOICE, leave it byte-identical.
  rm -rf "$cfg"; mkdir -p "$cfg"
  printf '{"statusLine":{"type":"command","command":"bash /opt/othertool.sh"}}' > "$cfg/settings.json"
  before=$(cat "$cfg/settings.json")
  if out=$("$bridger" statusline); then fail "a foreign statusline must make wiring exit non-zero"; fi
  case "$out" in *NEEDS-CHOICE*othertool*) ;; *) fail "foreign statusline must surface NEEDS-CHOICE with the current command (got: $out)" ;; esac
  [ "$(cat "$cfg/settings.json")" = "$before" ] || fail "a foreign statusline must be left untouched"
  "$bridger" statusline-status >/dev/null 2>&1 && fail "wired-detection must be false against a foreign statusline"
  pass "statusline no-clobber of a foreign command; wired-detection false"

  # Self-heal signal: wired → a foreign setup repoints settings → detection flips
  # to unwired (this flip is exactly what the SessionStart hook re-offers on).
  rm -rf "$cfg"; mkdir -p "$cfg"
  "$bridger" statusline >/dev/null
  "$bridger" statusline-status >/dev/null 2>&1 || fail "self-heal: must read wired right after wiring"
  printf '{"statusLine":{"type":"command","command":"bash /opt/othertool.sh"}}' > "$cfg/settings.json"
  "$bridger" statusline-status >/dev/null 2>&1 && fail "self-heal: must read unwired after a foreign takeover"
  pass "statusline self-heal detection: wired after wiring, unwired after takeover"

  # Self-wiring on register, the no-restart path: a drop-in dispatcher someone
  # else installed is already the active statusline, so registering only has to
  # drop one file for the badge to render in THIS session.
  rm -rf "$cfg"; mkdir -p "$cfg/hooks"
  cp "$here/hooks/statusline-dispatch.sh" "$cfg/hooks/othertool.sh"
  printf '{"statusLine":{"type":"command","command":"bash %s/hooks/othertool.sh"}}' "$cfg" > "$cfg/settings.json"
  before=$(cat "$cfg/settings.json")
  (cd "$sw/autowired" && CLAUDE_CODE_SESSION_ID=auto-sess "$bridger" register scout >/dev/null)
  [ -f "$cfg/statusline.d/50-bridger.sh" ] || fail "register must self-wire the fragment into a live drop-in dispatcher"
  [ "$(cat "$cfg/settings.json")" = "$before" ] || fail "self-wiring must not touch settings.json"
  out=$(printf '{"session_id":"auto-sess"}' | bash "$cfg/hooks/othertool.sh")
  case "$out" in *"BRIDGER:scout"*) ;; *) fail "the badge must render through the existing dispatcher (got: $out)" ;; esac
  pass "register self-wires the badge into a live dispatcher, settings.json untouched"

  # No dispatcher to join: wiring would mean rewriting a foreign statusline (and
  # would only show up next session), so register must wire nothing and leave
  # that choice to the one-time offer.
  rm -rf "$cfg"; mkdir -p "$cfg"
  printf '{"statusLine":{"type":"command","command":"bash /opt/othertool.sh"}}' > "$cfg/settings.json"
  before=$(cat "$cfg/settings.json")
  (cd "$sw/foreign" && CLAUDE_CODE_SESSION_ID=nowire-sess "$bridger" register lookout >/dev/null)
  [ -f "$cfg/statusline.d/50-bridger.sh" ] && fail "register must not wire a badge when no drop-in dispatcher is active"
  [ "$(cat "$cfg/settings.json")" = "$before" ] || fail "register must never edit a foreign statusline"
  pass "register never self-wires against a foreign statusline"

  rm -rf "$BRIDGER_ROOT" "$cfg" "$sw"
)

# --- delivery hooks: reaching a session whose watcher is not running ---------
# The watcher is the only path into an IDLE session, and only the agent can
# start it. These hooks cover the states that leaves blind: mid-task
# (PostToolUse), and the human's next turn (UserPromptSubmit). Both must be
# no-ops while the watcher is running — it already delivers.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  up=$(mktemp -d); mkdir -p "$up/reader" "$up/writer"
  hook="$here/hooks/deliver.sh"
  ups='{"hook_event_name":"UserPromptSubmit","cwd":"'"$up/reader"'","session_id":"reader-sess"}'
  ptu='{"hook_event_name":"PostToolUse","cwd":"'"$up/reader"'","session_id":"reader-sess"}'

  (cd "$up/reader" && BRIDGER_SESSION_ID=reader-sess "$bridger" register reader >/dev/null)
  (cd "$up/writer" && BRIDGER_SESSION_ID=writer-sess "$bridger" register writer >/dev/null)

  [ -z "$(printf '%s' "$ups" | bash "$hook")" ] || fail "hook must stay silent with no unread"

  (cd "$up/writer" && BRIDGER_SESSION_ID=writer-sess "$bridger" send reader ask "ruling: use v2" >/dev/null 2>/dev/null)
  out=$(printf '%s' "$ups" | bash "$hook")
  grep -q "writer ask: ruling: use v2" <<<"$out" || fail "hook must surface the unread message (got: $out)"
  grep -q "1 unread" <<<"$out" || fail "hook must report the unread count"

  # --peek, not poll: re-shown until acted on, and never consumed out from
  # under the agent (or a watcher) by the hook itself.
  grep -q "writer ask: ruling: use v2" <<<"$(printf '%s' "$ups" | bash "$hook")" \
    || fail "hook must peek, not consume — the message must survive to the next turn"

  # PostToolUse feeds context back only through hookSpecificOutput, so its
  # output must be JSON carrying the same message.
  out=$(printf '%s' "$ptu" | bash "$hook")
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = "PostToolUse" ] \
    || fail "PostToolUse output must be hookSpecificOutput JSON (got: $out)"
  jq -r '.hookSpecificOutput.additionalContext' <<<"$out" | grep -q "writer ask: ruling: use v2" \
    || fail "PostToolUse must carry the message in additionalContext"

  # Mid-task the report is per arrival, not per tool call — the same message
  # must not be re-injected after every subsequent tool.
  [ -z "$(printf '%s' "$ptu" | bash "$hook")" ] \
    || fail "PostToolUse must report a message once, not on every tool call"

  # ... but a message that lands after that must still get through.
  sleep 1
  (cd "$up/writer" && BRIDGER_SESSION_ID=writer-sess "$bridger" send reader chat "and v2.1 too" >/dev/null 2>/dev/null)
  jq -r '.hookSpecificOutput.additionalContext' <<<"$(printf '%s' "$ptu" | bash "$hook")" \
    | grep -q "and v2.1 too" || fail "PostToolUse must report a message that arrives later"

  # Registering is the moment the watcher is easiest to forget, so the
  # instruction is injected next to that call's own result. With nothing waiting,
  # that is the whole message.
  (cd "$up/reader" && BRIDGER_SESSION_ID=reader-sess "$bridger" poll >/dev/null 2>&1)
  regcall='{"hook_event_name":"PostToolUse","cwd":"'"$up/reader"'","session_id":"reader-sess","tool_input":{"command":"'"$bridger"' register scout"}}'
  out=$(printf '%s' "$regcall" | bash "$hook")
  jq -r '.hookSpecificOutput.additionalContext' <<<"$out" | grep -q "NOT yet listening" \
    || fail "a register call must draw the arm-the-watcher instruction (got: $out)"

  # But mail outranks the nag: a registration in a session that has unread
  # messages must still DELIVER them, and the arm instruction rides along in the
  # delivery text. The nag used to be emitted first and exit, dropping the mail.
  (cd "$up/writer" && BRIDGER_SESSION_ID=writer-sess "$bridger" send reader ask "URGENT which api" >/dev/null 2>/dev/null)
  rm -f "$BRIDGER_ROOT/reported-reader-sess"
  out=$(printf '%s' "$regcall" | bash "$hook")
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
  grep -q "URGENT which api" <<<"$ctx" || fail "a register call must not swallow unread mail (got: $out)"
  grep -q "Arm the watcher NOW" <<<"$ctx" || fail "delivery must still carry the arm instruction (got: $out)"

  # ...but that branch matched the command text as a SUBSTRING and then exited,
  # so any command merely MENTIONING the phrase — a grep, a doc edit, a test —
  # both injected a false "this session is now registered" and skipped delivery
  # of real unread mail on that tool call.
  (cd "$up/writer" && BRIDGER_SESSION_ID=writer-sess "$bridger" send reader ask "URGENT which db" >/dev/null 2>/dev/null)
  rm -f "$BRIDGER_ROOT/reported-reader-sess"
  mention=$(printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"reader-sess","tool_input":{"command":"grep -n \\"bridger register\\" README.md"}}' "$up/reader" | bash "$hook")
  jq -r '.hookSpecificOutput.additionalContext' <<<"$mention" | grep -q "URGENT which db" \
    || fail "a command that merely mentions 'bridger register' must not suppress delivery (got: $mention)"

  # And the claim must never be made for a session that is not registered at all.
  mkdir -p "$up/stranger"
  stranger=$(printf '{"hook_event_name":"PostToolUse","cwd":"%s","session_id":"stranger-sess","tool_input":{"command":"grep -n \\"bridger register\\" README.md"}}' "$up/stranger" | bash "$hook")
  [ -z "$stranger" ] \
    || fail "the hook claimed registration for an unregistered session (got: $stranger)"

  # A live watcher already delivers each message; a second copy is wasted context.
  (cd "$up/reader"; exec env BRIDGER_SESSION_ID=reader-sess "$bridger" wait --follow >/dev/null 2>&1) &
  w=$!
  await_listening reader || fail "watcher never came up for peer reader"
  [ -z "$(printf '%s' "$ups" | bash "$hook")" ] || fail "hook must stay silent while a watcher is listening"
  [ -z "$(printf '%s' "$ptu" | bash "$hook")" ] || fail "PostToolUse must stay silent while a watcher is listening"
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  # An unregistered session has no mailbox to report on.
  [ -z "$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","session_id":"nobody"}' "$up" | bash "$hook")" ] \
    || fail "hook must stay silent for an unregistered session"

  pass "delivery hooks surface unread mid-task and on turn, only when unwatched"
  rm -rf "$BRIDGER_ROOT" "$up"
)

# --- Stop hook: a registered session must not go idle deaf -------------------
# End of turn is where the watcher stops being optional: nothing else reaches
# an idle session. The hook cannot start it, so it blocks the turn once until
# the agent does — once, never a nag.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  st=$(mktemp -d); mkdir -p "$st/solo"
  hook="$here/hooks/stop.sh"
  payload='{"cwd":"'"$st/solo"'","session_id":"solo-sess","stop_hook_active":false}'

  [ -z "$(printf '%s' "$payload" | bash "$hook")" ] || fail "Stop must not block an unregistered session"

  (cd "$st/solo" && BRIDGER_SESSION_ID=solo-sess "$bridger" register solo >/dev/null)
  out=$(printf '%s' "$payload" | bash "$hook")
  [ "$(jq -r .decision <<<"$out")" = "block" ] || fail "Stop must block a registered, unwatched session (got: $out)"
  jq -r .reason <<<"$out" | grep -q "wait --follow" || fail "the block reason must name the command to run"

  # Once per session: an agent that ignores it still gets its turn back, and
  # falls through to the softer per-turn reminders instead of a hard loop.
  [ -z "$(printf '%s' "$payload" | bash "$hook")" ] || fail "Stop must block at most once per session"

  # A turn Claude Code is already continuing because of a stop hook.
  rm -f "$BRIDGER_ROOT/armed-nudge-solo-sess"
  [ -z "$(printf '{"cwd":"%s","session_id":"solo-sess","stop_hook_active":true}' "$st/solo" | bash "$hook")" ] \
    || fail "Stop must respect stop_hook_active"

  # Watcher armed: the session goes idle listening, nothing to enforce.
  rm -f "$BRIDGER_ROOT/armed-nudge-solo-sess"
  (cd "$st/solo"; exec env BRIDGER_SESSION_ID=solo-sess "$bridger" wait --follow >/dev/null 2>&1) &
  w=$!
  await_listening solo || fail "watcher never came up for peer solo"
  [ -z "$(printf '%s' "$payload" | bash "$hook")" ] || fail "Stop must not block once a watcher is listening"
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  pass "Stop hook blocks once until a registered session is actually listening"
  rm -rf "$BRIDGER_ROOT" "$st"
)

# --- log/mirror survive a corrupt message, exactly as poll does --------------
# poll was hardened to skip an unparseable message and keep going; log and
# mirror read the same files and must not be the readers that still stop dead.
# mirror's output is documented as a committable record, so a truncated one is
# worse than a loud failure: nothing in the FILE says it is short.
# Own root — these fixtures are deliberately corrupt and must not leak into the
# suite's shared state (the monitor block below asserts no warnings).
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  cr="$work/corrupt"; mkdir -p "$cr/a" "$cr/b"
  "$bridger" register ca "$cr/a" >/dev/null
  "$bridger" register cb "$cr/b" >/dev/null
  for i in 1 2 3; do (cd "$cr/a" && "$bridger" send cb ruling "d$i" >/dev/null); done
  td="$BRIDGER_ROOT/threads/ca--cb"

  # A genuine parse error: jq exits 5 and used to abort the whole read.
  printf 'NOT JSON{' > "$td/00002.json"
  out=$(cd "$cr/a" && "$bridger" log cb 2>/dev/null || true)
  grep -q 'd3' <<<"$out" || fail "log stops at an unparseable message, hiding every later one"
  out=$(cd "$cr/a" && "$bridger" mirror cb --types all 2>/dev/null || true)
  grep -q 'd3' <<<"$out" || fail "mirror truncates the record at an unparseable message"

  # jq exits 0 with NO output for a zero-byte/NUL/whitespace file, so the fields
  # come back empty and mirror used to print a section with every field blank —
  # exit 0, nothing on stderr, a phantom entry in a committed record.
  : > "$td/00002.json"
  out=$(cd "$cr/a" && "$bridger" mirror cb --types all 2>/dev/null || true)
  ! grep -qE '^## #[[:space:]]*$|^## #[[:space:]]+—' <<<"$out" \
    || fail "mirror emits a phantom empty section for a zero-byte message"
  grep -q 'd3' <<<"$out" || fail "mirror drops later messages after a zero-byte one"

  # The other half of the trade, and the one a "just skip bad files" rewrite
  # breaks: a message that is INTACT but momentarily unreadable (EACCES here; a
  # revoked mount or EIO in the wild) must stop the read, not be skipped. These
  # readers render history someone keeps — skipping burns a permanent hole into a
  # file that still looks complete. Root bypasses file permissions, so skip there.
  printf '{"seq":2,"from":"ca","to":"cb","type":"ruling","body":"d2","ts":"x"}' > "$td/00002.json"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$td/00002.json"
    out=$(cd "$cr/a" && "$bridger" log cb 2>/dev/null) && fail "log skips an unreadable message instead of refusing"
    ! grep -q 'd3' <<<"$out" || fail "log rendered past an unreadable message"
    chmod 644 "$td/00002.json"
  fi

  # A flag whose value is missing must be a usage error, not `$2: unbound variable`.
  err=$(cd "$cr/a" && "$bridger" mirror cb --types 2>&1 || true)
  ! grep -q 'unbound variable' <<<"$err" || fail "mirror --types with no value dies on set -u"
  grep -q 'usage:' <<<"$err" || fail "mirror --types with no value must print usage"

  pass "log/mirror survive corrupt messages and report missing flag values"
  rm -rf "$BRIDGER_ROOT"
)

# --- the watcher must never advance the cursor past mail it could not read ---
# unread_in_thread refuses to advance past a transiently unreadable message, and
# test.sh proves that through the CLI. The watcher reaches it by a different
# route: `out=$(cmd_poll)`. On bash 3.2 — what /usr/bin/env bash is on stock
# macOS — errexit is NOT inherited into a command substitution, so cmd_poll did
# not abort on the die and fell through to advance_cursor on the next line. The
# cursor jumped past the unreadable message AND everything behind it, while the
# peer went on advertising [listening]. Silent permanent loss on the only path
# that reaches an idle session, with the whole suite green.
if [ "$(id -u)" -ne 0 ]; then
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  ww="$work/watchloss"; mkdir -p "$ww/a" "$ww/b"
  "$bridger" register wsend "$ww/a" >/dev/null
  "$bridger" register wrecv "$ww/b" >/dev/null
  for m in one SECRET-two three; do
    (cd "$ww/a" && "$bridger" send wrecv chat "$m" >/dev/null 2>&1)
  done
  wtd="$BRIDGER_ROOT/threads/wrecv--wsend"
  [ -d "$wtd" ] || wtd="$BRIDGER_ROOT/threads/wsend--wrecv"
  chmod 000 "$wtd/00002.json"

  (cd "$ww/b"; exec "$bridger" wait --follow >/dev/null 2>&1) &
  wl=$!
  sleep 2
  kill "$wl" 2>/dev/null || true
  wait "$wl" 2>/dev/null || true
  chmod 644 "$wtd/00002.json"

  cur=$(cat "$wtd/cursor-wrecv" 2>/dev/null || echo 0)
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  [ "$cur" -lt 2 ] \
    || fail "the watcher advanced the cursor to $cur past an unreadable message — messages 2 and 3 are gone"

  # And once the fault clears, everything must still be deliverable.
  got=$(cd "$ww/b" && "$bridger" poll 2>/dev/null || true)
  grep -q "SECRET-two" <<<"$got" || fail "message 2 unrecoverable after the fault cleared (got: $got)"
  grep -q "three" <<<"$got" || fail "message 3 unrecoverable after the fault cleared (got: $got)"
  pass "the watcher wedges rather than destroying mail it could not read"
  rm -rf "$BRIDGER_ROOT"
)
fi

# --- wedging must not become an infinite replay of everything before it ------
# The first version of the fix above refused to advance the cursor AT ALL on a
# failed read. For a transient fault that is fine, but a permanent one (a
# DIRECTORY named NNNNN.json, a root-owned file — jq exits 2 and never stops
# doing so) then re-delivered every message before the fault on every 0.5s
# watcher tick, forever: measured at ~2 deliveries/second, and each line of
# watcher stdout re-invokes the agent. Trading silent loss for an unbounded
# replay storm is not a fix. The cursor must stop one short of the fault.
if [ "$(id -u)" -ne 0 ]; then
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  rp="$work/replay"; mkdir -p "$rp/a" "$rp/b"
  "$bridger" register rsend "$rp/a" >/dev/null
  "$bridger" register rrecv "$rp/b" >/dev/null
  (cd "$rp/a" && "$bridger" send rrecv chat before-the-fault >/dev/null 2>&1)
  rtd="$BRIDGER_ROOT/threads/rrecv--rsend"
  [ -d "$rtd" ] || rtd="$BRIDGER_ROOT/threads/rsend--rrecv"
  mkdir "$rtd/00002.json"          # permanent: jq can never read a directory
  (cd "$rp/a" && "$bridger" send rrecv chat behind-the-fault >/dev/null 2>&1)

  first=$(cd "$rp/b" && "$bridger" poll 2>/dev/null || true)
  grep -q "before-the-fault" <<<"$first" \
    || fail "the message before a permanent fault was never delivered (got: $first)"
  second=$(cd "$rp/b" && "$bridger" poll 2>/dev/null || true)
  grep -q "before-the-fault" <<<"$second" \
    && fail "a message before a permanent fault is re-delivered on every poll — replay storm"

  # The agent only ever sees stdout; the watcher's stderr reaches nobody. A
  # thread that will never deliver again has to say so on the channel that can
  # act on it — once per fault, not once per tick.
  grep -q "stuck at message 2" <<<"$first" \
    || fail "a permanently wedged thread said nothing on stdout (got: $first)"
  grep -q "stuck at message 2" <<<"$second" \
    && fail "the wedge notice repeats on every poll instead of once per fault"

  rmdir "$rtd/00002.json"
  third=$(cd "$rp/b" && "$bridger" poll 2>/dev/null || true)
  grep -q "behind-the-fault" <<<"$third" \
    || fail "the message behind the fault was lost once the fault cleared (got: $third)"
  pass "a permanent fault wedges once and replays nothing"
  rm -rf "$BRIDGER_ROOT"
)
fi

# --- one unreadable thread must not abort the whole --json poll --------------
# `unread_in_thread` signalled refusal with `die`, i.e. exit. In the render path
# it runs in a pipeline, so that only killed the subshell and the loop went on
# to the next peer. `poll --json` calls it WITHOUT a pipeline, so the same exit
# killed the entire process: every thread sorting after the faulty one was never
# polled at all. `ask` drains through `poll --json`, so a single unreadable file
# in one thread silently blinded it to every other peer.
if [ "$(id -u)" -ne 0 ]; then
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  jp="$work/jsonpoll"; mkdir -p "$jp/a" "$jp/b" "$jp/c"
  "$bridger" register jalice "$jp/a" >/dev/null
  "$bridger" register jbob   "$jp/b" >/dev/null
  "$bridger" register jcarol "$jp/c" >/dev/null
  (cd "$jp/a" && "$bridger" send jbob chat from-alice >/dev/null 2>&1)
  (cd "$jp/c" && "$bridger" send jbob chat from-carol >/dev/null 2>&1)
  jtd="$BRIDGER_ROOT/threads/jalice--jbob"
  chmod 000 "$jtd/00001.json"

  got=$(cd "$jp/b" && "$bridger" poll --json 2>/dev/null) && \
    fail "poll --json must report the unreadable thread with a nonzero exit"
  grep -q "from-carol" <<<"$got" \
    || fail "poll --json stopped at the unreadable thread and never served the others (got: $got)"
  chmod 644 "$jtd/00001.json"
  pass "poll --json serves every readable thread when one is unreadable"
  rm -rf "$BRIDGER_ROOT"
)
fi

# --- an empty BRIDGER_ROOT must refuse, never fall back to the real bus ------
# ${VAR:-default} treats set-but-empty as unset, so `BRIDGER_ROOT="" bridger
# register x` silently writes into ~/.claude/bridger — someone else's live bus.
# Unset is fine (that IS the default); explicitly empty is a caller bug.
#
# HOME is sandboxed for this block: on the UNFIXED code these commands really do
# create the fallback root, and a test that only fails after polluting the
# developer's own bus is not a test anyone can afford to run.
(
  fake_home=$(mktemp -d)
  out=$(HOME="$fake_home" BRIDGER_ROOT="" "$bridger" whoami 2>&1 || true)
  grep -q 'BRIDGER_ROOT' <<<"$out" \
    || fail "empty BRIDGER_ROOT silently falls back to \$HOME/.claude/bridger"
  if HOME="$fake_home" BRIDGER_ROOT="" "$bridger" register nope "$work/app" >/dev/null 2>&1; then
    fail "empty BRIDGER_ROOT still registers (into the fallback root)"
  fi
  [ ! -e "$fake_home/.claude/bridger" ] \
    || fail "empty BRIDGER_ROOT created the fallback root it should have refused"
  rm -rf "$fake_home"
)
pass "an empty BRIDGER_ROOT is refused, not silently defaulted"

# --- the watcher must never advance a cursor past a read it could not do -----
# unread_in_thread refuses to advance past a transiently unreadable message, and
# the block above proves it through the CLI. The WATCHER reaches the same code by
# a different route — `out=$(cmd_poll)` — and on bash 3.2 (what /usr/bin/env bash
# is on stock macOS) errexit is NOT inherited into a command substitution. So the
# failed read fell straight through to advance_cursor, skipping the unreadable
# message AND every message behind it, while the watcher kept beating and the
# peer kept reading [listening]: silent permanent loss on the only path that
# reaches an idle session. Exercised through `wait --follow`, because that is the
# caller the CLI test cannot reach.
if [ "$(id -u)" != "0" ]; then
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  ww="$work/watchloss"; mkdir -p "$ww/a" "$ww/b"
  "$bridger" register wa "$ww/a" >/dev/null
  "$bridger" register wb "$ww/b" >/dev/null
  for m in one SECRET-two three; do (cd "$ww/a" && "$bridger" send wb chat "$m" >/dev/null); done
  wt="$BRIDGER_ROOT/threads/wa--wb"
  chmod 000 "$wt/00002.json"
  (cd "$ww/b"; exec "$bridger" wait --follow >"$ww/out" 2>"$ww/err") &
  wpid=$!
  for _ in $(seq 1 150); do [ -s "$ww/err" ] && break; sleep 0.1; done
  cur=$(cat "$wt/cursor-wb" 2>/dev/null || echo 0)
  case "$cur" in ''|0|1) ;; *) kill "$wpid" 2>/dev/null; fail "watcher advanced the cursor to $cur past an unreadable message" ;; esac
  chmod 644 "$wt/00002.json"
  for _ in $(seq 1 150); do grep -q "SECRET-two" "$ww/out" && break; sleep 0.1; done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  grep -q "SECRET-two" "$ww/out" || fail "watcher never delivered the message once it became readable (got: $(cat "$ww/out"))"
  grep -q "three" "$ww/out" || fail "watcher lost the message BEHIND the unreadable one (got: $(cat "$ww/out"))"
  pass "the watcher wedges on an unreadable message and loses nothing"
  rm -rf "$BRIDGER_ROOT"
)
fi

# --- a stray non-numeric file must not wedge a thread in both directions -----
# The `[0-9]*.json` glob only anchors the first character, so a Finder duplicate
# ("00001 2.json"), an iCloud conflict copy or an editor artifact reaches the
# `$((10#…))` arithmetic and aborts it under set -e. max_seq is on the read AND
# the write path, so one such file killed poll and send together — silently,
# because the delivery hooks do `peers || exit 0`.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  sw="$work/strayfile"; mkdir -p "$sw/a" "$sw/b"
  "$bridger" register sa "$sw/a" >/dev/null
  "$bridger" register sb "$sw/b" >/dev/null
  (cd "$sw/a" && "$bridger" send sb chat one >/dev/null)
  st="$BRIDGER_ROOT/threads/sa--sb"
  cp "$st/00001.json" "$st/00001 2.json"; cp "$st/00001.json" "$st/00006x.json"; cp "$st/00001.json" "$st/0009-2.json"
  got=$(cd "$sw/b" && "$bridger" poll 2>/dev/null) || fail "a stray non-numeric file wedged poll"
  grep -q "one" <<<"$got" || fail "poll lost the real message next to a stray file (got: $got)"
  (cd "$sw/a" && "$bridger" send sb chat after >/dev/null 2>&1) || fail "a stray non-numeric file wedged send"
  pass "a stray non-numeric filename does not wedge poll or send"
  rm -rf "$BRIDGER_ROOT"
)

# --- send: a name is a PATH, so it must be validated like one ----------------
# valid_name gates `register`, but `send` only ran require_peer, which just tests
# that some <name>.json exists — which "../../elsewhere/package" satisfies. And
# the comma list was iterated unquoted, so it word-split AND globbed.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  nw="$work/sendname"; mkdir -p "$nw/a" "$nw/b" "$nw/victim"
  "$bridger" register na "$nw/a" >/dev/null
  "$bridger" register nb "$nw/b" >/dev/null
  echo '{}' > "$nw/victim/pwn.json"
  (cd "$nw/a" && "$bridger" send "../../../../../../../..$nw/victim/pwn" chat escaped >/dev/null 2>&1) \
    && fail "send accepted a traversal recipient"
  [ -z "$(find "$nw/victim" -name '*--*' 2>/dev/null)" ] || fail "send wrote a thread outside BRIDGER_ROOT"
  (cd "$nw/a" && "$bridger" send "./nb" chat dotslash >/dev/null 2>&1) \
    && fail "send accepted './nb', creating a second never-read thread"
  # Glob injection: ordinary files named like peers must not become recipients.
  (cd "$nw/a" && touch nb decoy && "$bridger" send "nosuch,*" chat globby >/dev/null 2>&1) \
    && fail "send with a glob in the recipient list reported success"
  [ -z "$(cd "$nw/b" && "$bridger" poll --peek 2>/dev/null)" ] \
    || fail "a globbed recipient received a message it was never addressed"
  # Partial and total fan-out failure must be visible in the exit status.
  (cd "$nw/a" && "$bridger" send nb,nosuch chat hi >/dev/null 2>&1) && fail "partial fan-out failure exited 0"
  (cd "$nw/a" && "$bridger" send nope1,nope2 chat hi >/dev/null 2>&1) && fail "total fan-out failure exited 0"
  (cd "$nw/a" && "$bridger" send nb chat fine >/dev/null 2>&1) || fail "a good send must still exit 0"
  # A bad --ref must be rejected before anything is written, not discovered by jq
  # after mktemp — which on the fan-out path committed a ZERO-BYTE message at a
  # real seq and still reported success.
  (cd "$nw/a" && "$bridger" send nb,nb chat body --ref abc >/dev/null 2>&1) && fail "a non-numeric --ref was accepted"
  [ -z "$(find "$BRIDGER_ROOT/threads" -name '[0-9]*.json' -size 0 2>/dev/null)" ] \
    || fail "a zero-byte message was committed at a real seq"
  for f in --ref --from; do
    (cd "$nw/a" && "$bridger" send nb chat hi "$f" 2>&1 | grep -q 'unbound variable') \
      && fail "send $f with no value leaks a raw bash error"
  done
  pass "send validates recipient names, never globs them, and reports fan-out failure"
  rm -rf "$BRIDGER_ROOT"
)

# --- ask: correlate on sender too, and never abandon a consumed batch --------
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  kw="$work/askfix"; mkdir -p "$kw/a" "$kw/b" "$kw/c"
  "$bridger" register ka "$kw/a" >/dev/null
  "$bridger" register kb "$kw/b" >/dev/null
  "$bridger" register kc "$kw/c" >/dev/null
  # cmd_poll --json consumes the WHOLE batch and moves every cursor before the
  # match is examined, so returning at the match dropped every later line in that
  # batch — never printed, not even to stderr. "Answer, then add a note" is the
  # ordinary pattern; the note vanished every time.
  (cd "$kw/a" && "$bridger" ask kb "q?" --timeout 20 >"$kw/out" 2>"$kw/err") &
  apid=$!
  for _ in $(seq 1 150); do [ -n "$(cd "$kw/b" && "$bridger" poll --peek 2>/dev/null)" ] && break; sleep 0.1; done
  (cd "$kw/b" && "$bridger" send ka answer "the-answer" --ref 1 >/dev/null 2>&1)
  (cd "$kw/b" && "$bridger" send ka chat "FOLLOWUP-NOTE" >/dev/null 2>&1)
  wait "$apid" 2>/dev/null || true
  grep -q "the-answer" "$kw/out" || fail "ask did not return the answer (got: $(cat "$kw/out"))"
  { grep -q "FOLLOWUP-NOTE" "$kw/err" || [ -n "$(cd "$kw/a" && "$bridger" poll --peek 2>/dev/null | grep FOLLOWUP-NOTE)" ]; } \
    || fail "ask destroyed the message that followed the answer in the same batch"
  # Seqs are per-thread, so a ref collision across threads is routine: a THIRD
  # peer's reply must not satisfy this ask.
  (cd "$kw/a" && "$bridger" poll >/dev/null 2>&1) || true
  (cd "$kw/a" && "$bridger" ask kb "real q" --timeout 4 >"$kw/out2" 2>/dev/null) &
  apid=$!
  for _ in $(seq 1 100); do [ -n "$(cd "$kw/b" && "$bridger" poll --peek 2>/dev/null)" ] && break; sleep 0.1; done
  (cd "$kw/c" && "$bridger" send ka answer "I-AM-KC" --ref 1 >/dev/null 2>&1)
  wait "$apid" 2>/dev/null || true
  ! grep -q "I-AM-KC" "$kw/out2" || fail "ask accepted a third peer's reply as the answer"
  (cd "$kw/a" && "$bridger" ask kb q --timeout 2>&1 | grep -q 'unbound variable') \
    && fail "ask --timeout with no value leaks a raw bash error"
  pass "ask matches on sender+ref and never abandons a consumed batch"
  rm -rf "$BRIDGER_ROOT"
)

# --- poll must not consume a zero-byte message as if it were nothing ---------
# jq exits 0 with no output on an empty file, which is indistinguishable from a
# good message addressed to somebody else — so poll swallowed it and advanced.
(
  BRIDGER_ROOT=$(mktemp -d); export BRIDGER_ROOT
  zw="$work/zerobyte"; mkdir -p "$zw/a" "$zw/b"
  "$bridger" register za "$zw/a" >/dev/null
  "$bridger" register zb "$zw/b" >/dev/null
  (cd "$zw/a" && "$bridger" send zb chat first >/dev/null)
  : > "$BRIDGER_ROOT/threads/za--zb/00001.json"
  (cd "$zw/a" && "$bridger" send zb chat real >/dev/null 2>&1)
  err=$( (cd "$zw/b" && "$bridger" poll >/dev/null) 2>&1 )
  grep -q "is empty" <<<"$err" || fail "poll consumed a zero-byte message silently (stderr: $err)"
  pass "poll reports a zero-byte message instead of swallowing it"
  rm -rf "$BRIDGER_ROOT"
)

# --- monitor: the web view reads what the CLI writes -------------------------
# The reader reimplements cursor and heartbeat semantics in Python, so it has
# its own self-check; this also points it at the root this suite just built, to
# catch the two sides drifting apart on the stored shape.
if command -v python3 >/dev/null 2>&1; then
  python3 "$here/monitor/server.py" --selftest >/dev/null || fail "monitor self-check"
  python3 - "$here/monitor" "$BRIDGER_ROOT" <<'PY' || fail "monitor cannot read a real BRIDGER_ROOT"
import sys
sys.path.insert(0, sys.argv[1])
from server import snapshot

state = snapshot(sys.argv[2])
names = {peer["name"] for peer in state["peers"]}
assert {"liba", "app"} <= names, names
assert state["metrics"]["messages"] > 0, state["metrics"]
assert state["threads"], "no threads parsed"
assert not state["warnings"], state["warnings"]
PY
  pass "monitor reads a real BRIDGER_ROOT"
else
  pass "monitor (skipped: no python3)"
fi

echo "PASS: all bridger self-checks green"
