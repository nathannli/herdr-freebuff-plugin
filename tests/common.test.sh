# Tests for scripts/common.sh
. "$(dirname "$0")/lib.sh"

. "$(dirname "$0")/../scripts/common.sh"

t_title "common.sh: in_herdr returns true when HERDR_ENV=1"
t_ok "in_herdr"

t_title "common.sh: in_herdr returns false when HERDR_ENV unset"
_SAVED="${HERDR_ENV:-}"
unset HERDR_ENV
. "$(dirname "$0")/../scripts/common.sh"
if in_herdr; then
  t_fail "in_herdr should be false outside herdr"
else
  t_pass "in_herdr false outside herdr"
fi
export HERDR_ENV="$_SAVED"
unset _SAVED

t_title "common.sh: herdr_cmd honours HERDR_BIN_PATH"
_SAVED_BIN="${HERDR_BIN_PATH:-}"
HERDR_BIN_PATH="/custom/herdr"
. "$(dirname "$0")/../scripts/common.sh"
t_is "/custom/herdr" "$(herdr_cmd)" "herdr_cmd returns HERDR_BIN_PATH"

t_title "common.sh: herdr_cmd falls back to herdr on PATH"
unset HERDR_BIN_PATH
. "$(dirname "$0")/../scripts/common.sh"
t_is "herdr" "$(herdr_cmd)" "herdr_cmd falls back to bare herdr"
HERDR_BIN_PATH="$_SAVED_BIN"
unset _SAVED_BIN

t_title "common.sh: can_report requires env, pane id and socket"
_SAVED_SOCK="${HERDR_SOCKET_PATH:-}"
unset HERDR_SOCKET_PATH
t_ok "! can_report"    # no socket: herdr cannot receive reports
export HERDR_SOCKET_PATH="$_SAVED_SOCK"
t_ok "can_report"      # run.sh exports HERDR_ENV=1 and HERDR_PANE_ID
unset _SAVED_SOCK
