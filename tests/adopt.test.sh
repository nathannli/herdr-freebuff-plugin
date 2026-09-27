# Tests for adopting manually started freebuff panes.
#
# Adoption is the one place the plugin writes herdr state into a pane it did not
# launch, so the tests are mostly about what it must NOT adopt.
. "$(dirname "$0")/lib.sh"

. "$(dirname "$0")/../scripts/common.sh"
. "$(dirname "$0")/../scripts/watcher-lib.sh"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

setup_adopt() {
  ADOPT_HOME=$(mktemp -d)
  ADOPT_STATE="$ADOPT_HOME/state"
  mkdir -p "$ADOPT_STATE"
  export HERDR_PLUGIN_STATE_DIR="$ADOPT_STATE"
  export HERDR_ENV=1
  export HERDR_SOCKET_PATH="/tmp/fake.sock"
  export HERDR_PLUGIN_ROOT="$PROJECT_ROOT"
  export HERDR_BIN_PATH="$PROJECT_ROOT/tests/fixtures/herdr-stub.sh"
  export HERDR_STUB_PANES="w1:p1"
  export HERDR_STUB_PANE_CWD="/tmp/adoptproj"
  # A process that actually exists, so a spawned watcher does not exit at once
  # and clean up its own pidfile.
  ADOPT_FB=$$
  ADOPT_REAL_FB="/Users/nathan/.config/manicode/freebuff"
  export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:${ADOPT_REAL_FB}"
}

teardown_adopt() {
  for _pf in "$ADOPT_STATE"/watch-*.pid; do
    [ -f "$_pf" ] || continue
    kill "$(tr -dc '0-9' < "$_pf" 2>/dev/null)" 2>/dev/null
  done
  rm -rf "$ADOPT_HOME"
  unset HERDR_PLUGIN_STATE_DIR HERDR_ENV HERDR_SOCKET_PATH HERDR_PLUGIN_ROOT
  unset HERDR_STUB_PANES HERDR_STUB_PANE_PROCS HERDR_STUB_PANE_CWD
  unset HERDR_BIN_PATH FREEBUFF_NO_ADOPT
  ADOPT_HOME=""; ADOPT_STATE=""
}

# --- strict detection ---

t_title "freebuff_paths: includes the real freebuff binary paths"
paths=$(freebuff_paths)
if printf '%s\n' "$paths" | grep -qxF "$HOME/.config/manicode/freebuff"; then
  t_pass "manicode binary path is recognised"
else
  t_fail "missing the manicode freebuff path (got: $paths)"
fi
if printf '%s\n' "$paths" | grep -q "node-versions/.*/bin/freebuff"; then
  t_pass "fnm-installed freebuff path is recognised"
else
  t_fail "missing the fnm freebuff path (got: $paths)"
fi

t_title "pane_freebuff_pid: matches the real manicode binary"
setup_adopt
t_is "$ADOPT_FB" "$(pane_freebuff_pid "w1:p1")" "adopts a pane running the real binary"

t_title "pane_freebuff_pid: matches the fnm node invocation"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:node /Users/nathan/.local/share/fnm/node-versions/v24.21.0/installation/bin/freebuff"
t_is "$ADOPT_FB" "$(pane_freebuff_pid "w1:p1")" "matches node-versions freebuff path"

t_title "pane_freebuff_pid: refuses a lookalike that merely mentions freebuff"
# The regression this whole design guards. A substring match would adopt these
# and write a state dot onto a pane running something else entirely.
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:vim /Users/nathan/notes/freebuff-notes.md"
t_is "" "$(pane_freebuff_pid "w1:p1")" "vim freebuff-notes.md is not adopted"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:grep -r freebuff /Users/nathan/src"
t_is "" "$(pane_freebuff_pid "w1:p1")" "grep freebuff is not adopted"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:sh /Users/nathan/scripts/freebuff-backup.sh"
t_is "" "$(pane_freebuff_pid "w1:p1")" "a user script named freebuff-backup is not adopted"

t_title "pane_freebuff_pid: refuses the plugin's own scripts"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:sh /x/scripts/status-watcher.sh 1 w1:p1"
t_is "" "$(pane_freebuff_pid "w1:p1")" "the watcher is not mistaken for freebuff"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:sh /x/scripts/adopt-watches.sh"
t_is "" "$(pane_freebuff_pid "w1:p1")" "the adoption sweep is not mistaken for freebuff"
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:sh /x/scripts/sweep-daemon.sh"
t_is "" "$(pane_freebuff_pid "w1:p1")" "the sweep daemon is not mistaken for freebuff"

# --- adoption ---

t_title "adopt-watches: adopts a manual freebuff pane and marks it"
setup_adopt
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_pass "adopted marker written so the pane is adopted once" \
  || t_fail "no adopted-<pane> marker after adopting a manual pane"
