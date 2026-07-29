#!/usr/bin/env bash
# Assertions for copilot-bar. Run: ./tests/test_states.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
source ./lib/state.sh

failures=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

NOW=1785183600000
MINUTE=60000

check "needs_input state means the session needs input" \
  needs_input "$(derive_display_state needs_input "$NOW" "$NOW")"

check "working state means the session is working" \
  working "$(derive_display_state working "$NOW" "$NOW")"

check "idle 30s ago just finished" \
  just_finished "$(derive_display_state idle "$((NOW - 30000))" "$NOW")"

check "idle just under 5min still counts as just finished" \
  just_finished "$(derive_display_state idle "$((NOW - 299999))" "$NOW")"

check "idle at exactly 5min is dormant" \
  dormant "$(derive_display_state idle "$((NOW - 5 * MINUTE))" "$NOW")"

check "idle for hours is dormant" \
  dormant "$(derive_display_state idle "$((NOW - 180 * MINUTE))" "$NOW")"

check "an unrecognised raw state is treated as dormant" \
  dormant "$(derive_display_state something_new "$NOW" "$NOW")"

check "needs_input wins over everything else" \
  needs_input "$(printf '%s\n' working dormant needs_input just_finished | most_urgent)"

check "just_finished wins over working" \
  just_finished "$(printf '%s\n' working just_finished dormant | most_urgent)"

check "working wins over dormant" \
  working "$(printf '%s\n' dormant working dormant | most_urgent)"

check "all dormant collapses to dormant" \
  dormant "$(printf '%s\n' dormant dormant | most_urgent)"

check "no states at all collapses to dormant" \
  dormant "$(printf '' | most_urgent)"

check "needs_input is red" "#fb4934" "$(state_color needs_input)"
check "just_finished is yellow" "#b57614" "$(state_color just_finished)"
check "working is blue" "#458588" "$(state_color working)"
check "dormant is grey" "#7c6f64" "$(state_color dormant)"

check "needs_input shows a filled dot" "●" "$(state_icon needs_input)"
check "just_finished shows a hollow dot" "○" "$(state_icon just_finished)"
check "working shows a half dot" "◐" "$(state_icon working)"
check "dormant shows a middot" "·" "$(state_icon dormant)"

check "seconds under a minute" "12s" "$(format_age 12000)"
check "zero is zero seconds" "0s" "$(format_age 0)"
check "59s stays in seconds" "59s" "$(format_age 59999)"
check "a minute is minutes" "1m" "$(format_age 60000)"
check "59m stays in minutes" "59m" "$(format_age 3599999)"
check "an hour is hours" "1h" "$(format_age 3600000)"
check "three hours" "3h" "$(format_age 10800000)"

# --- read_sessions ----------------------------------------------------------
# Fixtures carry PID_PLACEHOLDER so we can substitute a pid that is genuinely
# running (our own) and prove the dead-process filter matters: read_sessions
# itself does not filter dead pids (callers do, via kill -0), so this only
# proves the raw TSV rows come through correctly.

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
now_ms=$(( $(date +%s) * 1000 ))
for f in tests/fixtures/*.json; do
  sed -e "s/PID_PLACEHOLDER/$$/" -e "s/TIMESTAMP_PLACEHOLDER/$now_ms/" "$f" > "$fixture_dir/$(basename "$f")"
done

rows=$(SESSIONS_DIR="$fixture_dir" read_sessions)

check "read_sessions emits one row per well-formed file" \
  "6" "$(printf '%s\n' "$rows" | grep -c .)"

check "read_sessions carries the project name through" \
  "1" "$(printf '%s\n' "$rows" | grep -cF $'\tdeltatom\t')"

check "the unparseable file produces no row and does not abort the batch" \
  "0" "$(printf '%s\n' "$rows" | grep -cF 'unparseable')"

# --- Argos rendering ---------------------------------------------------------

out=$(COPILOT_BAR_SESSIONS_DIR="$fixture_dir" ./bar/copilot_sessions.sh)
title=$(printf '%s\n' "$out" | sed -n '1p')
menu=$(printf '%s\n' "$out" | sed -n '/^---$/,$p' | tail -n +2)

check "the title counts the four well-formed live sessions" \
  "1" "$(printf '%s' "$title" | grep -c '✦ 4')"

check "the title badges the needs_input session" \
  "arthur" "$(printf '%s' "$title" | sed -n 's/.*● \([a-z]*\).*/\1/p')"

