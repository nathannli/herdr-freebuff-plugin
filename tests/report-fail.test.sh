# Tests for the watcher's behaviour when it loses the herdr server.
#
# Regression: every herdr call in the watcher ended in >/dev/null 2>&1, so a
# watcher talking to a dead server was indistinguishable from a pane with no
# plugin installed. It polled forever, wrote nothing anywhere unless
# FREEBUFF_DEBUG was set, and never exited, so nothing could re-attach it.
. "$(dirname "$0")/lib.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHER_SCRIPT="$PROJECT_ROOT/scripts/status-watcher.sh"

teardown_watcher() {
  for _pid in ${LIVE_FAKES:-}; do
    kill "$_pid" 2>/dev/null
  done
  # Reap only the processes this suite started. A bare `wait` would block on
  # anything else the runner left running.
  for _pid in ${LIVE_FAKES:-}; do
    wait "$_pid" 2>/dev/null
  done
  LIVE_FAKES=""
  [ -n "${FAKEHOME:-}" ] && rm -rf "$FAKEHOME"
  unset HOME HERDR_CALL_LOG HERDR_PLUGIN_STATE_DIR HERDR_STUB_CONTENT_FILE \
    HERDR_STUB_PANE_PIDS HERDR_STUB_PANE_CWD HERDR_STUB_FAIL_REPORT \
    FREEBUFF_REPORT_FAILURE_LIMIT FREEBUFF_HEARTBEAT_POLLS FREEBUFF_DEBUG
  FAKEHOME=""; WATCHER_PID=""; FAKE_FB_PID=""
}

# A watcher that gives up must leave no pidfile and no seq file behind, because
# attach-watches.sh reads exactly those to decide whether a pane still has a
# live watcher. Leftover state would block the re-attach that this exit exists
# to trigger.
setup_watcher() {
  # Sweep first: this suite calls setup more than once, and a fake from the
  # previous case would otherwise outlive it holding the inherited stdout open,
  # hanging the caller on a pipe nothing writes to.
  teardown_watcher
  FAKEHOME=$(mktemp -d)
  mkdir -p "$FAKEHOME/.config/manicode/projects/test-project/chats" "$FAKEHOME/bin"
  ln -sf "$PROJECT_ROOT/tests/fixtures/herdr-stub.sh" "$FAKEHOME/bin/herdr"
  ln -sf "$PROJECT_ROOT/tests/fixtures/bin/freebuff" "$FAKEHOME/bin/freebuff"

  export HOME="$FAKEHOME"
  export HERDR_CALL_LOG="$FAKEHOME/herdr-calls.log"
  : > "$HERDR_CALL_LOG"
  export HERDR_PLUGIN_STATE_DIR="$FAKEHOME/state"
  mkdir -p "$HERDR_PLUGIN_STATE_DIR"
  export HERDR_STUB_CONTENT_FILE="$FAKEHOME/pane-content.txt"
  : > "$HERDR_STUB_CONTENT_FILE"

  # Stand in for a live freebuff process.
  #
  # Every fake is tracked because this suite calls setup_watcher more than once.
  # An untracked one would outlive the suite holding the inherited stdout open,
  # and the caller would hang waiting on a pipe nothing writes to.
  (
    trap 'exit 0' TERM INT
    while true; do sleep 1; done
  ) &
  FAKE_FB_PID=$!
  LIVE_FAKES="${LIVE_FAKES:-} $FAKE_FB_PID"

  export HERDR_STUB_PANE_PIDS="$FAKE_FB_PID"
  export HERDR_STUB_PANE_CWD="/tmp/test-project"

  # An idle chat dir pinned to the fake freebuff pid, so the watcher settles on
  # idle and starts reporting.
  make_fake_chat "$FAKEHOME/.config/manicode/projects/test-project/chats/2026-01-01T00-00-00.000Z" \
    "idle" "$FAKE_FB_PID"

  DEBUG_LOG="$FAKEHOME/state/watcher-p1.log"
  PANE_ID="p1"
}

# Wait for the watcher to exit on its own, up to ~25s.
wait_for_exit() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    kill -0 "$WATCHER_PID" 2>/dev/null || return 0
    sleep 0.5
    _i=$(( _i + 1 ))
  done
  return 1
}

