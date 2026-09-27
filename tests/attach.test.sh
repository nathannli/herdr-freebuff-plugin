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

t_title "pin_own_chat_dir: a zero floor refuses the newest-dir fallback"
# Regression: a floor of 0 means a resumed session or a restart re-attach, and
# "newest dir" cannot identify those. An idle session stops touching its dir, so
# any other active session in the same project is newer and would take over the
# state. No pin is correct here; a wrong pin is not.
mkdir -p "$CHATS/2026-01-01T11-00-00.000Z"
printf '{"msg":"Start agent z","pid":777777}\n' \
  > "$CHATS/2026-01-01T11-00-00.000Z/log.jsonl"
touch -t 202601010003 "$CHATS/2026-01-01T11-00-00.000Z"
export HERDR_STUB_PANE_PIDS="555555"
result=$(pin_own_chat_dir "w1:p1" "attachproj" 0)
t_is "" "$result" "zero floor with no pid match yields no pin, not the newest dir"

t_title "pin_own_chat_dir: a new-session floor still allows the mtime fallback"
# A brand-new session's dir is provably its own because the floor proves it was
# created after this pane launched. freebuff has not written its first log line
# yet, so this covers the first second or two of a session's life.
#
# Timestamps are fixed and in the past: BSD touch silently clamps a future
# timestamp to the current time, which would make the fixture's ordering a
# function of when the suite runs.
NEW_SLUG="floorproj"
FLOOR_CHATS="$FAKEHOME/.config/manicode/projects/$NEW_SLUG/chats"
mkdir -p "$FLOOR_CHATS/2026-01-01T12-00-00.000Z"
printf '{"msg":"Start agent new","pid":666666}\n' \
  > "$FLOOR_CHATS/2026-01-01T12-00-00.000Z/log.jsonl"
touch -t 202602010000 "$FLOOR_CHATS/2026-01-01T12-00-00.000Z"
# Floor is one second before the dir's mtime, in ms, as launch.sh supplies it.
# Read the mtime back rather than recomputing it from the timestamp: `date -j -f`
# and `touch -t` do not agree to the second here, and the fixture only works if
# the floor really is below the dir.
DIR_MTIME_S=$(stat -f %m "$FLOOR_CHATS/2026-01-01T12-00-00.000Z" 2>/dev/null || \
  stat -c %Y "$FLOOR_CHATS/2026-01-01T12-00-00.000Z")
FLOOR_MS=$(( DIR_MTIME_S * 1000 - 1000 ))
result=$(pin_own_chat_dir "w1:p1" "$NEW_SLUG" "$FLOOR_MS")
t_is "$FLOOR_CHATS/2026-01-01T12-00-00.000Z" "$result" "non-zero floor falls back to newest"

# --- re-validating an established pin ---

t_title "chat_dir_still_ours: yes when the pane's pid wrote the dir"
export HERDR_STUB_PANE_PIDS="$MYPID"
t_is "yes" "$(chat_dir_still_ours "w1:p1" "$CHATS/2026-01-01T00-00-00.000Z")" \
  "our own pid still writes the dir"

t_title "chat_dir_still_ours: no when only another pid writes the dir"
export HERDR_STUB_PANE_PIDS="555555"
t_is "no" "$(chat_dir_still_ours "w1:p1" "$CHATS/2026-01-01T00-00-00.000Z")" \
  "a dir written by another pid is not ours"

t_title "chat_dir_still_ours: unknown when the pane cannot be read"
# Not a mismatch: herdr failing to answer is not evidence the pin went bad, and
# treating it as one would unpin a correct pin on every hiccup.
export HERDR_STUB_PANE_PIDS=""
t_is "unknown" "$(chat_dir_still_ours "w1:p1" "$CHATS/2026-01-01T00-00-00.000Z")" \
  "unreadable pane is unknown, not a mismatch"

t_title "chat_dir_still_ours: unknown when the dir has no log yet"
export HERDR_STUB_PANE_PIDS="$MYPID"
mkdir -p "$CHATS/2026-01-01T13-00-00.000Z"
t_is "unknown" "$(chat_dir_still_ours "w1:p1" "$CHATS/2026-01-01T13-00-00.000Z")" \
  "a dir with no log.jsonl has no writer to compare"

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

# --- concurrent sweeps must not double-attach ---

t_title "attach-watches: concurrent sweeps leave exactly one live watcher per pane"
# Regression: the sweep read the pidfile, ran `kill -0`, and then spawned. Two
# concurrent sweeps both saw no live watcher, both passed the check, and two
# watchers shared one pane. They then raced on the seq file, so their --seq
# values interleaved and herdr dropped the out-of-order reports.
#
# Every sweep still spawns a candidate; the watcher claims the pane for itself
# with an exclusive create and the losers exit. So the invariant to assert is
# one *live* watcher afterwards, not one spawn. Counting spawns would be wrong
# by design under overlapping sweeps.
RACE_HOME=$(mktemp -d)
RACE_STATE="$RACE_HOME/state"
mkdir -p "$RACE_STATE"
export HERDR_PLUGIN_STATE_DIR="$RACE_STATE"
export HERDR_ENV=1
export HERDR_PANE_ID="test-pane-1"
export HERDR_SOCKET_PATH="/tmp/fake.sock"
export HERDR_PLUGIN_ROOT="$PROJECT_ROOT"
export HERDR_STUB_PANES="w1:p1"
: > "$RACE_STATE/owned-w1:p1"
RACE_FB=$$
export HERDR_STUB_PANE_PROCS="${RACE_FB}:/usr/local/bin/freebuff"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/attachproj"
export HERDR_BIN_PATH="$PROJECT_ROOT/tests/fixtures/herdr-stub.sh"
export HERDR_CALL_LOG="$RACE_HOME/calls.log"
: > "$HERDR_CALL_LOG"

