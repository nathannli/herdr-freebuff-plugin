#!/bin/sh
# Freebuff -> Herdr lifecycle status watcher.
#
# One instance per herdr pane running freebuff. Started by scripts/launch.sh for
# plugin-opened panes, and by scripts/attach-watches.sh for panes that survived
# a herdr restart. Scans freebuff's per-chat state files to classify the agent
# state and reports to the herdr pane.
#
# Arguments: <freebuff_pid> <pane_id> [min_created_ms]
#
# Reports use a stable namespaced source so herdr can order them by --seq and
# release the source's lifecycle authority on exit. Without that release, the
# pane keeps the last reported state (working/blocked) forever once freebuff
# is gone.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/watcher-lib.sh"

FREEBUFF_PID="$1"
PANE_ID="$2"
MIN_CREATED_MS="${3:-0}"

# Stable and unique per integration, as herdr requires. Never change these
# without unlinking the plugin: a new source is a new authority owner.
SOURCE="custom:freebuff"
AGENT="freebuff"
META_SOURCE="custom:freebuff-display"

[ -n "$FREEBUFF_PID" ] && [ -n "$PANE_ID" ] && can_report || exit 0

STATE_DIR="${HERDR_PLUGIN_STATE_DIR}"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  STATE_DIR="${TMPDIR:-/tmp}/herdr-freebuff"
  mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="${TMPDIR:-/tmp}"
fi
SEQ_FILE="${STATE_DIR}/seq-${PANE_ID}"
PID_FILE="${STATE_DIR}/watch-${PANE_ID}.pid"
DEBUG_LOG="${STATE_DIR}/watcher-${PANE_ID}.log"

# Let a restart sweep tell a live watcher from a dead one.
printf '%s' "$$" > "$PID_FILE" 2>/dev/null

# Opt-in diagnostics: FREEBUFF_DEBUG=1 in the pane environment.
log() {
  if [ -n "${FREEBUFF_DEBUG:-}" ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$DEBUG_LOG" 2>/dev/null
  fi
  return 0
}

# Unconditional logging, for the case where the watcher has lost herdr.
#
# `log` is debug-gated because a healthy watcher writes a line every 700ms. But
# the failure this exists for is precisely the one you cannot afford to be
# silent about: a watcher that cannot reach herdr looks identical to a pane with
# no plugin installed. Nobody will ever turn on FREEBUFF_DEBUG to diagnose a
# symptom that produces no output.
log_always() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$DEBUG_LOG" 2>/dev/null
  printf 'freebuff-watcher: %s\n' "$*" >&2
  return 0
}

# Monotonic seq counter, single writer per pane. Herdr drops reports whose seq
# is not greater than the last accepted one for the same source.
next_seq() {
  if [ -f "$SEQ_FILE" ]; then
    seq=$(tr -dc '0-9' < "$SEQ_FILE" 2>/dev/null)
  else
    seq=$(node -e 'process.stdout.write(String(Date.now()*1000))')
  fi
  seq=$(( ${seq:-0} + 1 ))
  printf '%s' "$seq" > "$SEQ_FILE" 2>/dev/null
  printf '%s' "$seq"
}

# Consecutive report-agent failures tolerated before the watcher gives up.
#
# Giving up is correct, not defensive: once the server is gone this process is
# holding a pane's worth of dead state and a stale seq counter, and the only
# thing that can fix it is exiting so the startup hook re-attaches a fresh
# watcher against the new server.
REPORT_FAILURE_LIMIT="${FREEBUFF_REPORT_FAILURE_LIMIT:-5}"
REPORT_FAILURES=0

report() {
  log "report $1"
  if "$(herdr_cmd)" pane report-agent "$PANE_ID" \
    --source "$SOURCE" --agent "$AGENT" --state "$1" --seq "$(next_seq)" >/dev/null 2>&1; then
    if [ "$REPORT_FAILURES" -gt 0 ]; then
      log_always "report-agent recovered after $REPORT_FAILURES failure(s)"
      REPORT_FAILURES=0
    fi
    return 0
  fi

  REPORT_FAILURES=$(( REPORT_FAILURES + 1 ))
  log_always "report-agent FAILED state=$1 ($REPORT_FAILURES/$REPORT_FAILURE_LIMIT consecutive)"
  if [ "$REPORT_FAILURES" -ge "$REPORT_FAILURE_LIMIT" ]; then
    log_always "giving up on pane $PANE_ID: $REPORT_FAILURE_LIMIT consecutive report-agent failures. Watcher will exit so the startup hook re-attaches it against the new server."
    exit 1
  fi
  return 0
}

