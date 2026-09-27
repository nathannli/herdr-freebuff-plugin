# Tests for scripts/prune-state.sh
. "$(dirname "$0")/lib.sh"

. "$(dirname "$0")/../scripts/common.sh"

FAKEHOME=$(mktemp -d)
STATE="$FAKEHOME/state"
mkdir -p "$STATE"
export HERDR_PLUGIN_STATE_DIR="$STATE"

# herdr still knows about w1:p1 only
export HERDR_STUB_PANES="w1:p1"

touch "$STATE/seq-w1:p1"        # live pane, keep
touch "$STATE/seq-w1:p2"        # dead pane, remove
touch "$STATE/seq-w9:p9"        # dead pane, remove
touch "$STATE/watcher-w1:p1.log"

t_title "prune-state.sh: keeps seq files for live panes"
sh "$(dirname "$0")/../scripts/prune-state.sh"
[ -f "$STATE/seq-w1:p1" ] && t_pass "live pane seq file kept" || t_fail "live pane seq file should be kept"

t_title "prune-state.sh: removes seq files for panes herdr no longer lists"
[ ! -f "$STATE/seq-w1:p2" ] && t_pass "dead pane seq file removed" || t_fail "dead pane seq file should be removed"
[ ! -f "$STATE/seq-w9:p9" ] && t_pass "unrelated dead pane seq file removed" || t_fail "unrelated dead pane seq file should be removed"

t_title "prune-state.sh: does not confuse pane id prefixes"
# w1:p1 must not be treated as live just because w1:p11 exists, and vice versa.
touch "$STATE/seq-w1:p11"
export HERDR_STUB_PANES="w1:p11"
sh "$(dirname "$0")/../scripts/prune-state.sh"
[ -f "$STATE/seq-w1:p11" ] && t_pass "new live pane seq file kept" || t_fail "new live pane seq file should be kept"
[ ! -f "$STATE/seq-w1:p1" ] && t_pass "prefix-sharing dead pane seq file removed" || t_fail "prefix-sharing dead pane should be removed, not kept"

t_title "prune-state.sh: keeps fresh debug logs and prunes old ones"
export HERDR_STUB_PANES="w1:p11"
touch "$STATE/watcher-w1:p11.log"
# Backdate one log past the -mtime +1 window
touch -t 202001010000 "$STATE/watcher-w1:p1.log" 2>/dev/null || \
  touch -d '3 days ago' "$STATE/watcher-w1:p1.log" 2>/dev/null || true
sh "$(dirname "$0")/../scripts/prune-state.sh"
[ -f "$STATE/watcher-w1:p11.log" ] && t_pass "fresh debug log kept" || t_fail "fresh debug log should be kept"
[ ! -f "$STATE/watcher-w1:p1.log" ] && t_pass "old debug log pruned" || t_fail "old debug log should be pruned"

t_title "prune-state.sh: no-op when the state dir does not exist"
export HERDR_PLUGIN_STATE_DIR="$FAKEHOME/does-not-exist"
sh "$(dirname "$0")/../scripts/prune-state.sh"
t_ok "$([ -d "$FAKEHOME/does-not-exist" ] && echo false || echo true)"

# Cleanup
rm -rf "$FAKEHOME"
unset HERDR_PLUGIN_STATE_DIR HERDR_STUB_PANES

t_title "prune_orphan_state: is the shared entrypoint the hook uses"
STATE2="$FAKEHOME/state2"
mkdir -p "$STATE2"
export HERDR_PLUGIN_STATE_DIR="$STATE2"
export HERDR_STUB_PANES="w1:p1"
touch "$STATE2/seq-w1:p1" "$STATE2/seq-w1:p2"
. "$(dirname "$0")/../scripts/common.sh"
sh -c '. "'"$(dirname "$0")"'/../scripts/common.sh"; prune_orphan_state'
[ -f "$STATE2/seq-w1:p1" ] && t_pass "shared sweep keeps live seq" || t_fail "shared sweep should keep live seq"
[ ! -f "$STATE2/seq-w1:p2" ] && t_pass "shared sweep removes orphan seq" || t_fail "shared sweep should remove orphan seq"
rm -rf "$STATE2"