for _n in 1 2 3 4 5 6; do
  ( sh "$PROJECT_ROOT/scripts/attach-watches.sh" >/dev/null 2>&1 ) &
done
wait
# Long enough for the winner to get through its first polls and create state.
sleep 4

live_watchers=0
for _pf in "$RACE_STATE"/watch-*.pid; do
  [ -f "$_pf" ] || continue
  _p=$(tr -dc '0-9' < "$_pf" 2>/dev/null)
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && live_watchers=$((live_watchers + 1))
done
t_is "1" "$live_watchers" "one live watcher for the pane, not several"

# One seq file too. Two watchers on one pane would each keep their own view of
# the same counter, which is exactly what makes herdr drop reports.
t_is "1" "$(ls "$RACE_STATE" | grep -c '^seq-' || echo 0)" "one seq file for the pane"

# The real consequence of a double-attach: two watchers share one seq counter,
# so their reports interleave and herdr drops the ones that arrive out of order.
# The winner alone reports, so every seq it sends must strictly increase.
seqs=$(grep -o -- "--seq [0-9]*" "$HERDR_CALL_LOG" 2>/dev/null | awk '{print $2}')
strictly_increasing=$(printf '%s\n' "$seqs" | awk '
  NR == 1 { prev = $1; next }
  { if ($1 <= prev) { print "NO"; exit } prev = $1 }
  END { if (NR > 1) print "YES"; else print "NONE" }')
if [ "$strictly_increasing" = "NONE" ] || [ "$strictly_increasing" = "YES" ]; then
  t_pass "reported seq numbers strictly increase ($strictly_increasing)"
else
  t_fail "seq numbers went backwards, so two watchers share the counter"
fi

if [ -f "$RACE_STATE/watch-w1:p1.pid" ]; then
  kill "$(tr -dc '0-9' < "$RACE_STATE/watch-w1:p1.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$RACE_HOME"
unset HERDR_PLUGIN_STATE_DIR HERDR_ENV HERDR_SOCKET_PATH HERDR_PLUGIN_ROOT
unset HERDR_STUB_PANES HERDR_STUB_PANE_PROCS HERDR_STUB_PANE_CWD
unset HERDR_BIN_PATH HERDR_CALL_LOG

# --- the claim primitive on its own ---

t_title "claim_watch_slot: a second claim on a live slot is refused"
CLAIM_HOME=$(mktemp -d)
export HERDR_PLUGIN_STATE_DIR="$CLAIM_HOME"
# Claim from this shell, not a subshell: the slot records the caller's pid, and
# a subshell's pid dies with the subshell, so a claim made in one would look
# stale to the next.
. "$PROJECT_ROOT/scripts/common.sh"
if claim_watch_slot "w1:p9"; then
  t_pass "first claim on a free slot succeeds"
else
  t_fail "first claim on a free slot should succeed"
fi
t_is "$$" "$(tr -dc '0-9' < "$CLAIM_HOME/watch-w1:p9.pid")" "slot records the claiming pid"
# A different shell, but the holder (this one) is still alive.
if ( . "$PROJECT_ROOT/scripts/common.sh"; claim_watch_slot "w1:p9" ) 2>/dev/null; then
  t_fail "second claim on a live slot should be refused"
else
  t_pass "second claim on a live slot is refused"
fi
rm -f "$CLAIM_HOME/watch-w1:p9.pid"
rm -rf "$CLAIM_HOME"
unset HERDR_PLUGIN_STATE_DIR

t_title "claim_watch_slot: a slot naming a dead process is reclaimed"
DEAD_HOME=$(mktemp -d)
export HERDR_PLUGIN_STATE_DIR="$DEAD_HOME"
# A pid that cannot be running, as left by a sweep that died before recording
# its watcher.
printf '%s' "999999" > "$DEAD_HOME/watch-w1:p9.pid"
if ( . "$PROJECT_ROOT/scripts/common.sh"; claim_watch_slot "w1:p9" ) 2>/dev/null; then
  t_pass "stale claim from a dead holder is taken over"
else
  t_fail "a dead holder should not block re-attachment forever"
fi
rm -rf "$DEAD_HOME"
unset HERDR_PLUGIN_STATE_DIR

t_title "claim_watch_slot: an empty slot is not treated as stale"
EMPTY_HOME=$(mktemp -d)
export HERDR_PLUGIN_STATE_DIR="$EMPTY_HOME"
: > "$EMPTY_HOME/watch-w1:p9.pid"
if ( . "$PROJECT_ROOT/scripts/common.sh"; claim_watch_slot "w1:p9" ) 2>/dev/null; then
  t_fail "an empty slot means a writer is mid-update; stealing it double-attaches"
else
  t_pass "empty slot is left alone"
fi
rm -rf "$EMPTY_HOME"
unset HERDR_PLUGIN_STATE_DIR
