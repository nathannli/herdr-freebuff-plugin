# Tests for scripts/watcher-lib.sh (classify function)
. "$(dirname "$0")/lib.sh"

# Source common.sh then watcher-lib to get herdr_cmd, classify, detect_blocked,
# last_matching_ts
. "$(dirname "$0")/../scripts/common.sh"
. "$(dirname "$0")/../scripts/watcher-lib.sh"

t_title "classify: idle when no chat dir"
result=$(classify "/nonexistent/dir")
t_is "idle" "$result" "no chat dir -> idle"

t_title "classify: blocked with unresolved ask-user (old format)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
result=$(classify "$chat_dir")
t_is "blocked" "$result" "ask-user block with no user reply -> blocked"
rm -rf "$chat_dir"

t_title "classify: blocked with tool/ask_user (new format)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked-new"
result=$(classify "$chat_dir")
t_is "blocked" "$result" "tool/ask_user block with no user reply -> blocked"
rm -rf "$chat_dir"

t_title "classify: working from in-progress agent step"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
result=$(classify "$chat_dir")
t_is "working" "$result" "Start agent after last finish -> working"
rm -rf "$chat_dir"

t_title "classify: idle (done) after Main prompt finished"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "done"
result=$(classify "$chat_dir")
t_is "idle" "$result" "Main prompt finished after start -> idle (done)"
rm -rf "$chat_dir"

t_title "classify: blocked when ask-user on finished turn (freebuff model)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "stale-blocked"
result=$(classify "$chat_dir")
t_is "blocked" "$result" "ask-user with Main prompt finished -> blocked (freebuff finishes turn before showing question)"
rm -rf "$chat_dir"

t_title "classify: idle when no messages"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
result=$(classify "$chat_dir")
t_is "idle" "$result" "no conversation -> idle"
rm -rf "$chat_dir"

t_title "classify_signals: detects ask-user (old format)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
classify_signals "$chat_dir"
t_is "blocked" "$SIG_BLOCKED" "ask-user block reported as blocked"
rm -rf "$chat_dir"

t_title "classify_signals: detects ask-user (new tool format)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked-new"
classify_signals "$chat_dir"
t_is "blocked" "$SIG_BLOCKED" "tool/ask_user block reported as blocked"
rm -rf "$chat_dir"

t_title "classify_signals: no ask-user on working"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
classify_signals "$chat_dir"
t_is "" "$SIG_BLOCKED" "no ask-user block on a working session"
rm -rf "$chat_dir"

t_title "classify_signals: finds the last Start agent"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
classify_signals "$chat_dir"
t_is "2026-01-01T00:02:10.000Z" "$SIG_START" "finds last start agent timestamp"
rm -rf "$chat_dir"

t_title "classify_signals: finds Main prompt finished"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "done"
classify_signals "$chat_dir"
t_is "2026-01-01T00:02:10.000Z" "$SIG_FINISH" "finds main prompt finished timestamp"
rm -rf "$chat_dir"

t_title "find_newest_chat: finds chat across projects"
_old_home="$HOME"
export HOME=$(mktemp -d)
mkdir -p "$HOME/.config/manicode/projects/testproj/chats/2026-01-01T00-00-00.000Z"
result=$(find_newest_chat)
t_is "$HOME/.config/manicode/projects/testproj/chats/2026-01-01T00-00-00.000Z" "$result" "finds chat dir"
rm -rf "$HOME"
export HOME="$_old_home"
unset _old_home

t_title "find_newest_chat: project slug filter ignores other projects"
_old_home="$HOME"
export HOME=$(mktemp -d)
mkdir -p "$HOME/.config/manicode/projects/proj-a/chats/2026-01-01T00-00-00.000Z"
mkdir -p "$HOME/.config/manicode/projects/proj-b/chats/2026-01-01T00-00-00.000Z"
# Make proj-b strictly newer so an unfiltered scan would pick it
touch "$HOME/.config/manicode/projects/proj-b/chats/2026-01-01T00-00-00.000Z"
sleep 0.05
touch "$HOME/.config/manicode/projects/proj-a/chats/2026-01-01T00-00-00.000Z"
result=$(find_newest_chat "proj-a")
t_is "$HOME/.config/manicode/projects/proj-a/chats/2026-01-01T00-00-00.000Z" "$result" "slug filter returns only that project's chat"
result=$(find_newest_chat "proj-b")
t_is "$HOME/.config/manicode/projects/proj-b/chats/2026-01-01T00-00-00.000Z" "$result" "other slug still resolvable"
rm -rf "$HOME"
export HOME="$_old_home"
unset _old_home

