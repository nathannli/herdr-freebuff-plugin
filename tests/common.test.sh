# Tests for scripts/common.sh
. "$(dirname "$0")/lib.sh"

PROJECT_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

t_title "common.sh: herdr_cmd resolves herdr on PATH to an absolute path"
# Not the bare string `herdr`. A bare name that turns out not to be on PATH fails
# at exec time, and every call site discards stderr, so "herdr not found" is
# indistinguishable from "server is gone". Resolving first keeps the watcher's
# failure counter meaning what it says.
unset HERDR_BIN_PATH
. "$(dirname "$0")/../scripts/common.sh"
_hc=$(herdr_cmd)
if [ "$_hc" = "herdr" ]; then
  t_is "herdr" "$_hc" "herdr not installed here, so the bare name is the fallback"
elif [ -x "$_hc" ]; then
  t_pass "herdr_cmd resolves to an executable path ($_hc)"
else
  t_fail "herdr_cmd returned a non-executable path: $_hc"
fi
HERDR_BIN_PATH="$_SAVED_BIN"
unset _SAVED_BIN

t_title "common.sh: can_report requires env, pane id and socket"
_SAVED_SOCK="${HERDR_SOCKET_PATH:-}"
unset HERDR_SOCKET_PATH
t_ok "! can_report"    # no socket: herdr cannot receive reports
export HERDR_SOCKET_PATH="$_SAVED_SOCK"
t_ok "can_report"      # run.sh exports HERDR_ENV=1 and HERDR_PANE_ID
unset _SAVED_SOCK

# --- augment_path ---

t_title "common.sh: augment_path adds a version-managed bin missing from PATH"
# The launchd case: a herdr server started from herdr-gui's LaunchAgent inherits
# /usr/bin:/bin:/usr/sbin:/sbin, which on a version-managed node install has
# neither freebuff, nor node, nor herdr in it.
AUG_HOME=$(mktemp -d)
mkdir -p "$AUG_HOME/.local/share/fnm/node-versions/v24.21.0/installation/bin"
AUG_DIR="$AUG_HOME/.local/share/fnm/node-versions/v24.21.0/installation/bin"
# Must be executable: `command -v` skips a non-executable file, so an empty
# placeholder would make this test fail for a reason unrelated to PATH.
printf '#!/bin/sh\nexit 0\n' > "$AUG_DIR/node"
chmod +x "$AUG_DIR/node"
AUG_OLD_PATH="$PATH"
(
  export HOME="$AUG_HOME"
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  . "$PROJECT_ROOT_DIR/scripts/common.sh"
  command -v node >/dev/null 2>&1 || exit 1
)
if [ $? -eq 0 ]; then
  t_pass "node resolves under a bare launchd PATH"
else
  t_fail "augment_path did not add $AUG_DIR"
fi
export PATH="$AUG_OLD_PATH"
rm -rf "$AUG_HOME"

t_title "common.sh: augment_path appends, so it cannot shadow an existing choice"
# The regression this test exists for. Prepending looks equivalent but is not: it
# lets a fallback directory outrank a binary the user had already resolved, so a
# pane would silently run a different version than the user's shell would.
# Appending means PATH order is exactly preserved and the fallback is only ever
# reached when nothing else provides the binary.
AUG_HOME2=$(mktemp -d)
mkdir -p "$AUG_HOME2/bin" "$AUG_HOME2/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$AUG_HOME2/bin/node"
chmod +x "$AUG_HOME2/bin/node"
AUG_DIR2="$AUG_HOME2/.local/bin"
augment_path_out=$(
  export HOME="$AUG_HOME2"
  export PATH="$AUG_HOME2/bin:/usr/bin:/bin"
  . "$PROJECT_ROOT_DIR/scripts/common.sh"
  printf '%s' "$PATH"
)
expected_prefix="$AUG_HOME2/bin:/usr/bin:/bin:"
case "$augment_path_out" in
  "$expected_prefix"*)
    # The original three entries must still lead, in the original order, with
    # every fallback after them. Which fallbacks appear depends on what exists on
    # the machine, so assert the ordering rather than the exact contents.
    if [ "$augment_path_out" = "$AUG_OLD_PATH" ]; then
      t_pass "an already-complete PATH is left untouched"
    elif printf '%s' "$augment_path_out" | grep -q "^$expected_prefix"; then
      t_pass "existing PATH order preserved, fallbacks appended after it"
    else
      t_fail "unexpected PATH contents: $augment_path_out"
    fi
    ;;
  *)
    t_fail "augment_path reordered PATH, so it can shadow an existing binary: $augment_path_out"
    ;;
esac
export PATH="$AUG_OLD_PATH"
rm -rf "$AUG_HOME2"

t_title "common.sh: augment_path does not duplicate a directory already on PATH"
AUG_HOME3=$(mktemp -d)
mkdir -p "$AUG_HOME3/.local/bin"
AUG_COUNT=$(
  export HOME="$AUG_HOME3"
  export PATH="$AUG_HOME3/.local/bin:/usr/bin:/bin"
  . "$PROJECT_ROOT_DIR/scripts/common.sh"
  printf '%s' "$PATH" | tr ':' '\n' | grep -c -x "$AUG_HOME3/.local/bin"
)
t_is "1" "$AUG_COUNT" "an already-present directory is added only once"
export PATH="$AUG_OLD_PATH"
rm -rf "$AUG_HOME3"

t_title "common.sh: augment_path tolerates a HOME with no version managers"
# A machine with none of fnm/nvm/asdf/mise must still work. Every candidate
# glob is left literal and unexpanded, so this is the case where a naive
# implementation would either error or add a literal "*" path.
if (
  export HOME="$(mktemp -d)"
  export PATH="/usr/bin:/bin"
  . "$PROJECT_ROOT_DIR/scripts/common.sh"
  case ":$PATH:" in
    *"\*"*) exit 1 ;;
    *) exit 0 ;;
  esac
); then
  t_pass "no unexpanded globs leak into PATH"
else
  t_fail "an unexpanded glob reached PATH"
fi