# Display-only presentation. Never carries lifecycle authority.
label() {
  "$(herdr_cmd)" pane report-metadata "$PANE_ID" \
    --source "$META_SOURCE" --agent "$AGENT" --display-agent freebuff >/dev/null 2>&1
}

# Release authority and drop per-pane state so the pane cannot keep a stale
# working/blocked dot after freebuff exits.
#
# Order matters twice over:
#   1. next_seq must be read BEFORE the rm, because next_seq writes the seq file
#      and would otherwise recreate the file we just deleted.
#   2. The rm runs before the herdr call, so the local cleanup cannot be lost to
#      a race with a signal arriving mid-call.
#
# This still does not run when a pane is closed: herdr tears the pane's process
# group down with SIGKILL, which no shell trap can intercept. prune_orphan_state
# covers that case.
cleanup() {
  seq=$(next_seq)
  rm -f "$SEQ_FILE" "$PID_FILE" 2>/dev/null
  log "releasing $SOURCE for $PANE_ID"
  "$(herdr_cmd)" pane release-agent "$PANE_ID" \
    --source "$SOURCE" --agent "$AGENT" --seq "$seq" >/dev/null 2>&1
}
trap cleanup EXIT
# SIGHUP matters most here: closing the pane tears down the PTY and hangs up the
# watcher. Without a HUP handler the shell dies without running the EXIT trap.
trap 'exit 0' HUP INT TERM

# Fractional sleep is not POSIX. Probe once so a strict sleep(1) cannot turn
# the poll loop into a busy spin.
POLL_INTERVAL=0.7
if ! sleep "$POLL_INTERVAL" 2>/dev/null; then
  log "fractional sleep unsupported, falling back to 1s"
  POLL_INTERVAL=1
fi

log "watcher start pane=$PANE_ID freebuff_pid=$FREEBUFF_PID interval=$POLL_INTERVAL"

# Pin this pane to exactly one chat dir, once.
#
# The pin is by writer pid, not by "newest dir". Newest-by-mtime is not a stable
# identity: an idle session stops touching its dir, so any other freebuff
# session still writing becomes newest and hijacks this pane's state. Measured
# on a live server, an idle pane flipped to working and stayed there for 76
# polls because an unrelated session was mid-turn.
PROJECT_SLUG=$(pane_project_slug "$PANE_ID")
log "project_slug=${PROJECT_SLUG:-<unresolved>} min_created_ms=$MIN_CREATED_MS"

CHAT_DIR=""

# --- Main loop ---
label

PREV_STATE=""
IDLE_STREAK=0

# Re-report the current state even when it has not changed, so a watcher whose
# reports are failing gets to discover that. Without this the failure counter
# below only advances on a state change, and a pane sitting idle against a dead
# server would never attempt a report and never notice.
HEARTBEAT_POLLS="${FREEBUFF_HEARTBEAT_POLLS:-30}"
POLLS_SINCE_REPORT=0

while kill -0 "$FREEBUFF_PID" 2>/dev/null; do
  if [ -z "$CHAT_DIR" ]; then
    candidate=$(pin_own_chat_dir "$PANE_ID" "$PROJECT_SLUG" "$MIN_CREATED_MS")
    if [ -n "$candidate" ]; then
      CHAT_DIR="$candidate"
      log "pinned chat_dir=$CHAT_DIR (watching pid $FREEBUFF_PID)"
    fi
  elif [ ! -d "$CHAT_DIR" ]; then
    log "pinned chat dir disappeared, re-pinning"
    CHAT_DIR=""
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [ -z "$CHAT_DIR" ]; then
    # This pane's freebuff has not written a chat dir yet.
    state=idle
  else
    state=$(classify "$CHAT_DIR" "$PANE_ID")
  fi
  log "state=$state chat_dir=${CHAT_DIR:-<unpinned>}"

  if [ "$state" = idle ]; then
    IDLE_STREAK=$((IDLE_STREAK + 1))
  else
    IDLE_STREAK=0
  fi

  if [ "$(should_report_state "$PREV_STATE" "$state" "$IDLE_STREAK")" = "1" ]; then
    report "$state"
    PREV_STATE="$state"
    POLLS_SINCE_REPORT=0
  else
    POLLS_SINCE_REPORT=$(( POLLS_SINCE_REPORT + 1 ))
    # Only once something has actually been reported, so a pane that has never
    # left its debounce window does not heartbeat an empty state.
    if [ -n "$PREV_STATE" ] && [ "$POLLS_SINCE_REPORT" -ge "$HEARTBEAT_POLLS" ]; then
      report "$PREV_STATE"
      POLLS_SINCE_REPORT=0
    fi
  fi

  sleep "$POLL_INTERVAL"
done

log "freebuff pid $FREEBUFF_PID gone, watcher exiting"
