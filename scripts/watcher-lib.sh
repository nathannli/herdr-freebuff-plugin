#!/bin/sh
# Shared functions for the freebuff status watcher.
# Sourced by status-watcher.sh and by tests.
#
# Requires common.sh (for herdr_cmd) to be sourced first.
#
# Provides: classify, classify_signals, chat_dir_still_ours, detect_screen_state,
#           find_newest_chat, freebuff_paths, pane_freebuff_pid, pane_project_slug,
#           pane_pids, pin_own_chat_dir, should_report_state

# How many consecutive `idle` observations are required before dropping out of a
# non-idle state. A single failed pane read, or one transient screen frame, can
# otherwise flap the pane between working and idle.
IDLE_STREAK_REQUIRED=3

# Transient screen markers live at the bottom of the pane buffer. Matching the
# whole buffer means a user who merely quotes "[response interrupted]" in a
# prompt gets reported as idle.
SCREEN_TAIL_LINES=40

# One node invocation per poll returns every file-derived signal. It used to be
# five spawns (one per log pattern, plus detect_blocked, plus the dir scan) at
# 1.4 polls per second, per pane.
#
# Output is five whitespace-separated fields, with "-" standing for empty so
# that word splitting cannot shift positions:
#   activity_ms  start_ts  send_ts  finish_ts  blocked
classify_signals() {
  _dir="$1"
  _out=$(node -e '
    const fs=require("fs"),path=require("path");
    const dir=process.argv[1];
    const r={activity:0,start:"",send:"",finish:"",blocked:""};
    const readJson=p=>{try{return JSON.parse(fs.readFileSync(p,"utf8"))}catch(e){return null}};

    // Activity signal. messagesMtimeMs is the precise per-file mtime freebuff
    // records; a directory mtime only moves when entries are added or removed,
    // which is why it is a fallback rather than the primary signal.
    const meta=readJson(path.join(dir,"chat-meta.json"));
    if(meta&&typeof meta.messagesMtimeMs==="number")r.activity=meta.messagesMtimeMs;
    try{
      for(const f of fs.readdirSync(dir)){
        const st=fs.statSync(path.join(dir,f));
        if(st.isFile()&&st.mtimeMs>r.activity)r.activity=st.mtimeMs;
      }
    }catch(e){}
    try{const st=fs.statSync(dir);if(st.mtimeMs>r.activity)r.activity=st.mtimeMs}catch(e){}

    // Last occurrence of each timeline marker, scanning backwards.
    try{
      const lines=fs.readFileSync(path.join(dir,"log.jsonl"),"utf8").split("\n");
      const pats=[["start","Start agent"],["send","[send-message]"],["finish","Main prompt finished"]];
      for(let i=lines.length-1;i>=0;i--){
        let j=null;try{j=JSON.parse(lines[i])}catch(e){continue}
        if(!j||!j.msg||!j.timestamp)continue;
        for(const p of pats){ if(!r[p[0]]&&j.msg.indexOf(p[1])>=0)r[p[0]]=j.timestamp; }
        if(r.start&&r.send&&r.finish)break;
      }
    }catch(e){}

    // Unresolved ask-user block in the last AI message.
    const msgs=readJson(path.join(dir,"chat-messages.json"));
    if(Array.isArray(msgs)){
      let ai=-1,ui=-1;
      for(let i=0;i<msgs.length;i++){const m=msgs[i];if(m.variant==="ai")ai=i;if(m.variant==="user")ui=i}
      if(ai>=0){
        const blocks=(msgs[ai]&&Array.isArray(msgs[ai].blocks))?msgs[ai].blocks:[];
        const has=blocks.some(b=>{
          if(b.type==="ask-user")return true;
          if(b.type==="tool"&&b.toolName==="ask_user"){
            const q=b.input&&b.input.questions;
            return Array.isArray(q)&&q.length>0;
          }
          return false;
        });
        if(has&&ai>ui)r.blocked="blocked";
      }
    }

    const dash=v=>v===""?"-":String(v);
    process.stdout.write([Math.round(r.activity),dash(r.start),dash(r.send),dash(r.finish),dash(r.blocked)].join(" "));
  ' "$_dir" 2>/dev/null) || _out=""

  # Byte-wise locale for every comparison below: ISO timestamps only sort
  # correctly under C collation, and `[ > ]` uses strcoll.
  LC_ALL=C
  export LC_ALL

  if [ -z "$_out" ]; then
    SIG_ACTIVITY=0
    SIG_START=""
    SIG_SEND=""
    SIG_FINISH=""
    SIG_BLOCKED=""
    return 0
  fi

  # shellcheck disable=SC2086
  set -- $_out
  SIG_ACTIVITY="$1"
  SIG_START="$2"
  SIG_SEND="$3"
  SIG_FINISH="$4"
  SIG_BLOCKED="$5"
  [ "$SIG_START" = "-" ] && SIG_START=""
  [ "$SIG_SEND" = "-" ] && SIG_SEND=""
  [ "$SIG_FINISH" = "-" ] && SIG_FINISH=""
  [ "$SIG_BLOCKED" = "-" ] && SIG_BLOCKED=""
  return 0
}

# Find the newest chat directory in manicode config.
# Arguments: [project_slug] [min_mtime_ms]
#
# Shell implementation on purpose: this ran every poll and used to cost a node
# startup each time.
#
# stat only gives whole seconds, so the floor is compared at second resolution
# too. Comparing a second-resolution mtime against a millisecond floor would
# make a session created in the launch second compare as "older than launch".
find_newest_chat() {
  _slug="${1:-}"
  _floor_ms="${2:-0}"
  LC_ALL=C
  export LC_ALL
  _floor=$(( _floor_ms / 1000 ))
  _base="${HOME}/.config/manicode/projects"
  [ -d "$_base" ] || return 0

  _newest=""
  _newest_s=$_floor

  for _proj_dir in "$_base"/*; do
    [ -d "$_proj_dir/chats" ] || continue
    _proj=$(basename "$_proj_dir")
    if [ -n "$_slug" ] && [ "$_proj" != "$_slug" ]; then
      continue
    fi
    for _chat_dir in "$_proj_dir/chats"/*; do
      [ -d "$_chat_dir" ] || continue
      _ms=$(dir_mtime_ms "$_chat_dir")
      [ -n "$_ms" ] || continue
      # Compare in seconds throughout: the floor arrives in milliseconds but
      # stat only resolves whole seconds.
      _s=$(( _ms / 1000 ))
      if [ "$_s" -gt "$_newest_s" ] 2>/dev/null; then
        _newest_s=$_s
        _newest="$_chat_dir"
      fi
    done
  done

  printf '%s' "$_newest"
}

# Directory mtime in whole milliseconds.
# BSD stat and GNU stat spell this differently, and macOS is the primary target.
dir_mtime_ms() {
  _d="$1"
  _s=$(stat -c %Y "$_d" 2>/dev/null) || _s=$(stat -f %m "$_d" 2>/dev/null) || _s=""
  [ -n "$_s" ] || return 0
  printf '%d' "$(( _s * 1000 ))"
}

# Resolve the pane's project slug, which is the basename of its working
# directory. freebuff groups chats under projects/<slug>/, so this keeps a pane
# from following another project's session.
# Argument: pane_id. Echoes the slug, or empty string if it cannot be resolved.
pane_project_slug() {
  _pane_id="$1"
  [ -z "$_pane_id" ] && return 0
  # `pane get` always prints JSON and takes no --json flag.
  _info=$("$(herdr_cmd)" pane get "$_pane_id" 2>/dev/null) || return 0
  _cwd=$(printf '%s' "$_info" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{
        const j=JSON.parse(d);
        const p=(j.result&&j.result.pane)||j.pane||j;
        process.stdout.write(p.foreground_cwd||p.cwd||"");
      }catch{}
    })
  ' 2>/dev/null)
  [ -z "$_cwd" ] && return 0
  printf '%s' "$_cwd" | sed 's|/*$||; s|.*/||'
}

# List the pids herdr currently sees in a pane, one per line. This includes the
# watcher's own shell, so callers must filter by what they are looking for.
pane_pids() {
  _pane_id="$1"
  [ -z "$_pane_id" ] && return 0
  "$(herdr_cmd)" pane process-info --pane "$_pane_id" 2>/dev/null | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      try{
        const pi=JSON.parse(d).result.process_info;
        for(const p of (pi.foreground_processes||[])) if(p.pid) process.stdout.write(p.pid+"\n");
      }catch{}
    })
  ' 2>/dev/null
}