check "the title is tinted by the most urgent state" \
  "color=#fb4934" "$(printf '%s' "$title" | sed -n 's/.*| \(color=[^ ]*\).*/\1/p')"

check "the dropdown lists the working session" \
  "1" "$(printf '%s\n' "$menu" | grep -cE '^◐ deltatom — working [0-9]+s \| color=#458588 bash=')"

check "the dropdown lists the dormant session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '· pipe∣farm — idle')"

check "the dropdown lists the needs_input session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '● arthur — needs input')"

check "the dead session appears nowhere" \
  "" "$(printf '%s\n' "$out" | grep -o 'ghost')"

check "the malformed timestamp is skipped rather than crashing" \
  "" "$(printf '%s\n' "$out" | grep -o 'broken')"

check "a pipe in the project name is escaped in the dropdown" \
  "1" "$(printf '%s\n' "$menu" | grep -cF 'pipe∣farm')"

check "a raw pipe in the project name never reaches the output" \
  "" "$(printf '%s\n' "$out" | grep -F 'pipe|farm')"

check "every dropdown row is clickable" \
  "$(printf '%s\n' "$menu" | grep -c .)" \
  "$(printf '%s\n' "$menu" | grep -cF "bash=\"$PWD/focus/copilot_focus.sh $$\" terminal=false")"

link_dir=$(mktemp -d)
ln -s "$PWD/bar/copilot_sessions.sh" "$link_dir/copilot-bar.20s.sh"
link_out=$(COPILOT_BAR_SESSIONS_DIR="$fixture_dir" "$link_dir/copilot-bar.20s.sh")
rm -rf "$link_dir"

check "run through a symlink the rows still point at the real focus script" \
  "4" "$(printf '%s\n' "$link_out" | grep -cF "bash=\"$PWD/focus/copilot_focus.sh")"

empty_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir" "$empty_dir"' EXIT
empty_out=$(COPILOT_BAR_SESSIONS_DIR="$empty_dir" ./bar/copilot_sessions.sh)

check "with no sessions the title counts zero" \
  "✦ 0 | color=#7c6f64" "$(printf '%s\n' "$empty_out" | sed -n '1p')"

check "with no sessions the dropdown says so" \
  "No Copilot CLI sessions | color=#7c6f64" \
  "$(printf '%s\n' "$empty_out" | sed -n '/^---$/,$p' | tail -n +2)"

no_jq_out=$(PATH=/nonexistent /bin/bash "$PWD/bar/copilot_sessions.sh" 2>/dev/null)

check "with jq missing the title warns instead of lying about zero" \
  "✦ ⚠ | color=#fb4934" "$(printf '%s\n' "$no_jq_out" | sed -n '1p')"

check "with jq missing the dropdown says why" \
  "jq not found in PATH | color=#fb4934" \
  "$(printf '%s\n' "$no_jq_out" | sed -n '/^---$/,$p' | tail -n +2)"

no_wmctrl_out=$(PATH="$(dirname "$(command -v jq)")" /bin/bash "$PWD/bar/copilot_sessions.sh" 2>/dev/null)

check "with wmctrl missing (but jq present) the title still warns" \
  "✦ ⚠ | color=#fb4934" "$(printf '%s\n' "$no_wmctrl_out" | sed -n '1p')"

check "with wmctrl missing the dropdown says why" \
  "wmctrl not found in PATH | color=#fb4934" \
  "$(printf '%s\n' "$no_wmctrl_out" | sed -n '/^---$/,$p' | tail -n +2)"

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
