#!/bin/sh
# Shared helpers for the Freebuff herdr plugin.
# Sourced by the launch/notify/watcher scripts. Safe to source outside herdr (no-ops).

# Plugin root: herdr provides this for plugin commands; fall back to this
# script's own location so scripts work when invoked directly.
: "${HERDR_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

# Plugin-local runtime state (per-pane seq counters, debug logs). Herdr creates
# this dir for installed plugins; fall back to a stable temp path otherwise.
: "${HERDR_PLUGIN_STATE_DIR:=${TMPDIR:-/tmp}/herdr-freebuff}"

# True when running inside a managed herdr pane.
in_herdr() { [ "${HERDR_ENV:-}" = "1" ]; }

# Resolve the herdr binary. Single source of truth for every herdr call.
herdr_cmd() {
  if [ -n "${HERDR_BIN_PATH:-}" ]; then
    printf '%s' "$HERDR_BIN_PATH"
  else
    printf 'herdr'
  fi
}

# True when this pane can actually report to a running herdr server.
# Herdr injects all three into every managed pane process.
can_report() {
  in_herdr && [ -n "${HERDR_PANE_ID:-}" ] && [ -n "${HERDR_SOCKET_PATH:-}" ]
}

# Echo the ids of every pane the running herdr server knows about, one per line.
#
# Parsed with node rather than sed on purpose: `pane list` prints the whole
# panes array on a single line, so a greedy sed pattern silently yields only the
# last pane id. That bug made the restart sweep attach to one arbitrary pane.
live_pane_ids() {
  "$(herdr_cmd)" pane list 2>/dev/null | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{
        const panes=JSON.parse(d).result.panes||[];
        for(const p of panes) if(p.pane_id) process.stdout.write(p.pane_id+"\n");
      }catch{}
    })
  ' 2>/dev/null
}

# True when a pane id is in the given newline-separated list.
# -x keeps w1:p1 from matching w1:p11.
pane_is_live() {
  printf '%s\n' "$1" | grep -qxF "$2"
}

# Remove per-pane state for panes herdr no longer lists, plus debug logs older
# than a day.
#
# This is not belt-and-braces. Closing a pane makes herdr tear down the pane's
# whole process group, which SIGKILLs the watcher before any shell trap can run,
# so the watcher cannot clean up after itself in that case. Verified live: the
# watcher exits with no cleanup log line and its state files survive. Sweeping
# from outside is the only thing that works.
prune_orphan_state() {
  state_dir="${HERDR_PLUGIN_STATE_DIR}"
  [ -d "$state_dir" ] || return 0

  find "$state_dir" -name 'watcher-*.log' -type f -mtime +1 -delete 2>/dev/null || true

  live_panes=$(live_pane_ids)
  [ -n "$live_panes" ] || return 0

  for state_file in "$state_dir"/seq-* "$state_dir"/watch-*.pid "$state_dir"/owned-*; do
    [ -f "$state_file" ] || continue
    base=$(basename "$state_file")
    pane_id="${base#seq-}"
    pane_id="${pane_id#watch-}"
    pane_id="${pane_id#owned-}"
    pane_id="${pane_id%.pid}"
    pane_is_live "$live_panes" "$pane_id" || rm -f "$state_file" 2>/dev/null
  done
  return 0
}
