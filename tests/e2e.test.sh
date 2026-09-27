# End-to-end test: fake freebuff + status-watcher + herdr-stub
. "$(dirname "$0")/lib.sh"

# Resolve absolute paths before any cd
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKEHOME=$(mktemp -d)
mkdir -p "$FAKEHOME/.config/manicode/projects/test-project/chats" "$FAKEHOME/bin"
ln -sf "$PROJECT_ROOT/tests/fixtures/herdr-stub.sh" "$FAKEHOME/bin/herdr"
ln -sf "$PROJECT_ROOT/tests/fixtures/bin/freebuff" "$FAKEHOME/bin/freebuff"

OLD_HOME="$HOME"
OLD_PWD="$PWD"
OLD_PATH="$PATH"
export HOME="$FAKEHOME"
export PATH="$FAKEHOME/bin:$PATH"
export HERDR_CALL_LOG="/tmp/herdr-e2e-call-log.txt"
: > "$HERDR_CALL_LOG"
export HERDR_STUB_LAST="/tmp/herdr-e2e-last.txt"
: > "$HERDR_STUB_LAST"

# Keep watcher seq files out of the real plugin state dir
export HERDR_PLUGIN_STATE_DIR="$FAKEHOME/state"
mkdir -p "$HERDR_PLUGIN_STATE_DIR"

# Shared content file for the pane-stub: the e2e test updates this file
# per-phase to simulate different on-screen states. The watcher's stub
# reads from this file each time it runs `herdr pane read`.
E2E_PANE_CONTENT="/tmp/herdr-e2e-pane-content.txt"
export HERDR_STUB_CONTENT_FILE="$E2E_PANE_CONTENT"
: > "$E2E_PANE_CONTENT"

PROJECT_DIR="/tmp/test-project"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

CHATS_DIR="$FAKEHOME/.config/manicode/projects/test-project/chats"

# A real freebuff session writes to ONE chat dir for its whole life. The
# watcher pins that dir at startup and never re-resolves, so this test models
# the session by rewriting the same dir's contents as the turn progresses.
# Start a fake "freebuff" to monitor (just a sleep loop)
(
  trap 'exit 0' TERM INT
  while true; do sleep 1; done
) &
FAKE_FB_PID=$!

# Pinning is by writer pid: the chat log must be stamped with this pid, and the
# stub must report the same pid from `pane process-info`.
export HERDR_STUB_PANE_PIDS="$FAKE_FB_PID"

CHAT="$CHATS_DIR/2026-01-01T00-00-00.000Z"
make_fake_chat "$CHAT" "idle" "$FAKE_FB_PID"

WATCHER_SCRIPT="$PROJECT_ROOT/scripts/status-watcher.sh"

# Clear the call log and give the watcher time to act. Each phase asserts only
# against reports made after the reset, so a state reported in an earlier phase
# can never satisfy a later assertion.
settle() {
  : > "$HERDR_CALL_LOG"
  sleep 3
}

assert_state() {
  expected="$1"
  msg="$2"
  if grep -qF -- "--state $expected" "$HERDR_CALL_LOG" 2>/dev/null; then
    t_pass "$msg"
  else
    t_fail "$msg (log: $(cat "$HERDR_CALL_LOG"))"
  fi
}

t_title "e2e: watcher starts and reports idle"
HERDR_ENV=1 HERDR_PANE_ID="e2e-pane" HERDR_SOCKET_PATH="$FAKEHOME/herdr.sock" \
  HERDR_BIN_PATH="$FAKEHOME/bin/herdr" HERDR_STUB_PANE_CWD="/tmp/test-project" \
  nohup sh "$WATCHER_SCRIPT" "$FAKE_FB_PID" "e2e-pane" \
  > /dev/null 2>&1 &
WATCHER_PID=$!
settle
assert_state idle "watcher reported idle on start"

t_title "e2e: watcher reports working when the turn starts"
make_fake_chat "$CHAT" "working" "$FAKE_FB_PID"
settle
assert_state working "watcher reported working"

