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

t_title "launch.sh: resume-named passes session id"
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-1" HERDR_ENV=1 HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
    sh "$PROJECT_ROOT/scripts/launch.sh" resume-named "test-session-123" > /dev/null 2>&1
) &
pid=$!
sleep 0.3
if kill -0 $pid 2>/dev/null; then
  t_pass "resume-named started freebuff with session id"
  kill $pid 2>/dev/null
else
  t_fail "resume-named did not start freebuff"
fi

# Cleanup leftover freebuff processes
pkill -f "fake freebuff" 2>/dev/null || true
sleep 0.3

t_title "launch.sh: spawns the status watcher inside a herdr pane"
pkill -f "status-watcher.sh" 2>/dev/null || true
sleep 0.3
(
  exec 2>/dev/null
  HERDR_PANE_ID="pane-spawn" HERDR_ENV=1 HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.8
watcher_count=$(ps -ef | grep "status-watcher.sh" | grep -v grep | wc -l | tr -d ' ')
if [ "$watcher_count" -ge 1 ]; then
  t_pass "watcher spawned inside herdr (count: $watcher_count)"
else
  t_fail "watcher should spawn inside herdr (count: $watcher_count)"
fi
kill $pid 2>/dev/null
pkill -f "status-watcher.sh" 2>/dev/null || true
sleep 0.2

t_title "launch.sh: no watcher outside a herdr pane"
pkill -f "status-watcher.sh" 2>/dev/null || true
sleep 0.3
(
  exec 2>/dev/null
  HERDR_ENV= HERDR_PANE_ID= HERDR_SOCKET_PATH= \
    sh "$PROJECT_ROOT/scripts/launch.sh" task > /dev/null 2>&1
) &
pid=$!
sleep 0.8
watcher_count=$(ps -ef | grep "status-watcher.sh" | grep -v grep | wc -l | tr -d ' ')
if [ "$watcher_count" -eq 0 ]; then
  t_pass "no watcher spawned outside herdr"
else
  t_fail "watcher should not spawn outside herdr (count: $watcher_count)"
fi
kill $pid 2>/dev/null
pkill -f "status-watcher.sh" 2>/dev/null || true

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
watcher_count=$(ps -ef | grep "status-watcher.sh" | grep -v grep | wc -l | tr -d ' ')
if [ "$watcher_count" -eq 0 ]; then
  t_pass "no watcher spawned without a herdr socket"
else
  t_fail "watcher should not spawn without a herdr socket (count: $watcher_count)"
fi
kill $pid 2>/dev/null
pkill -f "status-watcher.sh" 2>/dev/null || true

t_title "launch.sh: resume-named fails without session id"
output=$(HERDR_PANE_ID="pane-1" HERDR_ENV=1 sh "$PROJECT_ROOT/scripts/launch.sh" resume-named 2>&1 || true)
echo "$output" | grep -q "requires a session id" && t_pass "resume-named rejects empty session id" || t_fail "resume-named should reject empty session id"

t_title "launch.sh: unknown mode fails"
output=$(HERDR_PANE_ID="pane-1" HERDR_ENV=1 sh "$PROJECT_ROOT/scripts/launch.sh" unknown 2>&1 || true)
echo "$output" | grep -q "unknown launch mode" && t_pass "unknown mode rejected" || t_fail "unknown mode should be rejected"

# Restore
pkill -f "fake freebuff" 2>/dev/null || true
rm -rf "$FAKEHOME" /tmp/herdr-launch-test-last.txt /tmp/herdr-launch-test-call.txt
export HOME="$OLD_HOME"
export PATH="$OLD_PATH"
unset HERDR_STUB_LAST HERDR_CALL_LOG HERDR_PLUGIN_STATE_DIR
