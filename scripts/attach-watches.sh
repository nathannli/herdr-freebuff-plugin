#!/bin/sh
# [[startup]] hook: re-attach lifecycle watchers to live freebuff panes.
#
# A watcher is a child of the pane's own process tree, so a herdr server restart
# kills every watcher. The panes and their freebuff processes survive, which
# left those panes reporting nothing until the user relaunched freebuff by hand.
#
# Herdr re-reads this hook after restore, once the API socket is up, so this is
# the first moment the surviving panes can be inspected. `pane process-info`
# gives the pid of the freebuff in each pane, which is all the watcher needs.
#
# Several sweeps can run at once, so this script does not decide who watches a
# pane. It spawns a candidate and the watcher claims the pane for itself with an
# atomic create; the losers exit immediately without reporting anything.
#
# Scope is deliberately limited to panes carrying an `owned-<pane_id>` marker,
# written by launch.sh. Without that check this sweep would also adopt freebuff
# sessions the user started by hand and start writing herdr state into panes the
# plugin does not own.
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/watcher-lib.sh"

prune_orphan_state

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0

STATE_DIR="${HERDR_PLUGIN_STATE_DIR}"
# Deliberately no mkdir: this script only reads pidfiles, and the watcher creates
# the state dir itself when it actually starts. Creating it here would make a
# no-op sweep leave a directory behind.

panes=$(live_pane_ids)
[ -n "$panes" ] || exit 0

candidates=0
for pane_id in $panes; do

  # Only panes this plugin launched. A freebuff the user started by hand has no
  # marker, so it is never adopted and never has state written into it.
  [ -f "${STATE_DIR}/owned-${pane_id}" ] || continue

  # Cheap pre-check only, to avoid spawning a watcher that would immediately
  # exit. It is not the thing that prevents two watchers: it is check-then-act
  # and loses every race by definition. The watcher claims the pane for itself
  # as its first action, and that atomic claim is what actually decides.
  if [ -f "${STATE_DIR}/watch-${pane_id}.pid" ]; then
    existing=$(tr -dc '0-9' < "${STATE_DIR}/watch-${pane_id}.pid" 2>/dev/null)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      continue
    fi
  fi

  freebuff_pid=$(pane_freebuff_pid "$pane_id")
  [ -n "$freebuff_pid" ] || continue

  sh "${HERDR_PLUGIN_ROOT}/scripts/status-watcher.sh" \
    "$freebuff_pid" "$pane_id" 0 >/dev/null 2>&1 &
  candidates=$((candidates + 1))
done

# Counts candidates spawned, not watchers attached. When sweeps overlap this is
# deliberately larger than the number of panes, because the extra watchers lose
# the claim and exit without doing anything. Calling it "attached" would
# overstate what happened.
[ "$candidates" -gt 0 ] && printf 'spawned %s watcher candidate(s)\n' "$candidates" >&2
exit 0