t_title "find_newest_chat: min mtime floor rejects older chats"
_old_home="$HOME"
export HOME=$(mktemp -d)
OLD_DIR="$HOME/.config/manicode/projects/proj-a/chats/2026-01-01T00-00-00.000Z"
mkdir -p "$OLD_DIR"
echo '{}' > "$OLD_DIR/log.jsonl"
# Floor far in the future: nothing can satisfy it
result=$(find_newest_chat "proj-a" 99999999999999)
t_is "" "$result" "future floor rejects an existing chat dir"
# Floor at 0 behaves like no floor
result=$(find_newest_chat "proj-a" 0)
t_is "$OLD_DIR" "$result" "zero floor keeps the existing chat dir"
rm -rf "$HOME"
export HOME="$_old_home"
unset _old_home

t_title "pane_project_slug: resolves the basename of the pane cwd"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/my-project"
result=$(pane_project_slug "test.pane.9")
t_is "my-project" "$result" "slug is the cwd basename"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/my-project/"
result=$(pane_project_slug "test.pane.9")
t_is "my-project" "$result" "trailing slash does not leak into the slug"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/my-project/sub"
result=$(pane_project_slug "test.pane.9")
t_is "sub" "$result" "deep cwd uses its own basename"
unset HERDR_STUB_PANE_CWD

t_title "pane_project_slug: empty pane_id returns empty"
result=$(pane_project_slug "")
t_is "" "$result" "empty pane id -> empty slug"

t_title "pane_project_slug: calls pane get without a --json flag"
# `herdr pane get` always prints JSON and rejects --json with a usage error.
# The stub would happily swallow the flag, so assert the real argv.
: > "$HERDR_CALL_LOG"
export HERDR_STUB_PANE_CWD="/Users/someone/dev/argv-check"
pane_project_slug "test.pane.argv" >/dev/null
if grep -qF "pane get test.pane.argv --json" "$HERDR_CALL_LOG" 2>/dev/null; then
  t_fail "pane_project_slug must not pass --json to pane get"
else
  t_pass "pane get called without --json"
fi
unset HERDR_STUB_PANE_CWD

t_title "find_newest_chat: empty when no projects"
_old_home="$HOME"
export HOME=$(mktemp -d)
result=$(find_newest_chat)
t_is "" "$result" "empty when no projects"
rm -rf "$HOME"
export HOME="$_old_home"
unset _old_home

t_title "classify_signals: no match returns empty"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
classify_signals "$chat_dir"
t_is "" "$SIG_START" "no Start agent marker -> empty start"
rm -rf "$chat_dir"

t_title "classify_signals: uses messagesMtimeMs when it is the newest signal"
# A directory mtime only moves when entries are added or removed, so it is a weak
# activity signal. The activity value is the max across freebuff's recorded
# messagesMtimeMs, the session file mtimes, and the directory mtime.
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
printf '{"messagesMtimeMs":9999999999999}\n' > "$chat_dir/chat-meta.json"
classify_signals "$chat_dir"
t_is "9999999999999" "$SIG_ACTIVITY" "newest signal wins over file mtimes"
rm -rf "$chat_dir"

t_title "classify_signals: activity tracks real file writes, not dir mtime"
# Touching a file inside the dir does not move the dir mtime. The activity
# signal must still advance, or a resumed session can look permanently dead.
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
rm -f "$chat_dir/chat-meta.json"
classify_signals "$chat_dir"
before=$SIG_ACTIVITY
[ -n "$before" ] && [ "$before" -gt 0 ] 2>/dev/null && t_pass "activity is populated without chat-meta.json" \
  || t_fail "activity should come from file mtimes (got: $before)"
rm -rf "$chat_dir"

t_title "classify_signals: dir mtime is only a last-resort fallback"
chat_dir=$(mktemp -d)
mkdir -p "$chat_dir"
classify_signals "$chat_dir"
[ -n "$SIG_ACTIVITY" ] && [ "$SIG_ACTIVITY" -gt 0 ] 2>/dev/null \
  && t_pass "empty dir falls back to its own mtime" \
  || t_fail "empty dir should still report an activity value (got: $SIG_ACTIVITY)"
rm -rf "$chat_dir"

t_title "classify_signals: missing chat dir yields empty signals, not garbage"
classify_signals "/nonexistent/chat/dir"
t_is "0" "$SIG_ACTIVITY" "activity defaults to 0"
t_is "" "$SIG_START" "start empty"
t_is "" "$SIG_FINISH" "finish empty"
t_is "" "$SIG_BLOCKED" "blocked empty"

