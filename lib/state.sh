#!/usr/bin/env bash
# Shared state-derivation library for copilot-bar. Sourced by bar/copilot_sessions.sh
# and bin/copilot-bar-feed — one implementation of the state machine, two renderers.
#
# read_sessions() derives each session's raw state (working/needs_input/idle)
# straight from Copilot CLI's own per-session event log at
# ~/.copilot/session-state/<uuid>/events.jsonl — no plugin or hook install
# required. derive_display_state() then turns that plus the age of the last
# update into the four states the UI actually shows.

SESSION_STATE_DIR="${COPILOT_BAR_SESSION_STATE_DIR:-$HOME/.copilot/session-state}"

# How many trailing lines of events.jsonl to read per session on every
# refresh. A turn/tool-call cycle is a handful of lines, so 500 comfortably
# covers many turns back without ever reading a whole (potentially 10s of MB)
# file. Overridable for tests and for unusually bursty sessions.
EVENTS_TAIL_LINES="${COPILOT_BAR_EVENTS_TAIL_LINES:-500}"

# jq state machine: reduces a tailed window of events.jsonl lines (one JSON
# object per line, wrapped into an array by `jq -s`) into a single
# {state, updated} outcome.
#
# Tracked across the reduce: inTurn (are we between assistant.turn_start and
# .turn_end), pendingPerm (permission.requested request ids still waiting on
# a matching permission.completed, restricted to kind shell/write/url — the
# genuine user-facing Yes/No prompts; kind "hook" is a silent auto-decision
# and never blocks anyone) and pendingAsk (tool.execution_start toolCallIds
# for toolName "ask_user" still waiting on a matching tool.execution_complete
# — the "choose between these options" dialogs, which fire no hook at all
# but do leave this durable open/close pair in the event log).
#
# needs_input wins over everything else: as long as either pending set is
# non-empty the session stays needs_input regardless of turn boundaries.
# `abort` (user pressed Ctrl-C/Esc mid-turn) drops both pending sets and
# returns straight to idle — whatever was pending got cancelled along with
# the turn, and control is back with the user.
read -r -d '' STATE_MACHINE_JQ << 'JQ_EOF'
def toEpochMs:
  sub("\\.[0-9]+Z$"; "Z")
  | strptime("%Y-%m-%dT%H:%M:%SZ")
  | mktime
  | . * 1000;

reduce .[] as $e (
  {state: "idle", updated: 0, inTurn: false, pendingPerm: {}, pendingAsk: {}};
  ($e.type) as $t
  | (if $e.timestamp then ($e.timestamp | toEpochMs) else .updated end) as $ts
  | if $t == "session.start" or $t == "session.resume" then
      .state = "idle" | .updated = $ts | .inTurn = false | .pendingPerm = {} | .pendingAsk = {}
    elif $t == "assistant.turn_start" then
      .inTurn = true
      | (if (.pendingPerm | length == 0) and (.pendingAsk | length == 0) then .state = "working" | .updated = $ts else . end)
    elif $t == "assistant.turn_end" then
      .inTurn = false
      | (if (.pendingPerm | length == 0) and (.pendingAsk | length == 0) then .state = "idle" | .updated = $ts else . end)
    elif $t == "permission.requested" then
      ($e.data.permissionRequest.kind // $e.data.kind) as $kind
      | if ($kind == "shell" or $kind == "write" or $kind == "url") then
          .pendingPerm[$e.data.requestId] = true | .state = "needs_input" | .updated = $ts
        else . end
    elif $t == "permission.completed" then
      .pendingPerm |= del(.[$e.data.requestId])
      | (if (.pendingPerm | length == 0) and (.pendingAsk | length == 0) then .state = (if .inTurn then "working" else "idle" end) | .updated = $ts else . end)
    elif $t == "tool.execution_start" and $e.data.toolName == "ask_user" then
      .pendingAsk[$e.data.toolCallId] = true | .state = "needs_input" | .updated = $ts
    elif $t == "tool.execution_complete" then
      .pendingAsk |= del(.[$e.data.toolCallId])
      | (if (.pendingPerm | length == 0) and (.pendingAsk | length == 0) then .state = (if .inTurn then "working" else "idle" end) | .updated = $ts else . end)
    elif $t == "abort" then
      .inTurn = false | .pendingPerm = {} | .pendingAsk = {} | .state = "idle" | .updated = $ts
    elif $t == "session.shutdown" then
      .state = "idle" | .updated = $ts | .inTurn = false | .pendingPerm = {} | .pendingAsk = {}
    else . end
)
| [.state, (.updated | tostring)]
| @tsv
JQ_EOF

# A session idle for longer than this is dormant rather than freshly finished.
JUST_FINISHED_WINDOW_MS=300000

derive_display_state() {
  local state=$1 updated_at=$2 now=$3

  case "$state" in
    needs_input) printf 'needs_input\n' ;;
    working)     printf 'working\n' ;;
    idle)
      if (( now - updated_at < JUST_FINISHED_WINDOW_MS )); then
        printf 'just_finished\n'
      else
        printf 'dormant\n'
      fi
      ;;
    *) printf 'dormant\n' ;;
  esac
}

