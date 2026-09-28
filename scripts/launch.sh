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
# Usage: launch.sh <task|resume-last>
. "$(dirname "$0")/common.sh"

mode="${1:-task}"

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
#
# Falling back to 0 is not a safe degradation: a zero floor disables the
# newest-by-mtime fallback in the watcher, so a brand-new session would pin by
# writer pid only and report idle until freebuff writes its first log line. Warn
# rather than fail, because a session without a floor still works, just less
# precisely.
now_ms() {
  _ms=$(node -e 'process.stdout.write(String(Date.now()))' 2>/dev/null) || _ms=""
  if [ -z "$_ms" ]; then
    echo "warning: node not on PATH; starting without a launch-time pin floor" >&2
    printf '0'
    return 0
  fi
  printf '%s' "$_ms"
}

# Resolve freebuff binary. common.sh has already prepended the well-known
# install prefixes, so a pane spawned by a launchd-started herdr server still
# finds a version-managed freebuff.
FREEBUFF_BIN="${FREEBUFF_BIN_PATH:-}"
if [ -z "$FREEBUFF_BIN" ]; then
  FREEBUFF_BIN=$(command -v freebuff 2>/dev/null)
fi
if [ -z "$FREEBUFF_BIN" ] || [ ! -x "$FREEBUFF_BIN" ]; then
  # Name node too: without it the watcher's seq counter and the classifier both
  # fail, so a pane that opened without state reporting would look like a
  # different bug entirely.
  echo "freebuff binary not found on PATH (looked on PATH and in ~/.local/bin," >&2
  echo "fnm/nvm/asdf/mise node bins, /opt/homebrew/bin, /usr/local/bin)." >&2
  [ -n "${FREEBUFF_BIN_PATH:-}" ] && echo "FREEBUFF_BIN_PATH is set to: $FREEBUFF_BIN_PATH" >&2
  command -v node >/dev/null 2>&1 || echo "node is also not on PATH; state reporting would not work." >&2
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
  *)
    echo "unknown launch mode: $mode" >&2
    exit 1
    ;;
esac