t_title "watcher: gives up loudly when report-agent keeps failing"
setup_watcher
# Limit of 3 with a 1-poll heartbeat keeps the test short. FREEBUFF_DEBUG is
# deliberately NOT set: the whole point is that the failure is reported without
# the user having known to turn debugging on.
HERDR_STUB_FAIL_REPORT=1 \
FREEBUFF_REPORT_FAILURE_LIMIT=3 \
FREEBUFF_HEARTBEAT_POLLS=1 \
HERDR_ENV=1 HERDR_PANE_ID="$PANE_ID" HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
HERDR_BIN_PATH="$FAKEHOME/bin/herdr" \
  sh "$WATCHER_SCRIPT" "$FAKE_FB_PID" "$PANE_ID" 0 >"$FAKEHOME/watcher-stderr.log" 2>&1 &
WATCHER_PID=$!
LIVE_FAKES="$LIVE_FAKES $WATCHER_PID"

if wait_for_exit; then
  t_pass "watcher exits after repeated report failures instead of polling forever"
else
  t_fail "watcher should exit after 3 consecutive report failures (stderr: $(cat "$FAKEHOME/watcher-stderr.log" 2>&1))"
  kill "$WATCHER_PID" 2>/dev/null
fi

if [ ! -f "$DEBUG_LOG" ]; then
  t_fail "watcher wrote no log at all; stderr: $(cat "$FAKEHOME/watcher-stderr.log" 2>&1)"
else
  t_file_contains "$DEBUG_LOG" "report-agent FAILED" \
    "failure written to the watcher log without FREEBUFF_DEBUG"
fi
t_file_contains "$DEBUG_LOG" "giving up on pane $PANE_ID" \
  "log names the pane the watcher abandoned"
if grep -q "report-agent recovered" "$DEBUG_LOG" 2>/dev/null; then
  t_fail "logged a recovery that never happened"
else
  t_pass "no bogus recovery logged when every report failed"
fi

t_title "watcher: clears per-pane state on give-up so a re-attach can happen"
if [ -f "$FAKEHOME/state/seq-$PANE_ID" ]; then
  t_fail "seq file left behind; attach-watches.sh would treat the pane as watched"
else
  t_pass "seq file removed on give-up"
fi
if [ -f "$FAKEHOME/state/watch-$PANE_ID.pid" ]; then
  t_fail "pidfile left behind; the sweep would skip re-attaching this pane"
else
  t_pass "pidfile removed on give-up"
fi

t_title "watcher: keeps reporting and does not exit when herdr is healthy"
setup_watcher
# A generous failure limit and a slow heartbeat: if this watcher exits anyway,
# something is giving up on a server that is answering.
FREEBUFF_REPORT_FAILURE_LIMIT=3 \
FREEBUFF_HEARTBEAT_POLLS=1 \
HERDR_ENV=1 HERDR_PANE_ID="$PANE_ID" HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
HERDR_BIN_PATH="$FAKEHOME/bin/herdr" \
  sh "$WATCHER_SCRIPT" "$FAKE_FB_PID" "$PANE_ID" 0 >/dev/null 2>&1 &
WATCHER_PID=$!
LIVE_FAKES="$LIVE_FAKES $WATCHER_PID"
sleep 8
if kill -0 "$WATCHER_PID" 2>/dev/null; then
  t_pass "watcher stays alive against a healthy server"
else
  t_fail "watcher exited against a healthy server"
fi
if grep -qF -- "--state idle" "$HERDR_CALL_LOG" 2>/dev/null; then
  t_pass "healthy watcher still reports state"
else
  t_fail "healthy watcher stopped reporting (log: $(cat "$HERDR_CALL_LOG"))"
fi
if [ -f "$DEBUG_LOG" ] && grep -q "report-agent FAILED" "$DEBUG_LOG" 2>/dev/null; then
  t_fail "healthy watcher logged a report failure (log: $(cat "$DEBUG_LOG"))"
else
  t_pass "healthy watcher logs no report failures"
fi

t_title "watcher: heartbeats an unchanged state so a dead server is noticed"
# The failure counter only advances when a report is attempted. With no
# heartbeat, a pane that sits idle against a dead server never attempts a
# report and never discovers the server is gone.
if [ "$(grep -cF -- "--source custom:freebuff" "$HERDR_CALL_LOG" 2>/dev/null)" -ge 3 ]; then
  t_pass "unchanged idle state is re-reported (heartbeat working)"
else
  t_fail "no heartbeat: only one report made for an unchanged state (log: $(cat "$HERDR_CALL_LOG"))"
fi

teardown_watcher
summary