# --- detect_screen_state tests ---
# These need to stub `herdr pane read` via the fake herdr binary.
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HERDR_BIN_PATH="$PROJECT_ROOT/tests/fixtures/herdr-stub.sh"

t_title "detect_screen_state: returns blocked for ask_user popup"
HERDR_STUB_PANE_CONTENT_test_pane_1="$PROJECT_ROOT/tests/fixtures/pane-ask-user.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_1
result=$(detect_screen_state "test.pane.1")
t_is "blocked" "$result" "ask_user popup detected via screen content"

t_title "detect_screen_state: returns interrupted for [response interrupted]"
HERDR_STUB_PANE_CONTENT_test_pane_4="$PROJECT_ROOT/tests/fixtures/pane-response-interrupted.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_4
result=$(detect_screen_state "test.pane.4")
t_is "interrupted" "$result" "[response interrupted] detected via screen content"

t_title "detect_screen_state: returns answered for 'Your answer:' + box"
# The fixture also carries a live Thinking line below the echo (the new turn
# starts right after the answer). Bottom-most wins at detection level, and
# thinking and a boxed answer both mean working — classify lands on working
# either way (asserted below).
HERDR_STUB_PANE_CONTENT_test_pane_5="$PROJECT_ROOT/tests/fixtures/pane-answer-chosen.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_5
result=$(detect_screen_state "test.pane.5")
t_is "thinking" "$result" "echo above live Thinking: bottom-most marker wins, both mean working"

t_title "detect_screen_state: boxed answer with no Thinking below is answered"
# Truncate the fixture to the boxed answer plus one blank line so the echo
# itself is the bottom-most transient marker (the second Thinking line below
# the box is the next turn, not part of this one).
_fixture_dir=$(mktemp -d)
sed -n '1,/^╰/p' "$PROJECT_ROOT/tests/fixtures/pane-answer-chosen.txt" > "$_fixture_dir/echo-only.txt"
HERDR_STUB_PANE_CONTENT_test_pane_5="$_fixture_dir/echo-only.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_5
result=$(detect_screen_state "test.pane.5")
t_is "answered" "$result" "'Your answer:' box as the bottom-most marker -> answered"
rm -rf "$_fixture_dir"

t_title "detect_screen_state: returns thinking for suggest_followups"
HERDR_STUB_PANE_CONTENT_test_pane_2="$PROJECT_ROOT/tests/fixtures/pane-suggest-followups.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_2
result=$(detect_screen_state "test.pane.2")
t_is "thinking" "$result" "suggest_followups has • Thinking -> thinking"

t_title "detect_screen_state: returns thinking for plain working output"
HERDR_STUB_PANE_CONTENT_test_pane_3="$PROJECT_ROOT/tests/fixtures/pane-plain.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_3
result=$(detect_screen_state "test.pane.3")
t_is "thinking" "$result" "plain thinking output has • Thinking -> thinking"

t_title "detect_screen_state: returns empty for truly idle output"
HERDR_STUB_PANE_CONTENT_test_pane_6="$PROJECT_ROOT/tests/fixtures/pane-idle.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_6
result=$(detect_screen_state "test.pane.6")
t_is "" "$result" "idle pane with no signals -> empty"

t_title "detect_screen_state: empty pane_id returns empty silently"
result=$(detect_screen_state "")
t_is "" "$result" "empty pane_id -> empty result"

t_title "classify: screen overrides working -> blocked"
# Build a working chat dir (file-based returns working), then a pane_id whose
# screen shows ask_user popup -> classify should return "blocked".
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_1="$PROJECT_ROOT/tests/fixtures/pane-ask-user.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_1
result=$(classify "$chat_dir" "test.pane.1")
t_is "blocked" "$result" "working + ask_user on screen -> blocked"
rm -rf "$chat_dir"

t_title "classify: screen with suggest_followups does not override working"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_2="$PROJECT_ROOT/tests/fixtures/pane-suggest-followups.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_2
result=$(classify "$chat_dir" "test.pane.2")
t_is "working" "$result" "working + suggest_followups -> working (not blocked)"
rm -rf "$chat_dir"

t_title "classify: file=blocked + pane=interrupted -> idle"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
HERDR_STUB_PANE_CONTENT_test_pane_4="$PROJECT_ROOT/tests/fixtures/pane-response-interrupted.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_4
result=$(classify "$chat_dir" "test.pane.4")
t_is "idle" "$result" "blocked files + [response interrupted] on screen -> idle"
rm -rf "$chat_dir"

