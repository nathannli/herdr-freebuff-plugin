#!/bin/sh
# Test runner for freebuff-herdr integration.
# Usage: sh tests/run.sh [test_name_pattern]

SCRIPT_DIR="$(dirname "$0")"
export HERDR_BIN_PATH="${SCRIPT_DIR}/fixtures/herdr-stub.sh"
export HERDR_ENV=1
export HERDR_PANE_ID="test-pane-1"
# can_report() requires a socket path. The stub never connects; this only
# exercises the guard the way a real herdr-managed pane would.
export HERDR_SOCKET_PATH="${TMPDIR:-/tmp}/herdr-test-fake.sock"
export HERDR_STUB_LAST=/tmp/herdr-stub-last.txt
export HERDR_CALL_LOG=/tmp/herdr-stub-call-log.txt

# Reset stub state
: > "$HERDR_CALL_LOG"
: > "$HERDR_STUB_LAST"

cd "$(dirname "$0")/.."

pattern="${1:-}"
TOTAL_FAILED=0
FAILED_FILES=""

for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue
  name="$(basename "$test_file")"
  [ -z "$pattern" ] || printf '%s' "$name" | grep -q "$pattern" || continue

  echo "==========================================="
  printf 'RUNNING: %s\n' "$name"
  echo "==========================================="

  # Run each suite in a subshell with clean state. Failures are accumulated so
  # one broken suite does not hide the results of every suite after it.
  (
    FAIL_COUNT=0 PASS_COUNT=0 TEST_COUNT=0
    : > "$HERDR_CALL_LOG"
    : > "$HERDR_STUB_LAST"
    . "$test_file"
    summary
  ) || {
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    FAILED_FILES="${FAILED_FILES} ${name%.test.sh}"
  }
  echo ""
done

echo "==========================================="
if [ "$TOTAL_FAILED" -eq 0 ]; then
  echo "All suites passed."
else
  echo "FAILED suites:${FAILED_FILES}"
fi
echo "==========================================="

[ "$TOTAL_FAILED" -eq 0 ]
