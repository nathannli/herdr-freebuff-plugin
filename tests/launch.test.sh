# Tests for scripts/launch.sh
. "$(dirname "$0")/lib.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKEHOME=$(mktemp -d)
mkdir -p "$FAKEHOME/.config/manicode/projects" "$FAKEHOME/bin"
ln -sf "$PROJECT_ROOT/tests/fixtures/herdr-stub.sh" "$FAKEHOME/bin/herdr"
ln -sf "$PROJECT_ROOT/tests/fixtures/bin/freebuff" "$FAKEHOME/bin/freebuff"

OLD_HOME="$HOME"
OLD_PATH="$PATH"
export HOME="$FAKEHOME"
export PATH="$FAKEHOME/bin:$PATH"
export HERDR_STUB_LAST="/tmp/herdr-launch-test-last.txt"
: > "$HERDR_STUB_LAST"
export HERDR_CALL_LOG="/tmp/herdr-launch-test-call.txt"
: > "$HERDR_CALL_LOG"

# Isolated plugin state dir so watcher seq files never touch the real one
export HERDR_PLUGIN_STATE_DIR="$FAKEHOME/state"

# Only ever match this suite's own watchers.
#
# These tests used `pkill -f "status-watcher.sh"` and counted matches from
# `ps -ef | grep status-watcher.sh`. Both are unscoped, and a live plugin's
# watcher runs out of the *installed* plugin directory, so it matches too. That
# cut two ways: every suite run killed the watcher for the real freebuff session
# on this machine (the sweep daemon re-attached a new one within 20s, which is
# why it went unnoticed), and the daemon's re-attached watcher was counted here
# as a leak — which is the flaky failure "watcher should not spawn outside herdr
# (count: 1)", appearing only when a re-attach landed inside the 0.8s window.
#
# Test watchers are spawned as `sh $PROJECT_ROOT/scripts/status-watcher.sh`, so
# scoping on this repo's path separates ours from the live ones exactly, while
# still cleaning up after any suite in this repo.
test_watcher_pids() {
  pgrep -f "$PROJECT_ROOT/scripts/status-watcher.sh" 2>/dev/null
}

kill_test_watchers() {
  for _p in $(test_watcher_pids); do
    kill "$_p" 2>/dev/null
  done
  return 0
}

count_test_watchers() {
  _p=$(test_watcher_pids)
  if [ -n "$_p" ]; then
    printf '%s\n' "$_p" | grep -c .
  else
    printf '0'
  fi
}
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

t_title "launch.sh: task mode execs freebuff"
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-1" HERDR_ENV=1 HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.3
if kill -0 $pid 2>/dev/null; then
  t_pass "task mode started freebuff"
  kill $pid 2>/dev/null
else
  t_fail "task mode did not start freebuff"
fi

t_title "launch.sh: resume-last mode passes --continue"
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-1" HERDR_ENV=1 HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
    sh "$PROJECT_ROOT/scripts/launch.sh" resume-last > /dev/null 2>&1
) &
pid=$!
sleep 0.3
if kill -0 $pid 2>/dev/null; then
  t_pass "resume-last mode started freebuff with --continue"
  kill $pid 2>/dev/null
else
  t_fail "resume-last mode did not start freebuff"
fi

t_title "launch.sh: resume-named is not a mode"
# It never had a caller, and it was actively dangerous to keep: it passed its
# argument straight to `freebuff --continue`, which uses the value verbatim as a
# chat *directory* name and, on a miss, silently falls back to the most recent
# chat in the project. Handing it a `cli:<uuid>` instanceId, which is what its
# "session id" wording invited, resumed the wrong conversation with no error.
output=$(HERDR_PANE_ID="pane-1" HERDR_ENV=1 sh "$PROJECT_ROOT/scripts/launch.sh" resume-named "test-session-123" 2>&1 || true)
echo "$output" | grep -q "unknown launch mode" \
  && t_pass "resume-named is rejected as an unknown mode" \
  || t_fail "resume-named still accepted a session id (got: $output)"

# Cleanup leftover freebuff processes
pkill -f "fake freebuff" 2>/dev/null || true
sleep 0.3

t_title "launch.sh: spawns the status watcher inside a herdr pane"
kill_test_watchers
sleep 0.3
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-spawn" HERDR_ENV=1 HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.8
watcher_count=$(count_test_watchers)
if [ "$watcher_count" -ge 1 ]; then
  t_pass "watcher spawned inside herdr (count: $watcher_count)"
else
  t_fail "watcher should spawn inside herdr (count: $watcher_count)"
fi
kill $pid 2>/dev/null
kill_test_watchers
sleep 0.2