# Absolute paths that identify a real freebuff process.
#
# Matching on a substring of "freebuff" would adopt any pane running
# `vim freebuff-notes.md` or `grep freebuff`. Two real shapes exist, both
# observed live via `pane process-info`:
#   node /Users/…/fnm/node-versions/v24.21.0/installation/bin/freebuff
#   /Users/nathan/.config/manicode/freebuff
# The first is the parent whose pid stamps the chat logs, so it is the one the
# watcher must follow.
#
# The fnm path is matched by shape rather than by an exact path, because the
# node version and fnm layout differ per machine. Everything else is an exact
# path. FREEBUFF_BIN_PATH overrides the PATH-resolved binary for a custom
# install.
freebuff_paths() {
  printf '%s\n' \
    "${HOME}/.config/manicode/freebuff" \
    "${FREEBUFF_BIN_PATH:-/nonexistent/freebuff}"

  # fnm / nvm / asdf / mise node installs: <prefix>/bin/freebuff
  for _root in \
    "${HOME}/.local/share/fnm/node-versions"/*/installation/bin \
    "${HOME}/.nvm/versions/node"/*/bin \
    "${HOME}/.asdf/installs/nodejs"/*/bin \
    "${HOME}/.local/share/mise/installs/node"/*/bin; do
    [ -x "$_root/freebuff" ] && printf '%s\n' "$_root/freebuff"
  done

  # The plain `freebuff` on PATH, resolved.
  _onpath=$(command -v freebuff 2>/dev/null)
  if [ -n "$_onpath" ]; then
    case "$_onpath" in
      /*) printf '%s\n' "$_onpath" ;;
      *) printf '%s\n' "$(cd "$(dirname "$_onpath")" 2>/dev/null && pwd)/$(basename "$_onpath")" ;;
    esac
  fi
}

# Echo the pid of the freebuff process running in a pane, or nothing.
#
# Strict on purpose: this decides whether the plugin takes ownership of a pane
# the user started by hand, so a false positive writes herdr state into
# somebody's unrelated session. A false negative just means that pane keeps
# showing `unknown`, which is the status quo.
pane_freebuff_pid() {
  _pane_id="$1"
  [ -z "$_pane_id" ] && return 0

  _paths=$(freebuff_paths)
  [ -n "$_paths" ] || return 0

  "$(herdr_cmd)" pane process-info --pane "$_pane_id" 2>/dev/null |
    FREEBUFF_PATHS="$_paths" node -e '
      const paths = (process.env.FREEBUFF_PATHS || "").split("\n").filter(Boolean);
      const isFreebuff = (cmd) => {
        if (!cmd) return false;
        // The plugin never adopts its own processes.
        if (cmd.indexOf("status-watcher.sh") >= 0) return false;
        if (cmd.indexOf("attach-watches.sh") >= 0) return false;
        if (cmd.indexOf("adopt-watches.sh") >= 0) return false;
        if (cmd.indexOf("sweep-daemon.sh") >= 0) return false;
        return paths.some((p) => cmd === p || cmd.indexOf(p) >= 0);
      };
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        try{
          const pi=JSON.parse(d).result.process_info;
          for(const p of (pi.foreground_processes||[])){
            if(!p.pid) continue;
            if(isFreebuff(p.cmdline)){ process.stdout.write(p.pid+"\n"); return; }
          }
        }catch{}
      })
    ' 2>/dev/null | head -1
}

# List the distinct pids that have written a chat dir's log.jsonl. freebuff
# stamps every log line with the pid of the process that wrote it, so this is
# the session's real process identity.
chat_dir_pids() {
  [ -f "$1/log.jsonl" ] || return 0
  sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/log.jsonl" 2>/dev/null |
    sort -u
}

# Find the chat directory this pane's own freebuff process is writing to.
#
# This is the unambiguous pin. "Newest dir" cannot work: an idle session stops
# touching its dir, so any other concurrently active session becomes newest and
# takes over the state. Matching on the writer pid cannot misfire, and it needs
# no cooperation from freebuff beyond the pid it already logs.
#
# Arguments: pane_id [project_slug] [fallback_floor_ms]
# Echoes the chat dir, or empty string if this pane has not written one yet.
pin_own_chat_dir() {
  _pane_id="$1"
  _slug="${2:-}"
  _floor="${3:-0}"

  _own_pids=$(pane_pids "$_pane_id" | tr '\n' ' ')
  [ -n "$_own_pids" ] || return 0

  _base="${HOME}/.config/manicode/projects"
  [ -d "$_base" ] || return 0

  for _proj_dir in "$_base"/*; do
    [ -d "$_proj_dir/chats" ] || continue
    _proj=$(basename "$_proj_dir")
    if [ -n "$_slug" ] && [ "$_proj" != "$_slug" ]; then
      continue
    fi
    for _chat_dir in "$_proj_dir/chats"/*; do
      [ -d "$_chat_dir" ] || continue
      for _pid in $(chat_dir_pids "$_chat_dir"); do
        case " $_own_pids " in
          *" $_pid "*)
            printf '%s' "$_chat_dir"
            return 0
            ;;
        esac
      done
    done
  done

  # No pid match. Only a brand-new session may fall back to mtime, and only
  # because its floor proves the dir was created after this pane launched.
  #
  # A floor of 0 (both resume modes, and every restart re-attach) gets no
  # fallback at all. "Newest dir" cannot identify a resumed session: an idle
  # session stops touching its dir, so any other concurrently active session in
  # the same project is newer and takes over the state. A wrong pin is worse
  # than no pin, because a missing pin self-heals the moment freebuff writes its
  # first log line, while a wrong one reports another session's state forever.
  [ "$_floor" -gt 0 ] 2>/dev/null || return 0
  find_newest_chat "$_slug" "$_floor"
}

# Is the chat dir still being written by a process in this pane?
#
# Prints one of:
#   yes      the pane's pids and the dir's writer pids intersect
#   no       both sides are known and they do not intersect
#   unknown  either side could not be read, or the dir has no log yet
#
# `unknown` is deliberately not a failure. A pane whose process-info call failed
# has told us nothing, and treating that as a mismatch would unpin a correct pin
# every time herdr hiccups.
#
# Arguments: pane_id chat_dir
chat_dir_still_ours() {
  _pane_id="$1"
  _chat_dir="$2"

  [ -n "$_pane_id" ] && [ -n "$_chat_dir" ] || { printf unknown; return 0; }

  _dir_pids=$(chat_dir_pids "$_chat_dir" | tr '\n' ' ')
  [ -n "$_dir_pids" ] || { printf unknown; return 0; }

  _own_pids=$(pane_pids "$_pane_id" | tr '\n' ' ')
  [ -n "$_own_pids" ] || { printf unknown; return 0; }

  for _pid in $_dir_pids; do
    case " $_own_pids " in
      *" $_pid "*)
        printf yes
        return 0
        ;;
    esac
  done

  printf no
}

# Read pane screen content and classify the on-screen state.
# Uses herdr's `detection` source: the live bottom-buffer snapshot, which is the
# same buffer herdr's own agent screen manifests evaluate. `visible` is the
# scrolled viewport and misses content the agent has scrolled past.
#
# freebuff flushes chat files only at end-of-turn, so file-based detection
# cannot see transient UI states (live question popup, answer echo immediately
# after submission, response-interrupted text after Esc). Screen content fills
# those gaps.
#
# The ask_user popup renders a bordered dialog with a Submit button and the
# hint "↑↓ navigate • Enter select"; suggest_followups (optional end-of-turn
# follow-ups) does not. Either of those strings uniquely identifies the live
# ask_user state.
#
# After the user answers, freebuff echoes the choice: "Your answer: <text>"
# followed within <=2 lines by a bordered box around the chosen answer.
# After Esc, freebuff prints "[response interrupted]" directly.
#
# Argument: pane_id. Echoes one of:
#   blocked | interrupted | answered | thinking | ""
# Always returns 0 so callers under `set -e` cannot abort on a read failure.
detect_screen_state() {
  _pane_id="$1"
  [ -z "$_pane_id" ] && return 0
  _content=$("$(herdr_cmd)" pane read "$_pane_id" --source detection 2>/dev/null) || return 0
  [ -z "$_content" ] && return 0

  # Only the bottom of the buffer carries transient markers. The trailing
  # newline matters: grep -A2 cannot see past the last line without one.
  _tail=$(printf '%s\n' "$_content" | tail -n "$SCREEN_TAIL_LINES")

  # 1. Live popup — highest precedence
  printf '%s\n' "$_tail" | grep -qE "Enter select|↑↓ navigate" && { printf blocked; return; }

  # 2. Response interrupted (Esc) — chat files are still stale at this point
  printf '%s\n' "$_tail" | grep -qF '[response interrupted]' && { printf interrupted; return; }

  # 3. Answer just chosen — "Your answer:" followed within <=2 lines by
  #    a bordered box. The box is a strong signal that the answer-echo was
  #    rendered and the popup was dismissed.
  if printf '%s\n' "$_tail" | grep -A2 'Your answer:' | grep -qE '[╭│╰└┌]'; then
    printf answered
    return
  fi

  # 4. AI processing heartbeat — "• Thinking", "Thinking...", or "Working..."
  #     on screen. These persist for the entire duration of AI processing,
  #     bridging the gap between the "Your answer:" box scrolling off and
  #     file-based classification catching up (next Main prompt finished).
  #     The bullet "•" is Unicode U+2022.
  printf '%s\n' "$_tail" | grep -qE '• Thinking|Thinking\.\.\.|Working\.\.\.' && { printf thinking; return; }

  # 5. No signal
  return 0
}

# Classify freebuff's current state from log.jsonl timeline only.
# Argument: chat directory path. Echoes: working | idle.
_classify_timeline() {
  _chat_dir="$1"
  [ -d "$_chat_dir" ] || { printf idle; return; }

  classify_signals "$_chat_dir"

  _last_start="$SIG_START"
  if [ -n "$SIG_SEND" ]; then
    if [ -z "$_last_start" ] || [ "$SIG_SEND" \> "$_last_start" ]; then
      _last_start="$SIG_SEND"
    fi
  fi
  _last_finish="$SIG_FINISH"

  if [ -n "$_last_start" ] && [ -n "$_last_finish" ]; then
    if [ "$_last_start" \> "$_last_finish" ]; then
      printf working
    else
      printf idle
    fi
    return
  fi

  [ -n "$_last_start" ] && { printf working; return; }
  [ -n "$_last_finish" ] && { printf idle; return; }

  printf idle
}

# Classify freebuff's current state from chat files only.
# Argument: chat directory path. Echoes: blocked | working | idle.
_classify_files() {
  _chat_dir="$1"
  [ -d "$_chat_dir" ] || { printf idle; return; }

  # Blocked: unresolved ask-user block. freebuff finishes the turn (Main prompt
  # finished) BEFORE showing an ask-user question, so blocked must be checked
  # first regardless of turn state. Once the user replies, lastUserIdx >
  # lastAiIdx and blocked clears.
  classify_signals "$_chat_dir"
  [ "$SIG_BLOCKED" = "blocked" ] && { printf blocked; return; }

  _classify_timeline "$_chat_dir"
}

# Decide whether a state change should be reported now.
# Arguments: previous_state, next_state, consecutive_next_idle_count
# Echoes 1 to report, 0 to hold.
#
# Entering idle is debounced; every other transition reports immediately. A
# failed pane read makes one poll fall through to the timeline, which can say
# idle while the agent is still working.
should_report_state() {
  _prev="$1"
  _next="$2"
  _idle_streak="$3"

  [ "$_next" = "$_prev" ] && { printf 0; return; }

  if [ "$_next" = "idle" ] && [ "$_prev" != "idle" ] &&
     [ "$_idle_streak" -lt "$IDLE_STREAK_REQUIRED" ]; then
    printf 0
    return
  fi

  printf 1
}

# Classify freebuff's current state.
#
# When pane_id is available, the visible screen content is authoritative:
#   - ask_user popup visible  → blocked
#   - answer echo / thinking heartbeat on screen → working
#   - [response interrupted] on screen → idle
#   - no screen signal → use timeline from log files (stale blocked is ignored
#     since the popup is visually absent)
#
# Without pane_id, falls back to full file-based detection (including the
# ask_user block check from chat-messages.json).
classify() {
  _chat_dir="$1"
  _pane_id="${2:-}"

  if [ -n "$_pane_id" ]; then
    _sig=$(detect_screen_state "$_pane_id")

    # Screen signals are authoritative
    case "$_sig" in
      blocked)
        printf blocked
        return
        ;;
      interrupted)
        printf idle
        return
        ;;
      answered|thinking)
        printf working
        return
        ;;
      "")
        # No screen signal — popup is visually absent so any file-based
        # "blocked" would be stale. Use the log timeline directly.
        _classify_timeline "$_chat_dir"
        return
        ;;
    esac
  fi

  # No pane_id: file-based detection (including blocked check from messages)
  _classify_files "$_chat_dir"
}