if [ -f "$ADOPT_STATE/watch-w1:p1.pid" ]; then
  t_pass "a watcher is attached to the adopted pane"
else
  t_fail "manual pane got no watcher"
fi

t_title "adopt-watches: a second pass does not re-adopt"
before=$(cat "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
after=$(cat "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)
t_is "$before" "$after" "the same watcher is kept, not replaced"

t_title "adopt-watches: never touches a pane the plugin launched"
setup_adopt
: > "$ADOPT_STATE/owned-w1:p1"
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "a plugin-launched pane must not be marked adopted" \
  || t_pass "plugin-launched pane is left to attach-watches.sh"

t_title "adopt-watches: a pane that runs no freebuff is not adopted"
setup_adopt
export HERDR_STUB_PANE_PROCS="${ADOPT_FB}:/bin/zsh"
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "a plain shell pane must not be adopted" \
  || t_pass "a pane running zsh is not adopted"

t_title "adopt-watches: the kill switch stops adoption"
setup_adopt
: > "$ADOPT_STATE/no-adopt"
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "no-adopt file must stop adoption" \
  || t_pass "no-adopt file disables adoption"
rm -f "$ADOPT_STATE/no-adopt"

t_title "adopt-watches: FREEBUFF_NO_ADOPT in the environment stops adoption"
setup_adopt
FREEBUFF_NO_ADOPT=1 sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "FREEBUFF_NO_ADOPT must stop adoption" \
  || t_pass "environment kill switch disables adoption"

t_title "adopt-watches: a per-pane no-adopt marker is honoured"
setup_adopt
: > "$ADOPT_STATE/no-adopt-w1:p1"
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "per-pane no-adopt marker was ignored" \
  || t_pass "a pane can opt out individually"

t_title "adopt-watches: an adopted pane that dies is swept"
setup_adopt
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/adopted-w1:p1" ] || t_fail "setup: nothing was adopted"
# Pane gone: herdr no longer lists it.
export HERDR_STUB_PANES="w1:p2"
. "$PROJECT_ROOT/scripts/common.sh"
prune_orphan_state
[ -f "$ADOPT_STATE/adopted-w1:p1" ] \
  && t_fail "adopted marker for a dead pane was not swept" \
  || t_pass "adopted marker for a closed pane is swept"

teardown_adopt

# --- a dead watcher on an adopted pane must be re-attached ---

t_title "attach-watches: re-attaches a watcher killed on an adopted pane"
# The regression that made adopted panes go permanently stale.
#
# A watcher is a child of the pane's process tree, so a herdr restart SIGKILLs it
# and the cleanup that calls `release-agent` never runs: herdr then holds the last
# reported state forever. Nothing put a watcher back, because the pane had no
# `owned-` marker (so attach-watches skipped it) and already had an `adopted-`
# marker (so adopt-watches skipped it too). Observed live as panes stuck showing
# `agent: freebuff` with no watcher process anywhere.
setup_adopt
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/watch-w1:p1.pid" ] || t_fail "setup: nothing was adopted"
# Kill the watcher the way a server restart does: no trap, no cleanup.
kill -9 "$(tr -dc '0-9' < "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)" 2>/dev/null || true
sleep 1

sh "$PROJECT_ROOT/scripts/attach-watches.sh" >/dev/null 2>&1
sleep 1
reattached=$(tr -dc '0-9' < "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)
if [ -n "$reattached" ] && kill -0 "$reattached" 2>/dev/null; then
  t_pass "a killed watcher on an adopted pane is replaced"
else
  t_fail "adopted pane left with no watcher, so its herdr state is stuck forever"
fi
teardown_adopt

t_title "attach-watches: a per-pane no-adopt marker detaches an adopted pane"
# Opting out has to work on a pane that was already adopted, or "no-adopt" is
# only a promise about the future.
setup_adopt
sh "$PROJECT_ROOT/scripts/adopt-watches.sh" >/dev/null 2>&1
sleep 1
[ -f "$ADOPT_STATE/watch-w1:p1.pid" ] || t_fail "setup: nothing was adopted"
: > "$ADOPT_STATE/no-adopt-w1:p1"
kill -9 "$(tr -dc '0-9' < "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)" 2>/dev/null || true
sleep 1
sh "$PROJECT_ROOT/scripts/attach-watches.sh" >/dev/null 2>&1
sleep 1
opted_out=$(tr -dc '0-9' < "$ADOPT_STATE/watch-w1:p1.pid" 2>/dev/null)
if [ -z "$opted_out" ] || ! kill -0 "$opted_out" 2>/dev/null; then
  t_pass "an opted-out pane is not re-attached"
else
  t_fail "per-pane no-adopt did not detach an already-adopted pane"
fi
teardown_adopt

summary
