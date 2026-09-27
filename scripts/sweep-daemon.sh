#!/bin/sh
# Periodic sweep daemon.
#
# The startup hook runs once, at server start and after a restore. A freebuff
# the user starts by hand ten minutes later would never be adopted, and there is
# no way to hook pane creation: herdr exposes no cron, no scheduler, and no
# `events.subscribe` in 0.9.1. So something has to poll.
#
# One daemon, guarded by an exclusive-create claim. Several startup hooks can
# race to start it and exactly one wins, the same way the watcher claims a pane.
#
# Runs three sweeps on a slow interval:
#   prune_orphan_state  - state for panes herdr no longer lists
#   attach-watches.sh   - re-attach watchers to plugin-launched panes
#   adopt-watches.sh    - adopt manually started freebuff panes
#
# Interval is deliberately long. Adoption only needs to catch a pane within a
# few seconds of the user starting it, and each pass costs a `pane list` plus one
# `pane process-info` per candidate pane.
. "$(dirname "$0")/common.sh"

STATE_DIR="${HERDR_PLUGIN_STATE_DIR}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

DAEMON_PIDFILE="${STATE_DIR}/sweep-daemon.pid"
DAEMON_LOG="${STATE_DIR}/sweep-daemon.log"

# Claim the daemon slot. The claim is this process's own pid, which is alive for
# the whole run, so a competing sweep always sees a live holder and backs off.
if ! ( set -C; printf '%s' "$$" > "$DAEMON_PIDFILE" ) 2>/dev/null; then
  holder=$(tr -dc '0-9' < "$DAEMON_PIDFILE" 2>/dev/null)
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    exit 0
  fi
  # Dead holder: a daemon that was killed with its server. Reclaim it, letting
  # the exclusive create arbitrate between any racing starters.
  rm -f "$DAEMON_PIDFILE" 2>/dev/null
  ( set -C; printf '%s' "$$" > "$DAEMON_PIDFILE" ) 2>/dev/null || exit 0
fi

log() {
  [ -n "${FREEBUFF_DEBUG:-}" ] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$DAEMON_LOG" 2>/dev/null
  return 0
}

# Stop on the signals a background daemon can receive, and leave no stale claim.
trap 'rm -f "$DAEMON_PIDFILE" 2>/dev/null; exit 0' HUP INT TERM
trap 'rm -f "$DAEMON_PIDFILE" 2>/dev/null' EXIT

INTERVAL="${FREEBUFF_SWEEP_INTERVAL:-20}"

log "sweep daemon start pid=$$ interval=${INTERVAL}s"

while :; do
  # Each sweep is independent and never fatal: one failing must not take the
  # daemon down, or every later sweep is lost until the next server restart.
  sh "${HERDR_PLUGIN_ROOT}/scripts/prune-state.sh" >/dev/null 2>&1 || true
  sh "${HERDR_PLUGIN_ROOT}/scripts/attach-watches.sh" >/dev/null 2>&1 || true
  sh "${HERDR_PLUGIN_ROOT}/scripts/adopt-watches.sh" >/dev/null 2>&1 || true
  log "sweep pass done"
  sleep "$INTERVAL"
done
