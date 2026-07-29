#!/usr/bin/env bash
# Shared state-derivation library for copilot-bar. Sourced by bar/copilot_sessions.sh
# and bin/copilot-bar-feed — one implementation of the state machine, two renderers.
#
# The plugin (plugin/hooks/update-session-state.sh) writes the raw hook-derived
# state (working/needs_input/idle) per session. This library turns that plus the
# age of the last update into the four states the UI actually shows.

SESSIONS_DIR="${COPILOT_BAR_SESSIONS_DIR:-$HOME/.copilot-bar/sessions}"

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

# One TSV row per session file: pid, sessionId, project, raw state, stateUpdatedAt.
#
# One jq invocation per file: a parse error aborts jq immediately, so a single
# truncated or malformed file must not take every file after it down with it.
read_sessions() {
  local files f

  shopt -s nullglob
  files=("$SESSIONS_DIR"/*.json)
  shopt -u nullglob

  (( ${#files[@]} )) || return 0

  for f in "${files[@]}"; do
    jq -r '[.pid, .sessionId, .project, .state, .stateUpdatedAt] | @tsv' "$f" 2>/dev/null
  done
}
