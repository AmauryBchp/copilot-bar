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
  "5" "$(printf '%s\n' "$rows" | grep -c .)"

check "read_sessions carries the project name through" \
  "1" "$(printf '%s\n' "$rows" | grep -cF $'\tdeltatom\t')"

check "the unparseable file produces no row and does not abort the batch" \
  "0" "$(printf '%s\n' "$rows" | grep -cF 'unparseable')"

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
