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

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

mkdir -p "$work/liba/sub" "$work/app"

# --- register + whoami ------------------------------------------------------
"$bridger" register liba "$work/liba" >/dev/null
"$bridger" register app "$work/app" >/dev/null

[ "$(cd "$work/liba" && "$bridger" whoami)" = "liba" ] || fail "whoami exact cwd"
[ "$(cd "$work/liba/sub" && "$bridger" whoami)" = "liba" ] || fail "whoami subdirectory"
[ "$(cd "$work/app" && "$bridger" whoami)" = "app" ] || fail "whoami second peer"
if (cd /tmp && "$bridger" whoami >/dev/null 2>&1); then fail "whoami matches unregistered dir"; fi
if "$bridger" register "bad--name" "$work" >/dev/null 2>&1; then fail "register accepts '--' in name"; fi
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
[ "$(cd "$disc/plain" && "$bridger" peers --dir | grep -c .)" = "1" ] || fail "--dir scopes to this directory"
(cd "$disc/plain" && "$bridger" summary "still building") >/dev/null
grep -q "still building" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "summary is updatable"
pass "peers listing, summaries, and --dir scope"

# A running watcher marks its peer "listening"; a stopped one drops back to
# "queued" — via its own trap, and via the offline command the end-of-session
# hook calls. exec so the PID is the watcher itself and the trap can fire.
(cd "$disc/plain"; exec "$bridger" wait --follow >/dev/null 2>&1) &
watcher=$!
sleep 3
grep -q "plain \[listening\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "watcher must mark peer listening"
kill "$watcher" 2>/dev/null || true
wait "$watcher" 2>/dev/null || true
grep -q "plain \[queued\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "stopped watcher must fall back to queued"

# A watcher killed without a chance to clean up: the beat goes stale on its own.
: > "$BRIDGER_ROOT/peers/plain.beat"
touch -t 202001010000 "$BRIDGER_ROOT/peers/plain.beat"
grep -q "plain \[queued\]" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "stale heartbeat must read as queued"
(cd "$disc/plain" && "$bridger" offline)
[ ! -e "$BRIDGER_ROOT/peers/plain.beat" ] || fail "offline must clear the heartbeat"
pass "heartbeat: listening while watched, queued when stopped or stale"

# Re-registering must not erase what the peer said it was doing, and must
# record the current session id when the hook provides one.
(cd "$disc/plain" && BRIDGER_SESSION_ID=sess-abc123 "$bridger" autoregister >/dev/null)
grep -q "still building" <<<"$(cd "$disc/plain" && "$bridger" peers --dir)" || fail "autoregister must preserve summary"
[ "$(jq -r .session "$BRIDGER_ROOT/peers/plain.json")" = "sess-abc123" ] || fail "peer must record its session id"
(cd "$disc/plain" && "$bridger" autoregister >/dev/null)
[ "$(jq -r .session "$BRIDGER_ROOT/peers/plain.json")" = "sess-abc123" ] || fail "session id must survive refresh without one"
pass "re-registration preserves peer metadata and tracks the session id"

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
# Two checkouts of one project: each auto-registers from its directory name,
# then takes an explicit role name. The rename must be clean, not additive.
mkdir -p "$disc/proj" "$disc/proj-worktree"
derived=$(cd "$disc/proj" && "$bridger" autoregister)
(cd "$disc/proj-worktree" && "$bridger" autoregister >/dev/null)
(cd "$disc/proj" && "$bridger" register lead >/dev/null)
(cd "$disc/proj-worktree" && "$bridger" register worker >/dev/null)
[ "$(cd "$disc/proj" && "$bridger" whoami)" = "lead" ] || fail "explicit name must win over the derived one"
[ "$(cd "$disc/proj-worktree" && "$bridger" whoami)" = "worker" ] || fail "second checkout keeps its own identity"
[ ! -f "$BRIDGER_ROOT/peers/$derived.json" ] || fail "derived name must be replaced, not kept alongside"
[ "$(cd "$disc/proj" && "$bridger" peers --dir | grep -c .)" = "1" ] || fail "one identity per directory"
(cd "$disc/proj" && "$bridger" send worker chat "roles work" >/dev/null)
[ "$(cd "$disc/proj-worktree" && "$bridger" poll)" = "#1 lead chat: roles work" ] || fail "renamed peers can talk"

# Once a name has history, silently renaming it would orphan the thread.
if (cd "$disc/proj" && "$bridger" register lead-2 >/dev/null 2>&1); then
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
(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-1 "$bridger" register worker >/dev/null)
# A live holder (a running watcher keeps the heartbeat fresh) refuses a 2nd claim.
(cd "$disc/role"; exec env CLAUDE_CODE_SESSION_ID=sess-1 "$bridger" wait --follow >/dev/null 2>&1) &
watcher=$!
sleep 3
if (cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" register worker >/dev/null 2>&1); then
  kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
  fail "a name held by a live session must be refused"
fi
kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
# Holder gone (heartbeat forced stale): a second session reclaims the name.
: > "$BRIDGER_ROOT/peers/worker.beat"; touch -t 202001010000 "$BRIDGER_ROOT/peers/worker.beat"
(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" register worker >/dev/null) \
  || fail "a dead holder's name must be reclaimable"
[ "$(cd "$disc/role" && CLAUDE_CODE_SESSION_ID=sess-2 "$bridger" whoami)" = "worker" ] \
  || fail "takeover must bind the name to the reclaiming session"
pass "same name: live holder refused, dead holder taken over"

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
pass "log + status"

# --- statusline badge + drop-in wiring ---------------------------------------
# Fully isolated: its own BRIDGER_ROOT (badge state) and CLAUDE_CONFIG_DIR
# (settings.json + statusline.d), so it never touches the real ~/.claude.
(
  badge="$here/hooks/statusline.sh"
  BRIDGER_ROOT=$(mktemp -d); cfg=$(mktemp -d); sw=$(mktemp -d)
  export BRIDGER_ROOT
  export CLAUDE_CONFIG_DIR="$cfg"
  mkdir -p "$sw/proj"

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
  [ "$clean" = "[⇄ BRIDGER:bad31mXY]" ] || fail "badge must strip to a safe charset (got: $(printf %q "$clean"))"
  pass "badge sanitizes crafted names (no ANSI/control-char injection)"

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

  rm -rf "$BRIDGER_ROOT" "$cfg" "$sw"
)

echo "PASS: all bridger self-checks green"
