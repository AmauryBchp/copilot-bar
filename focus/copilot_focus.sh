#!/usr/bin/env bash
# Bring the terminal window running a given Copilot CLI session to the front.
#
# The terminal in use (Terminator) is a single process for every window it
# owns, so a session's pid cannot be resolved to an X11 window through the
# process tree — every window shares the same _NET_WM_PID. The link is made
# instead by writing an OSC 2 title escape to the session's own tty: the title
# lands on whichever window has that tty open, whatever else has focus. The
# window is then found by title with `wmctrl -l` and raised with `wmctrl -ia`.
#
# This is the same trick claude-bar uses for Ghostty via an AppleScript
# dictionary, generalized to any X11 terminal that honors OSC 2 — wmctrl reads
# window titles the way AppleScript's `terminal` objects exposed them.
set -uo pipefail

# Argos and Ulauncher both run this script from a GUI process's PATH, which
# may not carry wmctrl. Appended rather than prepended so a test's PATH (with
# a stub wmctrl/ps ahead of it) still takes priority.
PATH="${PATH}:/usr/bin:/bin"

# Injectable for tests: production always targets /dev. A test points this at
# a scratch directory it can write files into and inspect, since a real
# /dev/pts entry cannot be created without a genuine pty.
DEV_PREFIX="${COPILOT_BAR_DEV_PREFIX:-/dev}"

usage() {
  printf 'usage: %s <pid>\n' "$0" >&2
  exit 64
}

list_windows() {
  wmctrl -l
}

set_title() {
  printf '\033]2;%s\007' "$2" > "$DEV_PREFIX/$1" 2>/dev/null
}

focus_session() {
  local pid=$1 tty marker before id previous attempt

  # Argos and Ulauncher both run this script from a GUI process's PATH; a
  # missing wmctrl must say so on stderr rather than silently doing nothing,
  # which is what a click would otherwise look like.
  if ! command -v wmctrl >/dev/null; then
    printf 'wmctrl not found in PATH\n' >&2
    return 1
  fi

  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$tty" || "$tty" == '?' ]]; then
    printf 'pid %s has no controlling terminal\n' "$pid" >&2
    return 1
  fi

  # Read every window's title before one of them is overwritten, so the
  # window the marker ends up identifying can be put back to what it said.
  before=$(list_windows) || return 1

  marker="copilot-bar:${pid}"
  set_title "$tty" "$marker"

  # A few short retries: the terminal needs a moment to process the escape
  # sequence and repaint its title before wmctrl can see it.
  id=""
  for attempt in 1 2 3 4 5; do
    id=$(list_windows | awk -v m="$marker" '$0 ~ m { print $1; exit }')
    [[ -n "$id" ]] && break
    sleep 0.2
  done

  if [[ -z "$id" ]]; then
    printf 'no window found for pid %s\n' "$pid" >&2
    return 1
  fi

  wmctrl -ia "$id"

  # Restore the window's previous title so the marker doesn't linger on
  # screen. An empty result (a window opened since `before` was read) clears
  # the title instead, which is rendered as the terminal's own default.
  previous=$(printf '%s\n' "$before" | awk -v id="$id" '$1 == id { $1=$2=$3=""; sub(/^ +/, ""); print }')
  set_title "$tty" "$previous"
}

case "${1:-}" in
  "")       usage ;;
  *[!0-9]*) usage ;;
  *)        focus_session "$1" ;;
esac