t_title "classify: file=blocked + pane=answered -> working"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
HERDR_STUB_PANE_CONTENT_test_pane_5="$PROJECT_ROOT/tests/fixtures/pane-answer-chosen.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_5
result=$(classify "$chat_dir" "test.pane.5")
t_is "working" "$result" "blocked files + 'Your answer:' box on screen -> working"
rm -rf "$chat_dir"

t_title "classify: file=blocked + pane=blocked -> blocked"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
HERDR_STUB_PANE_CONTENT_test_pane_1="$PROJECT_ROOT/tests/fixtures/pane-ask-user.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_1
result=$(classify "$chat_dir" "test.pane.1")
t_is "blocked" "$result" "blocked files + live popup on screen -> blocked"
rm -rf "$chat_dir"

t_title "classify: file=blocked + pane='' -> blocked (no screen override)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
result=$(classify "$chat_dir")
t_is "blocked" "$result" "blocked files + no pane_id -> blocked (no screen check)"
rm -rf "$chat_dir"

t_title "classify: working files + pane=interrupted -> idle (screen first)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_4="$PROJECT_ROOT/tests/fixtures/pane-response-interrupted.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_4
result=$(classify "$chat_dir" "test.pane.4")
t_is "idle" "$result" "working files + [response interrupted] on screen -> idle (screen is authoritative)"
rm -rf "$chat_dir"

t_title "classify: idle files + pane=interrupted -> idle (screen first)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
HERDR_STUB_PANE_CONTENT_test_pane_4="$PROJECT_ROOT/tests/fixtures/pane-response-interrupted.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_4
result=$(classify "$chat_dir" "test.pane.4")
t_is "idle" "$result" "idle files + [response interrupted] on screen -> idle (screen says idle)"
rm -rf "$chat_dir"

t_title "classify: file=blocked + pane=thinking -> working"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
HERDR_STUB_PANE_CONTENT_test_pane_3="$PROJECT_ROOT/tests/fixtures/pane-plain.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_3
result=$(classify "$chat_dir" "test.pane.3")
t_is "working" "$result" "blocked files + • Thinking on screen -> working"
rm -rf "$chat_dir"

t_title "classify: working files + pane=thinking -> working (screen first)"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_3="$PROJECT_ROOT/tests/fixtures/pane-plain.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_3
result=$(classify "$chat_dir" "test.pane.3")
t_is "working" "$result" "working files + • Thinking on screen -> working (screen says working)"
rm -rf "$chat_dir"

t_title "classify: no screen signals + working timeline -> working"
chat_dir=$(mktemp -d)
# Working timeline (Start agent after last Main prompt finished — AI is processing)
cat > "$chat_dir/chat-messages.json" <<'JSONEOF'
[{"id":"divider-1","variant":"divider","content":"","blocks":[],"timestamp":"00:00 AM"}]
JSONEOF
cat > "$chat_dir/log.jsonl" <<'JSONEOF'
{"level":"INFO","timestamp":"2026-01-01T00:01:00.000Z","msg":"[send-message] Sending message"}
{"level":"INFO","timestamp":"2026-01-01T00:02:00.000Z","msg":"Start agent test-agent step 1 (run1)"}
{"level":"INFO","timestamp":"2026-01-01T00:02:05.000Z","msg":"End agent test-agent step 1 (run1)"}
{"level":"INFO","timestamp":"2026-01-01T00:02:10.000Z","msg":"Start agent test-agent step 2 (run1)"}
JSONEOF
# No screen signals (idle fixture — no popup, no markers)
HERDR_STUB_PANE_CONTENT_test_pane_6="$PROJECT_ROOT/tests/fixtures/pane-idle.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_6
result=$(classify "$chat_dir" "test.pane.6")
t_is "working" "$result" "no screen signals + working timeline -> working (timeline fallback)"
rm -rf "$chat_dir"

t_title "classify: no screen signals + idle timeline -> idle"
chat_dir=$(mktemp -d)
# Idle timeline (Main prompt finished after last start — turn is done)
cat > "$chat_dir/chat-messages.json" <<'JSONEOF'
[{"id":"divider-1","variant":"divider","content":"","blocks":[],"timestamp":"00:00 AM"}]
JSONEOF
cat > "$chat_dir/log.jsonl" <<'JSONEOF'
{"level":"INFO","timestamp":"2026-01-01T00:01:00.000Z","msg":"[send-message] Sending message"}
{"level":"INFO","timestamp":"2026-01-01T00:02:00.000Z","msg":"Start agent test-agent step 1 (run1)"}
{"level":"INFO","timestamp":"2026-01-01T00:02:10.000Z","msg":"Main prompt finished"}
JSONEOF
HERDR_STUB_PANE_CONTENT_test_pane_6="$PROJECT_ROOT/tests/fixtures/pane-idle.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_6
result=$(classify "$chat_dir" "test.pane.6")
t_is "idle" "$result" "no screen signals + idle timeline -> idle (timeline fallback)"
rm -rf "$chat_dir"