t_title "e2e: watcher reports blocked when ask-user pending"
# Simulate the ask_user popup on screen (needed now that classify validates
# screen confirms popup before returning blocked with a stale-file fallback)
cat "$PROJECT_ROOT/tests/fixtures/pane-ask-user.txt" > "$E2E_PANE_CONTENT"
make_fake_chat "$CHAT" "blocked" "$FAKE_FB_PID"
settle
assert_state blocked "watcher reported blocked"

t_title "e2e: watcher reports idle when turn completes"
# Clear screen content — turn is done, no popup
: > "$E2E_PANE_CONTENT"
make_fake_chat "$CHAT" "done" "$FAKE_FB_PID"
settle
assert_state idle "watcher reported idle (done)"

t_title "e2e: watcher uses the namespaced lifecycle source"
if grep -qF -- "--source custom:freebuff" "$HERDR_CALL_LOG" 2>/dev/null; then
  t_pass "reports use source custom:freebuff"
else
  t_fail "reports should use a stable namespaced source (log: $(cat "$HERDR_CALL_LOG"))"
fi

t_title "e2e: a newer unrelated chat dir cannot hijack the pinned session"
# Regression: the watcher used to re-resolve "newest chat dir" every poll, so an
# unrelated live session with a newer mtime stole this pane's reported state.
#
# The screen is left empty on purpose: with no screen signal, classify reads the
# log timeline of whichever chat dir it is following.
#
# The watcher only reports on a state *change*, so this walks a real
# idle -> working -> idle sequence on the pinned dir first, then plants an
# unrelated mid-turn dir that is strictly newer. Following it would emit a
# fresh working report; staying pinned emits nothing.
: > "$E2E_PANE_CONTENT"
make_fake_chat "$CHAT" "working" "$FAKE_FB_PID"
settle
assert_state working "pinned session reports working"

make_fake_chat "$CHAT" "done" "$FAKE_FB_PID"
settle
assert_state idle "pinned session reports idle again"

OTHER="$CHATS_DIR/2026-01-01T09-00-00.000Z"
make_fake_chat "$OTHER" "working" 99999
settle
if grep -qF -- "--state working" "$HERDR_CALL_LOG" 2>/dev/null; then
  t_fail "watcher followed an unrelated newer chat dir (log: $(cat "$HERDR_CALL_LOG"))"
else
  t_pass "watcher ignored the unrelated newer chat dir"
fi
rm -rf "$OTHER"

t_title "e2e: watcher releases lifecycle authority when freebuff dies"
: > "$HERDR_CALL_LOG"
kill "$FAKE_FB_PID" 2>/dev/null
sleep 3
if kill -0 "$WATCHER_PID" 2>/dev/null; then
  t_fail "watcher still running after freebuff died"
  kill "$WATCHER_PID" 2>/dev/null
else
  t_pass "watcher exited after freebuff died"
fi
if grep -qF "release-agent" "$HERDR_CALL_LOG" 2>/dev/null; then
  t_pass "watcher released its herdr source on exit"
else
  t_fail "watcher should release-agent on exit (log: $(cat "$HERDR_CALL_LOG"))"
fi

t_title "e2e: watcher removes its per-pane seq file on exit"
if [ -f "$HERDR_PLUGIN_STATE_DIR/seq-e2e-pane" ]; then
  t_fail "seq file should be removed on exit"
else
  t_pass "seq file cleaned up on exit"
fi

# Cleanup
rm -rf "$FAKEHOME" "$PROJECT_DIR"
rm -f /tmp/herdr-e2e-call-log.txt /tmp/herdr-e2e-last.txt /tmp/e2e-debug.log /tmp/herdr-e2e-pane-content.txt
export HOME="$OLD_HOME"
export PATH="$OLD_PATH"
cd "$OLD_PWD"
unset HERDR_CALL_LOG HERDR_STUB_LAST HERDR_STUB_CONTENT_FILE HERDR_PLUGIN_STATE_DIR \
  HERDR_STUB_PANE_PIDS HERDR_STUB_PANE_CWD
