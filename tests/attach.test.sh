# Tests for the restart re-attach sweep and the new pinning/debounce helpers
. "$(dirname "$0")/lib.sh"

. "$(dirname "$0")/../scripts/common.sh"
. "$(dirname "$0")/../scripts/watcher-lib.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKEHOME=$(mktemp -d)
mkdir -p "$FAKEHOME/state"
export HERDR_PLUGIN_STATE_DIR="$FAKEHOME/state"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/attachproj"

# --- should_report_state: idle is debounced, everything else is immediate ---

t_title "should_report_state: no change never reports"
t_is "0" "$(should_report_state working working 0)" "working -> working held"
t_is "0" "$(should_report_state idle idle 9)" "idle -> idle held"

t_title "should_report_state: entering working/blocked reports immediately"
t_is "1" "$(should_report_state idle working 0)" "idle -> working immediate"
t_is "1" "$(should_report_state idle blocked 0)" "idle -> blocked immediate"
t_is "1" "$(should_report_state working blocked 0)" "working -> blocked immediate"

t_title "should_report_state: entering idle is debounced"
t_is "0" "$(should_report_state working idle 1)" "first idle observation held"
t_is "0" "$(should_report_state working idle 2)" "second idle observation held"
t_is "1" "$(should_report_state working idle 3)" "third idle observation reports"

t_title "should_report_state: a zero streak is still inside the debounce window"
t_is "0" "$(should_report_state working idle 0)" "zero streak held"
t_is "1" "$(should_report_state blocked idle 3)" "debounced exit from blocked reports"

# --- pinning by writer pid ---

t_title "pin_own_chat_dir: pins the dir written by this pane's own pid"
MYPID=424242
OTHERS=999998
CHATS="$FAKEHOME/.config/manicode/projects/attachproj/chats"
mkdir -p "$CHATS/2026-01-01T00-00-00.000Z" "$CHATS/2026-01-01T09-00-00.000Z"
printf '{"msg":"Start agent x","pid":%s}\n' "$MYPID" \
  > "$CHATS/2026-01-01T00-00-00.000Z/log.jsonl"
printf '{"msg":"Start agent y","pid":%s}\n' "$OTHERS" \
  > "$CHATS/2026-01-01T09-00-00.000Z/log.jsonl"
# stat resolves to whole seconds, so pin explicit distinct mtimes rather than
# relying on creation order within the same second.
touch -t 202601010001 "$CHATS/2026-01-01T00-00-00.000Z"
touch -t 202601010002 "$CHATS/2026-01-01T09-00-00.000Z"
OLD_HOME="$HOME"
export HOME="$FAKEHOME"

# The stub reports only our pid in the pane, so the newer unrelated dir must lose.
export HERDR_STUB_PANE_PIDS="$MYPID"
result=$(pin_own_chat_dir "w1:p1" "attachproj" 0)
t_is "$CHATS/2026-01-01T00-00-00.000Z" "$result" "pins our pid's dir, not the newer one"

t_title "pin_own_chat_dir: ignores a dir written by a pid not in this pane"
export HERDR_STUB_PANE_PIDS="$OTHERS"
result=$(pin_own_chat_dir "w1:p1" "attachproj" 0)
t_is "$CHATS/2026-01-01T09-00-00.000Z" "$result" "follows the pid herdr reports"

t_title "pin_own_chat_dir: falls back to newest when no pid matches yet"
mkdir -p "$CHATS/2026-01-01T11-00-00.000Z"
printf '{"msg":"Start agent z","pid":777777}\n' \
  > "$CHATS/2026-01-01T11-00-00.000Z/log.jsonl"
touch -t 202601010003 "$CHATS/2026-01-01T11-00-00.000Z"
export HERDR_STUB_PANE_PIDS="555555"
result=$(pin_own_chat_dir "w1:p1" "attachproj" 0)
t_is "$CHATS/2026-01-01T11-00-00.000Z" "$result" "no pid match falls back to newest"

t_title "pin_own_chat_dir: no pids in the pane yields no pin"
export HERDR_STUB_PANE_PIDS=""
result=$(pin_own_chat_dir "w1:p1" "attachproj" 99999999999999)
t_is "" "$result" "empty process-info means no pin yet"

# --- pane_freebuff_pid ---

t_title "pane_freebuff_pid: finds freebuff and ignores the plugin's own scripts"
export HERDR_STUB_PANE_PROCS="74167:sh /x/scripts/status-watcher.sh 1 w1:p1|72243:/Users/x/.config/manicode/freebuff|72232:node /x/bin/freebuff"
result=$(pane_freebuff_pid "w1:p1")
t_is "72243" "$result" "picks the freebuff process, not the watcher shell"

t_title "pane_freebuff_pid: empty when only plugin scripts are present"
export HERDR_STUB_PANE_PROCS="74167:sh /x/scripts/status-watcher.sh 1 w1:p1"
result=$(pane_freebuff_pid "w1:p1")
t_is "" "$result" "no freebuff in the pane -> no attach"

export HOME="$OLD_HOME"
unset HERDR_STUB_PANE_PIDS HERDR_STUB_PANE_PROCS
rm -rf "$FAKEHOME"
unset HERDR_PLUGIN_STATE_DIR

# --- restart sweep scope: plugin-launched panes only ---

t_title "attach-watches: only re-attaches to panes the plugin launched"
SWEEP_HOME=$(mktemp -d)
SWEEP_STATE="$SWEEP_HOME/state"
mkdir -p "$SWEEP_STATE"
export HERDR_PLUGIN_STATE_DIR="$SWEEP_STATE"
export HERDR_ENV=1
export HERDR_SOCKET_PATH="/tmp/fake.sock"
export HERDR_PLUGIN_ROOT="$PROJECT_ROOT"
export HERDR_STUB_PANES="w1:p1 w1:p2"
# w1:p1 is ours (marker present). w1:p2 runs freebuff but the user started it,
# so there is no marker and the sweep must leave it alone.
: > "$SWEEP_STATE/owned-w1:p1"
# The fake freebuff pid must be a process that actually exists, otherwise the
# spawned watcher exits immediately and cleans up its own pidfile.
FAKE_FB=$$
export HERDR_STUB_PANE_PROCS="${FAKE_FB}:/usr/local/bin/freebuff"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/attachproj"

before_ours=$(ls "$SWEEP_STATE" | grep -c 'watch-w1:p1.pid' || true)
sh "$PROJECT_ROOT/scripts/attach-watches.sh" >/dev/null 2>&1
sleep 1
after_ours=$(ls "$SWEEP_STATE" | grep -c 'watch-w1:p1.pid' || true)
after_theirs=$(ls "$SWEEP_STATE" | grep -c 'watch-w1:p2.pid' || true)
[ "$after_ours" -ge 1 ] && t_pass "our pane got a watcher" || t_fail "our pane should be re-attached"
[ "$after_theirs" -eq 0 ] && t_pass "unmarked pane was not adopted" || t_fail "must not adopt panes the plugin did not launch"
if [ -f "$SWEEP_STATE/watch-w1:p1.pid" ]; then
  kill "$(cat "$SWEEP_STATE/watch-w1:p1.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$SWEEP_HOME"
unset HERDR_PLUGIN_STATE_DIR HERDR_ENV HERDR_SOCKET_PATH HERDR_PLUGIN_ROOT
unset HERDR_STUB_PANES HERDR_STUB_PANE_PROCS HERDR_STUB_PANE_CWD
