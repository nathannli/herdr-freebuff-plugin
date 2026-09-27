#!/bin/sh
# Launch Freebuff inside a herdr plugin PANE.
#
# Herdr runs plugin pane entrypoints as the pane's own PTY process, so freebuff
# gets a real TTY and its interactive TUI works. (Plugin actions/CLI have no TTY
# and cannot launch interactive agents, which is why these are panes, not actions.)
#
# This script is the only place the lifecycle watcher is started. $$ becomes
# freebuff's own pid after the exec below, so the watcher can track freebuff's
# lifetime with a plain kill -0 poll. No PATH shim and no baked absolute path.
#
# Usage: launch.sh <task|resume-last|resume-named> [session-id]
. "$(dirname "$0")/common.sh"

mode="${1:-task}"
name="${2:-}"

# Spawn the lifecycle watcher for this pane, if herdr can receive reports.
# Runs before the exec so the watcher exists for the whole session.
# $1 = floor epoch-ms for chat-dir pinning; 0 means "any dir may be pinned",
# which is what a resumed session needs because it reuses an existing chat dir.
spawn_watcher() {
  can_report || return 0
  # Claim the pane before the watcher starts. The restart sweep only re-attaches
  # to panes carrying this marker, so a freebuff the user started by hand is
  # never adopted.
  mkdir -p "${HERDR_PLUGIN_STATE_DIR}" 2>/dev/null
  : > "${HERDR_PLUGIN_STATE_DIR}/owned-${HERDR_PANE_ID}" 2>/dev/null
  sh "${HERDR_PLUGIN_ROOT}/scripts/status-watcher.sh" "$$" "$HERDR_PANE_ID" "${1:-0}" >/dev/null 2>&1 &
  return 0
}

# A brand-new session creates its chat dir after launch. Pin the watcher to
# dirs created at or after now so it cannot latch onto another live session.
now_ms() {
  node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null || printf '0'
}

# Resolve freebuff binary.
FREEBUFF_BIN="${FREEBUFF_BIN_PATH:-}"
if [ -z "$FREEBUFF_BIN" ]; then
  FREEBUFF_BIN=$(command -v freebuff 2>/dev/null)
fi
if [ -z "$FREEBUFF_BIN" ] || [ ! -x "$FREEBUFF_BIN" ]; then
  echo "freebuff binary not found on PATH" >&2
  exit 1
fi

case "$mode" in
  task)
    spawn_watcher "$(now_ms)"
    exec "$FREEBUFF_BIN"
    ;;
  resume-last)
    spawn_watcher 0
    exec "$FREEBUFF_BIN" --continue
    ;;
  resume-named)
    if [ -z "$name" ]; then
      echo "resume-named requires a session id" >&2
      exit 1
    fi
    spawn_watcher 0
    exec "$FREEBUFF_BIN" --continue "$name"
    ;;
  *)
    echo "unknown launch mode: $mode" >&2
    exit 1
    ;;
esac