# --- quoted-marker regressions ---
# A mid-turn agent PRINTS old markers (reading its own chat log, grepping a
# transcript, cat-ing this repo's tests). Flat marker precedence ranked the
# quoted stale marker above the live heartbeat and reported idle mid-turn,
# which fired herdr's agent-done notification while the session was working.

t_title "detect_screen_state: quoted [response interrupted] loses to live Thinking below it"
HERDR_STUB_PANE_CONTENT_test_pane_7="$PROJECT_ROOT/tests/fixtures/pane-quoted-interrupted-last.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_7
result=$(detect_screen_state "test.pane.7")
t_is "thinking" "$result" "bottom-most marker wins: quoted interrupted is history, Thinking is live"

t_title "detect_screen_state: quoted 'Your answer:' without box is not answered"
HERDR_STUB_PANE_CONTENT_test_pane_8="$PROJECT_ROOT/tests/fixtures/pane-quoted-answer-no-box.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_8
result=$(detect_screen_state "test.pane.8")
t_is "thinking" "$result" "answer echo requires its confirmation box; bare text is history"

t_title "detect_screen_state: genuine interruption (marker bottom-most, no Thinking) still detected"
HERDR_STUB_PANE_CONTENT_test_pane_9="$PROJECT_ROOT/tests/fixtures/pane-interrupted-bare-last.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_9
result=$(detect_screen_state "test.pane.9")
t_is "interrupted" "$result" "real Esc leaves [response interrupted] as the bottom-most marker"

t_title "classify: working files + quoted interrupted + Thinking on screen -> working"
# The exact production symptom: timeline says working, screen shows a quoted
# interrupted marker above the live heartbeat. Must stay working.
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_7="$PROJECT_ROOT/tests/fixtures/pane-quoted-interrupted-last.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_7
result=$(classify "$chat_dir" "test.pane.7")
t_is "working" "$result" "quoted interrupted must not flip a working session to idle"
rm -rf "$chat_dir"

t_title "classify: working files + bare interrupted (no Thinking) -> idle after recheck"
# Real Esc: the marker stays bottom-most across the re-read because the screen
# is static, so the confirm pass upholds the idle verdict.
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "working"
HERDR_STUB_PANE_CONTENT_test_pane_9="$PROJECT_ROOT/tests/fixtures/pane-interrupted-bare-last.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_9
result=$(classify "$chat_dir" "test.pane.9")
t_is "idle" "$result" "genuine interruption of a working session still lands idle"
rm -rf "$chat_dir"

t_title "classify: idle files + bare interrupted -> idle without recheck"
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "idle"
HERDR_STUB_PANE_CONTENT_test_pane_9="$PROJECT_ROOT/tests/fixtures/pane-interrupted-bare-last.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_9
result=$(classify "$chat_dir" "test.pane.9")
t_is "idle" "$result" "interrupted against an idle timeline needs no confirmation"
rm -rf "$chat_dir"

t_title "classify: file=blocked + quoted answer without box -> files decide"
# The echo lost its box (quoted text), so it is history. The live Thinking
# heartbeat below it wins, and a thinking screen against blocked files means
# the new turn already started -> working (same contract as pane=thinking).
chat_dir=$(mktemp -d)
make_fake_chat "$chat_dir" "blocked"
HERDR_STUB_PANE_CONTENT_test_pane_8="$PROJECT_ROOT/tests/fixtures/pane-quoted-answer-no-box.txt" \
  export HERDR_STUB_PANE_CONTENT_test_pane_8
result=$(classify "$chat_dir" "test.pane.8")
t_is "working" "$result" "quoted answer is history; live Thinking means the turn is running"
rm -rf "$chat_dir"

unset HERDR_STUB_PANE_CONTENT_test_pane_1 HERDR_STUB_PANE_CONTENT_test_pane_2 \
  HERDR_STUB_PANE_CONTENT_test_pane_3 HERDR_STUB_PANE_CONTENT_test_pane_4 \
  HERDR_STUB_PANE_CONTENT_test_pane_5 HERDR_STUB_PANE_CONTENT_test_pane_6 \
  HERDR_STUB_PANE_CONTENT_test_pane_7 HERDR_STUB_PANE_CONTENT_test_pane_8 \
  HERDR_STUB_PANE_CONTENT_test_pane_9
unset HERDR_BIN_PATH
