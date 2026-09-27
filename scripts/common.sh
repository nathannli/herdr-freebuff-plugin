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

# Add the well-known install prefixes to PATH if they are missing from it.
#
# Herdr panes do not get a login shell's PATH. Panes are spawned by the herdr
# *server*, and that server is normally started by launchd from herdr-gui's
# LaunchAgent, which inherits launchd's default PATH:
#
#   /usr/bin:/bin:/usr/sbin:/sbin
#
# On a version-managed node install that contains none of `freebuff`, `node`, or
# `herdr`, so every one of them fails: launch.sh aborts with "freebuff binary not
# found on PATH", and even if it did not, the watcher's `next_seq` and the
# classifier's node parse would both fail, taking state reporting down with it.
# Verified on this machine: under that exact PATH, `command -v` finds none of the
# three.
#
# It is an *appended* fallback, not a replacement, and that ordering is the whole
# design. Anything already on PATH keeps winning, so a pane launched from a real
# shell is completely unaffected and an interactive login shell's own version
# selection still takes precedence. Prepending would be wrong: it would let a
# fallback directory shadow a binary the user had already resolved, silently
# running a different version than the one their shell would have.
#
# Only directories that actually exist are added, and a missing one costs
# nothing. This runs once per script; it is a handful of `[ -d ]` tests, not a
# scan.
augment_path() {
  for _dir in \
    "${HOME}/.local/bin" \
    "${HOME}/.local/share/fnm/node-versions"/*/installation/bin \
    "${HOME}/.nvm/versions/node"/*/bin \
    "${HOME}/.asdf/installs/nodejs"/*/bin \
    "${HOME}/.local/share/mise/installs/node"/*/bin \
    /opt/homebrew/bin \
    /usr/local/bin; do
    [ -d "$_dir" ] || continue
    # Skip a directory already on PATH, so the common case leaves PATH alone.
    case ":${PATH}:" in
      *":${_dir}:"*) continue ;;
    esac
    PATH="${PATH}:${_dir}"
  done
  export PATH
  return 0
}

# Called after the definition, and before any caller can resolve a binary. Every
# script that runs `herdr`, `node`, or `freebuff` sources this file first, so one
# call here covers the launcher, the watcher, and the sweeps together.
augment_path

# Resolve the herdr binary. Single source of truth for every herdr call.
#
# HERDR_BIN_PATH wins, so the test suite can point at a stub. Otherwise fall back
# to a PATH lookup, but verify it resolves: a bare `herdr` that is not on PATH
# fails at exec time with "not found" and every call site discards stderr, which
# is indistinguishable from a dead server. That ambiguity is why the watcher's
# failure counter exists, but a pane that can never report is better caught here.
herdr_cmd() {
  if [ -n "${HERDR_BIN_PATH:-}" ]; then
    printf '%s' "$HERDR_BIN_PATH"
    return 0
  fi
  _resolved=$(command -v herdr 2>/dev/null)
  if [ -n "$_resolved" ]; then
    printf '%s' "$_resolved"
  else
    printf 'herdr'
  fi
  return 0
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

# Claim exclusive ownership of a pane's watcher slot.
#
# Returns 0 if the caller now owns the pane and must run a watcher, 1 if another
# live watcher already owns it.
#
# The sweep used to read the pidfile, run `kill -0` on it, and then spawn. That
# is check-then-act: two concurrent sweeps both see no live watcher, both pass,
# and two watchers end up sharing one pane. They then race on the seq file, so
# their --seq values interleave, herdr drops the out-of-order reports, and the
# pane goes quiet for reasons that look like the original bug.
#
# The winner is decided by the kernel, not by a read. `set -C` makes the create
# itself the test, so exactly one of N racing callers can create the file. An
# earlier attempt claimed on the sweeper's behalf and recorded the spawned pid
# afterwards; that failed because the recording was a second, unguarded step, and
# a competing sweep could reclaim the slot in the gap. One atomic step, owned by
# the process that will actually live in the slot, has no such gap.
#
# Only a slot naming a *live* process blocks a claim. A slot left by a killed
# watcher is stale and must be reclaimable, or a pane could never be
# re-attached.
claim_watch_slot() {
  _slot="${HERDR_PLUGIN_STATE_DIR}/watch-$1.pid"

  if ( set -C; printf '%s' "$$" > "$_slot" ) 2>/dev/null; then
    return 0
  fi

  _holder=$(tr -dc '0-9' < "$_slot" 2>/dev/null)
  if [ -z "$_holder" ]; then
    # A slot with no readable pid is a writer mid-update, not a dead claim.
    # Stealing it would hand two watchers the same pane.
    return 1
  fi

  kill -0 "$_holder" 2>/dev/null && return 1

  # Stale: the previous watcher was killed and left this behind. Remove it and
  # let the exclusive create arbitrate, so only one of several sweeps reclaims.
  rm -f "$_slot" 2>/dev/null
  ( set -C; printf '%s' "$$" > "$_slot" ) 2>/dev/null
}

# Replace a slot's contents without ever exposing an empty file.
#
# `> file` truncates before writing, so a concurrent claimer can observe a
# zero-length slot. An empty slot reads as "writer mid-update" and is refused,
# so this costs a re-attach rather than causing a double-attach. Renaming a
# fully written temporary over the slot is atomic: a reader sees either the old
# pid or the new one, never nothing.
# Arguments: pane_id pid
record_watch_slot() {
  _slot="${HERDR_PLUGIN_STATE_DIR}/watch-$1.pid"
  _tmp="${_slot}.tmp.$$"
  printf '%s' "$2" > "$_tmp" 2>/dev/null || return 1
  mv -f "$_tmp" "$_slot" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; return 1; }
  return 0
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

  for state_file in "$state_dir"/seq-* "$state_dir"/watch-*.pid \
                    "$state_dir"/owned-* "$state_dir"/adopted-*; do
    [ -f "$state_file" ] || continue
    base=$(basename "$state_file")
    pane_id="${base#seq-}"
    pane_id="${pane_id#watch-}"
    pane_id="${pane_id#owned-}"
    pane_id="${pane_id#adopted-}"
    pane_id="${pane_id%.pid}"
    pane_is_live "$live_panes" "$pane_id" || rm -f "$state_file" 2>/dev/null
  done
  return 0
}
