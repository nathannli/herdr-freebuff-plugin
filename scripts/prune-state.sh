#!/bin/sh
# [[startup]] hook: re-attach watchers to surviving freebuff panes and clean up
# state for panes that are gone.
. "$(dirname "$0")/common.sh"

sh "${HERDR_PLUGIN_ROOT}/scripts/attach-watches.sh"
exit 0