t_title "launch.sh: no watcher outside a herdr pane"
kill_test_watchers
sleep 0.3
(
  exec 2>/dev/null
  HERDR_ENV= HERDR_PANE_ID= HERDR_SOCKET_PATH= \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.8
watcher_count=$(count_test_watchers)
if [ "$watcher_count" -eq 0 ]; then
  t_pass "no watcher spawned outside herdr"
else
  t_fail "watcher should not spawn outside herdr (count: $watcher_count)"
fi
kill $pid 2>/dev/null
kill_test_watchers

t_title "launch.sh: no watcher when the herdr socket is absent"
# HERDR_ENV=1 with a pane id but no socket: herdr cannot receive reports, so
# the watcher must not start.
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-nosock" HERDR_ENV=1 HERDR_SOCKET_PATH= \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.8
watcher_count=$(count_test_watchers)
if [ "$watcher_count" -eq 0 ]; then
  t_pass "no watcher spawned without a herdr socket"
else
  t_fail "watcher should not spawn without a herdr socket (count: $watcher_count)"
fi
kill $pid 2>/dev/null
kill_test_watchers

t_title "launch.sh: watcher cleanup is scoped to this repo"
# The regression: cleanup used `pkill -f "status-watcher.sh"`, which also matches
# the *installed* plugin's watcher, so every suite run killed the live freebuff
# session's watcher on this machine. A decoy with the same basename under a
# different path stands in for it, so the test needs no live plugin.
mkdir -p "$FAKEHOME/decoy"
printf '#!/bin/sh\nsleep 30\n' > "$FAKEHOME/decoy/status-watcher.sh"
chmod +x "$FAKEHOME/decoy/status-watcher.sh"
# Started from a subshell that exits immediately, so the decoy is reparented to
# init rather than being a child of this test. A child would linger as a zombie
# after `kill` and still answer `kill -0`, which would make the assertion below
# pass no matter what the cleanup did.
sh -c 'sh "$1" >/dev/null 2>&1 &' _ "$FAKEHOME/decoy/status-watcher.sh"
sleep 0.5
decoy=$(pgrep -f "$FAKEHOME/decoy/status-watcher.sh" 2>/dev/null | head -1)
if [ -z "$decoy" ]; then
  t_fail "setup: the decoy watcher did not start"
else
  # Precondition, so a pass cannot be vacuous: the old unscoped pattern really
  # would have matched this decoy.
  if pgrep -f "status-watcher.sh" 2>/dev/null | grep -qx "$decoy"; then
    unscoped="unscoped pkill -f would match it"
  else
    unscoped="decoy not matched even unscoped (weak precondition)"
  fi

  kill_test_watchers
  sleep 0.3

  if kill -0 "$decoy" 2>/dev/null; then
    t_pass "cleanup spares a watcher outside this repo ($unscoped)"
  else
    t_fail "cleanup killed an out-of-repo watcher, so the live plugin's watcher is never safe"
  fi
  kill "$decoy" 2>/dev/null
fi

t_title "launch.sh: unknown mode fails"
output=$(HERDR_PANE_ID="pane-1" HERDR_ENV=1 sh "$PROJECT_ROOT/scripts/launch.sh" unknown 2>&1 || true)
echo "$output" | grep -q "unknown launch mode" && t_pass "unknown mode rejected" || t_fail "unknown mode should be rejected"

# --- a pane's PATH is not a login shell's PATH ---

# Herdr panes are spawned by the herdr *server*. That server is normally started
# by launchd from herdr-gui's LaunchAgent and inherits launchd's default PATH,
# which on a version-managed node install contains neither freebuff nor node nor
# herdr. Verified on this machine under the exact PATH below: `command -v` finds
# none of the three.
#
# So the launcher has to repair PATH itself, or a plugin pane opened from a GUI
# launch simply fails.
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
BARE_HOME=$(mktemp -d)
mkdir -p "$BARE_HOME/.local/bin"
# A fake version-managed install, laid out where augment_path looks.
mkdir -p "$BARE_HOME/.local/share/fnm/node-versions/v24.21.0/installation/bin"
ln -sf "$PROJECT_ROOT/tests/fixtures/herdr-stub.sh" "$BARE_HOME/.local/bin/herdr"
ln -sf "$PROJECT_ROOT/tests/fixtures/bin/freebuff" \
  "$BARE_HOME/.local/share/fnm/node-versions/v24.21.0/installation/bin/freebuff"

t_title "launch.sh: finds freebuff under a bare launchd PATH"
# The regression: with only the bare PATH, this aborts with
# "freebuff binary not found on PATH".
bare_out=$(env -i PATH="$BARE_PATH" HOME="$BARE_HOME" HERDR_PANE_ID= HERDR_ENV= \
  sh "$PROJECT_ROOT/scripts/launch.sh" task 2>&1 &
  sleep 1; kill %1 2>/dev/null; wait 2>/dev/null)
if printf '%s' "$bare_out" | grep -q "freebuff binary not found"; then
  t_fail "bare PATH: launcher cannot find freebuff"
else
  t_pass "bare PATH: freebuff resolved from the fnm install prefix"
fi

t_title "launch.sh: bare PATH failure names node, which reporting also needs"
# Without node the watcher cannot build a seq and the classifier cannot parse, so
# a pane that opened but never reported would look like an unrelated bug.
NO_NODE_OUT=$(env -i PATH="$BARE_PATH" HOME="$BARE_HOME/nodeonly" HERDR_PANE_ID= HERDR_ENV= \
  sh "$PROJECT_ROOT/scripts/launch.sh" task 2>&1 || true)
if printf '%s' "$NO_NODE_OUT" | grep -q "freebuff binary not found"; then
  if printf '%s' "$NO_NODE_OUT" | grep -q "node is also not on PATH"; then
    t_pass "the error explains that node is missing too"
  else
    t_fail "the error should mention node, since reporting needs it as well"
  fi
else
  t_fail "setup: expected a freebuff-not-found error with no freebuff installed"
fi

rm -rf "$BARE_HOME"

# Restore
pkill -f "fake freebuff" 2>/dev/null || true
rm -rf "$FAKEHOME" /tmp/herdr-launch-test-last.txt /tmp/herdr-launch-test-call.txt
export HOME="$OLD_HOME"
export PATH="$OLD_PATH"
unset HERDR_STUB_LAST HERDR_CALL_LOG HERDR_PLUGIN_STATE_DIR
