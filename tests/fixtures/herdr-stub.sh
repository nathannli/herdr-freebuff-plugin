#!/bin/sh
# Fake herdr binary for testing.
# Records each invocation to a call log at $HERDR_CALL_LOG (default: stdout).
#
# Usage: set HERDR_CALL_LOG=/path/to/log or use --output-last /tmp/last_call
# The stub accepts the same flag layout as real herdr and validates required args.
# It never actually connects to a socket.

CALL_LOG="${HERDR_CALL_LOG:-}"
SELF="$(basename "$0")"
OUTPUT_LAST="${HERDR_STUB_LAST:-}"

# Log the full invocation
log_call() {
  line="$SELF $*"
  if [ -n "$CALL_LOG" ]; then
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$line" >> "$CALL_LOG"
  fi
  if [ -n "$OUTPUT_LAST" ]; then
    printf '%s\n' "$line" > "$OUTPUT_LAST"
  fi
}

# Parse subcommand
subcmd="${1:-}"
shift 2>/dev/null || :

log_call "$subcmd $*"

case "$subcmd" in
  pane)
    pane_sub="${1:-}"
    shift 2>/dev/null || :
    case "$pane_sub" in
      report-agent)
        # validate required args
        state=""
        source=""
        agent=""
        seq=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --source) source="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --state) state="$2"; shift 2 ;;
            --seq) seq="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -z "$source" ] || [ -z "$agent" ] || [ -z "$state" ]; then
          echo "ERROR: stub missing required --source/--agent/--state" >&2
          exit 1
        fi
        # Models a dead or restarted herdr server: every report is refused.
        if [ -n "${HERDR_STUB_FAIL_REPORT:-}" ]; then
          echo "ERROR: stub simulating unreachable herdr server" >&2
          exit 1
        fi
        echo "ok report-agent $state seq=$seq"
        ;;
      release-agent)
        # validate required args
        source=""
        agent=""
        seq=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --source) source="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --seq) seq="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -z "$source" ] || [ -z "$agent" ]; then
          echo "ERROR: stub missing required --source/--agent" >&2
          exit 1
        fi
        echo "ok release-agent source=$source agent=$agent seq=$seq"
        ;;
      report-metadata)
        source=""
        agent=""
        display_agent=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --source) source="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --display-agent) display_agent="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "ok report-metadata display-agent=$display_agent"
        ;;
      report-agent-session)
        echo "ok report-agent-session"
        ;;
      list)
        # Pane ids come from HERDR_STUB_PANES (space separated) so tests can
        # model which panes still exist.
        first=1
        printf '{"result":{"panes":['
        for p in ${HERDR_STUB_PANES:-w1:p1}; do
          [ "$first" -eq 1 ] || printf ','
          first=0
          printf '{"pane_id":"%s"}' "$p"
        done
        printf '],"type":"pane_list"}}\n'
        ;;
      process-info)
        # Pids come from HERDR_STUB_PANE_PIDS (space separated), or from
        # HERDR_STUB_PANE_PROCS as "pid:cmdline" pairs separated by "|". The
        # watcher pins its chat dir by writer pid, so tests must supply the pid
        # that wrote the fake chat log.
        printf '{"result":{"process_info":{"foreground_process_group_id":1,"foreground_processes":['
        first=1
        if [ -n "${HERDR_STUB_PANE_PROCS:-}" ]; then
          OLDIFS=$IFS; IFS='|'
          for entry in $HERDR_STUB_PANE_PROCS; do
            IFS=$OLDIFS
            ep=${entry%%:*}
            ec=${entry#*:}
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"pid":%s,"name":"proc","cmdline":"%s"}' "$ep" "$ec"
            IFS='|'
          done
          IFS=$OLDIFS
        else
          for p in ${HERDR_STUB_PANE_PIDS:-}; do
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"pid":%s,"name":"freebuff","cmdline":"/usr/local/bin/freebuff"}' "$p"
          done
        fi
        printf ']}}}\n'
        ;;
      get)
        # `pane get` takes no --json flag; it always prints JSON.
        pane_id=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --*) shift ;;
            *) pane_id="$1"; shift ;;
          esac
        done
        cwd="${HERDR_STUB_PANE_CWD:-$PWD}"
        printf '{"result":{"type":"pane_info","pane":{"pane_id":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
          "$pane_id" "$cwd" "$cwd"
        ;;
      read)
        # Parse: pane read <pane_id> --source visible --lines N
        pane_id=""
        lines=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --source) shift 2 ;;
            --lines) lines="$2"; shift 2 ;;
            --*) shift ;;
            *) pane_id="$1"; shift ;;
          esac
        done
        # Look up content from env var based on pane id (dots/dashes -> underscores)
        key="HERDR_STUB_PANE_CONTENT_$(printf '%s' "$pane_id" | tr '.-' '__')"
        eval "val=\${$key:-}"
        # Fallback to a shared content file (useful for e2e tests where env
        # vars are inherited at fork and cannot be changed per-phase).
        if [ -z "$val" ] && [ -n "${HERDR_STUB_CONTENT_FILE:-}" ]; then
          [ -f "$HERDR_STUB_CONTENT_FILE" ] && val="$HERDR_STUB_CONTENT_FILE"
        fi
        if [ -z "$val" ]; then
          # No content configured — return empty
          exit 0
        fi
        cat "$val" 2>/dev/null
        ;;
      *)
        echo "ERROR: unknown pane subcommand: $pane_sub" >&2
        exit 1
        ;;
    esac
    ;;
  notification)
    sub="${1:-}"
    shift 2>/dev/null || :
    echo "ok notification $sub $*"
    ;;
  *)
    echo "ERROR: unknown herdr subcommand: $subcmd" >&2
    exit 1
    ;;
esac
