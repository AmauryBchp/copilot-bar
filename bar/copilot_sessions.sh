#!/usr/bin/env bash
# Argos plugin: surface live GitHub Copilot CLI sessions in the GNOME top bar.
#
# Reads ~/.copilot-bar/sessions/<pid>.json (one file per live session,
# maintained by plugin/hooks/update-session-state.sh) and prints Argos's
# BitBar-compatible text protocol: lines before `---` are the panel button,
# lines after are the dropdown, and per-line parameters follow a `|`. The
# refresh interval lives in the installed filename (e.g. copilot-bar.20s.sh),
# not in here.
#
# Not `set -e`: the read loop uses non-zero exits from kill -0 as ordinary
# control flow.
set -uo pipefail

# Argos runs this plugin through a symlink in ~/.config/argos, so the sibling
# focus script has to be found relative to the real file, not the link.
SCRIPT_DIR="$(dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/state.sh
source "$SCRIPT_DIR/../lib/state.sh"

FOCUS_SCRIPT="$(/usr/bin/realpath "$SCRIPT_DIR/../focus/copilot_focus.sh")"

# A session idle longer ago than this is forgotten rather than freshly
# finished, and no longer earns a badge in the button line. Kept separate from
# JUST_FINISHED_WINDOW_MS in lib/state.sh so the badge and the dropdown state
# can never disagree about the boundary.
render() {
  local now=$1
  local -a states=() rows=()
  local count=0 badges=""
  local pid sid project state updated display

  while IFS=$'\t' read -r pid sid project state updated; do
    [[ -n "$pid" ]] || continue
    # Argos's line protocol gives `|` meaning (its parameter separator); a
    # project directory named with one would inject bogus parameters.
    project=${project//|/∣}
    # Session files outlive a crashed copilot process, so trust the process.
    kill -0 "$pid" 2>/dev/null || continue
    # A malformed timestamp must not take down a refresh that runs every few
    # seconds; derive_display_state's arithmetic would abort on a non-number.
    [[ "$updated" =~ ^[0-9]+$ ]] || continue

    count=$(( count + 1 ))
    display=$(derive_display_state "$state" "$updated" "$now")
    states+=("$display")

    # terminal=false keeps the focus script in the background.
    rows+=("$(state_icon "$display") $project — $(state_label "$display") $(format_age "$(( now - updated ))") | color=$(state_color "$display") bash=\"$FOCUS_SCRIPT $pid\" terminal=false")

    case "$display" in
      needs_input|just_finished) badges+="  $(state_icon "$display") $project" ;;
    esac
  done < <(read_sessions)

  local overall=dormant
  if (( ${#states[@]} )); then
    overall=$(printf '%s\n' "${states[@]}" | most_urgent)
  fi

  printf '✦ %d%s | color=%s\n' "$count" "$badges" "$(state_color "$overall")"
  printf -- '---\n'

  if (( ${#rows[@]} )); then
    printf '%s\n' "${rows[@]}"
  else
    printf 'No Copilot CLI sessions | color=%s\n' "$(state_color dormant)"
  fi
}

main() {
  # Argos launches plugins from a GUI process with its own PATH, so a missing
  # jq or wmctrl must say so visibly rather than rendering a plausible "no
  # sessions" (wmctrl is only used by the click action, but we check it here
  # too so the warning shows up before the user ever clicks).
  if ! command -v jq >/dev/null; then
    printf '✦ ⚠ | color=#fb4934\n'
    printf -- '---\n'
    printf 'jq not found in PATH | color=#fb4934\n'
    return 0
  fi
  if ! command -v wmctrl >/dev/null; then
    printf '✦ ⚠ | color=#fb4934\n'
    printf -- '---\n'
    printf 'wmctrl not found in PATH | color=#fb4934\n'
    return 0
  fi

  render "$(( $(date +%s) * 1000 ))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
