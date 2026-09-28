#!/bin/sh
# [[startup]] hook: sweep state, re-attach watchers, and start the periodic
# sweep daemon.
#
# The one-shot sweeps run immediately so a restored server is correct before
# this hook returns. The daemon covers everything after that, because a freebuff
# started by hand later would otherwise never be adopted.
. "$(dirname "$0")/common.sh"

sh "${HERDR_PLUGIN_ROOT}/scripts/attach-watches.sh"
sh "${HERDR_PLUGIN_ROOT}/scripts/adopt-watches.sh"

# Backgrounded so the startup hook returns immediately. The daemon claims its
# own slot, so repeated hooks cannot accumulate daemons.
#
# FREEBUFF_NO_DAEMON suppresses it. The daemon is long-lived and inherits the
# environment it was started with, so a caller that changes the environment
# between invocations (the test suite does) would have the daemon pruning against
# a stale view. Real startup hooks run once per server, where the inherited
# environment is stable.
if [ -z "${FREEBUFF_NO_DAEMON:-}" ]; then
  sh "${HERDR_PLUGIN_ROOT}/scripts/sweep-daemon.sh" >/dev/null 2>&1 &
fi

exit 0
