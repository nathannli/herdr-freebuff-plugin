#!/bin/sh
# Adopt panes running a freebuff the user started by hand.
#
# The plugin launches its own panes and marks them `owned-<pane_id>`. A freebuff
# typed into any other herdr pane has no marker, so without this sweep it shows
# `agent_status: unknown` forever.
#
# Adoption means writing herdr state into a pane the plugin does not own, so the
# gating is the whole point of this script:
#
#   1. Detection is strict. `pane_freebuff_pid` matches resolved freebuff binary
#      paths, not the substring "freebuff", so `vim freebuff-notes.md` in a pane
#      is never adopted. A false positive would paint another program's state
#      onto the user's pane.
#   2. Pinning is pid-only. An adopted pane has no launch floor, and newest-by-
#      mtime cannot identify a resumed session, so the watcher waits for a writer
#      pid match and reports `idle` until one appears. No pin is the correct
#      answer: a wrong pin reports another session's state indefinitely.
#   3. Adoption is visible and reversible. An `adopted-<pane_id>` marker records
#      it, `no-adopt` in the state dir stops new claims, and `no-adopt-<pane_id>`
#      drops a single pane. Turning adoption off does not tear down watchers that
#      already exist: killing one without releasing its herdr authority would
#      leave a stale state dot behind, which is worse than a live watcher on a pane
#      the user no longer wants adopted.
#
# A claim lasts exactly as long as the freebuff it was made for. An
# `adopted-<pane_id>` marker on a pane with no freebuff in it is a claim on a
# process that has exited, so it is dropped and the pane becomes adoptable
# again. Tying the marker to the pane instead left a live pane that could never
# be adopted a second time: a freebuff started there later reported
# `agent_status: unknown` forever, which is the exact trap adoption exists to
# avoid. Seen live on a pane whose freebuff had exited.
#
# Keeping an existing claim's watcher alive is attach-watches.sh's job, not this
# script's, so a pane with a live watcher is skipped here.
#
# The watcher claims the pane for itself with an atomic create, so overlapping
# sweeps cannot produce two watchers on one pane.
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/watcher-lib.sh"

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0

STATE_DIR="${HERDR_PLUGIN_STATE_DIR}"

# Kill switch. Create this file to stop adopting entirely:
#   touch "$(herdr plugin config-dir freebuff.integration)/../../state/herdr/plugins/freebuff.integration/no-adopt"
# Simpler from a shell: see README, "Turning adoption off".
[ -f "${STATE_DIR}/no-adopt" ] && exit 0
[ -n "${FREEBUFF_NO_ADOPT:-}" ] && exit 0

panes=$(live_pane_ids)
[ -n "$panes" ] || exit 0

adopted=0
for pane_id in $panes; do
  # Already ours, or explicitly excluded by a per-pane no-adopt marker. An
  # opted-out pane keeps its marker untouched: opting out is the user's call,
  # not ours to clean up.
  [ -f "${STATE_DIR}/owned-${pane_id}" ] && continue
  [ -f "${STATE_DIR}/no-adopt-${pane_id}" ] && continue

  # Detection comes before the pidfile check on purpose. Whether a claim is
  # still valid depends on the freebuff, not on the watcher, so the freebuff has
  # to be resolved first or a stale claim would outlive the process it names.
  freebuff_pid=$(pane_freebuff_pid "$pane_id")
  if [ -z "$freebuff_pid" ]; then
    # The freebuff this pane was adopted for has exited, so the claim is void.
    # Dropping it is what lets a freebuff started here later be adopted; the
    # marker is rewritten below the moment a freebuff is actually present.
    rm -f "${STATE_DIR}/adopted-${pane_id}" 2>/dev/null
    continue
  fi

  # A freebuff in the pane is what makes the claim true, so record it here,
  # before the pidfile check below. Skipping straight past a pane that already
  # has a live watcher would leave the marker missing, and a missing marker is
  # what attach-watches.sh reads to decide a pane is still claimed.
  : > "${STATE_DIR}/adopted-${pane_id}" 2>/dev/null

  # Cheap pre-check only. The watcher's own atomic claim is what actually
  # decides; this just avoids spawning a watcher that would instantly exit.
  if [ -f "${STATE_DIR}/watch-${pane_id}.pid" ]; then
    existing=$(tr -dc '0-9' < "${STATE_DIR}/watch-${pane_id}.pid" 2>/dev/null)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      continue
    fi
  fi

  # Floor 0: pid-only pinning, no newest-by-mtime fallback. See note 2 above.
  sh "${HERDR_PLUGIN_ROOT}/scripts/status-watcher.sh" \
    "$freebuff_pid" "$pane_id" 0 >/dev/null 2>&1 &
  adopted=$((adopted + 1))
done

[ "$adopted" -gt 0 ] && printf 'adopted %s manual pane(s)\n' "$adopted" >&2
exit 0