# Gruvbox neutral/faded variants, copied from claude-bar — chosen for
# readability on both a light-tinted panel and a dark dropdown.
state_color() {
  case "$1" in
    needs_input)   printf '#fb4934\n' ;;
    just_finished) printf '#b57614\n' ;;
    working)       printf '#458588\n' ;;
    *)             printf '#7c6f64\n' ;;
  esac
}

state_icon() {
  case "$1" in
    needs_input)   printf '●\n' ;;
    just_finished) printf '○\n' ;;
    working)       printf '◐\n' ;;
    *)             printf '·\n' ;;
  esac
}

state_label() {
  case "$1" in
    needs_input)   printf 'needs input\n' ;;
    just_finished) printf 'just finished\n' ;;
    working)       printf 'working\n' ;;
    *)             printf 'idle\n' ;;
  esac
}

# Coarse human-readable age; precision past the unit is noise at a 20s refresh.
format_age() {
  local seconds=$(( $1 / 1000 ))

  if (( seconds < 60 )); then
    printf '%ds\n' "$seconds"
  elif (( seconds < 3600 )); then
    printf '%dm\n' "$(( seconds / 60 ))"
  else
    printf '%dh\n' "$(( seconds / 3600 ))"
  fi
}

# Sort key (ascending = more urgent), not a display value.
state_rank() {
  case "$1" in
    needs_input)   printf '0\n' ;;
    just_finished) printf '1\n' ;;
    working)       printf '2\n' ;;
    *)             printf '3\n' ;;
  esac
}

# Collapse display states read from stdin into the single most urgent one.
most_urgent() {
  local best=dormant state

  while read -r state; do
    case "$state" in
      needs_input)
        best=needs_input
        ;;
      just_finished)
        [[ "$best" != needs_input ]] && best=just_finished
        ;;
      working)
        [[ "$best" == dormant ]] && best=working
        ;;
    esac
  done

  printf '%s\n' "$best"
}

# One TSV row per live session: pid, sessionId, project, raw state, stateUpdatedAt.
#
# Enumerates ~/.copilot/session-state/<uuid>/inuse.<pid>.lock files — these
# are written by Copilot CLI itself, one per session directory, encoding the
# owning process's pid in the filename. The lock file can outlive the process
# (confirmed: it is never cleaned up on crash), so — same as the old
# hook-file approach — callers must still filter on `kill -0 "$pid"`; this
# function does not do that itself.
#
# One jq invocation per session: a parse error (e.g. a truncated line at the
# very end of a file mid-write) aborts that jq call immediately, so a single
# broken session must not take every session after it down with it.
read_sessions() {
  local -a locks
  local lockfile dir sid pid cwd project row state updated

  shopt -s nullglob
  locks=("$SESSION_STATE_DIR"/*/inuse.*.lock)
  shopt -u nullglob

  (( ${#locks[@]} )) || return 0

  for lockfile in "${locks[@]}"; do
    dir=$(dirname "$lockfile")
    sid=$(basename "$dir")

    pid=$(basename "$lockfile")
    pid=${pid#inuse.}
    pid=${pid%.lock}
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    [[ -f "$dir/events.jsonl" ]] || continue

    # workspace.yaml is a flat, simple YAML file (no nesting) — a plain sed
    # for the cwd: line avoids depending on a YAML parser that isn't
    # installed on the machine.
    cwd=$(sed -n 's/^cwd: *//p' "$dir/workspace.yaml" 2>/dev/null | head -n1)
    cwd=${cwd%\"}
    cwd=${cwd#\"}
    project=$(basename "${cwd:-unknown}")

    row=$(tail -n "$EVENTS_TAIL_LINES" "$dir/events.jsonl" 2>/dev/null | jq -s -r "$STATE_MACHINE_JQ" 2>/dev/null)
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r state updated <<< "$row"

    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$sid" "$project" "$state" "$updated"
  done
}
