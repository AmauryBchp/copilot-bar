# copilot-bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build copilot-bar — a menu bar (Argos) and keyboard switcher (Ulauncher) for GitHub Copilot CLI sessions on Ubuntu, with click/select-to-focus on the right terminal window, per the approved design in `docs/superpowers/specs/2026-07-28-copilot-bar-design.md`.

**Architecture:** A Copilot CLI plugin uses native hooks (`sessionStart`, `preToolUse`, `notification`, `stop`, `sessionEnd`) to maintain one JSON state file per live session in `~/.copilot-bar/sessions/<pid>.json`. A shared bash library (`lib/state.sh`) turns that raw state into a display state (`needs_input`/`just_finished`/`working`/`dormant`). Two renderers consume it: an Argos script for the GNOME top bar, and a JSON feed script consumed by a Ulauncher Python extension. Both call a `wmctrl`-based focus script that writes an OSC-title marker to the session's tty, finds the matching X11 window, and activates it.

**Tech Stack:** Bash (`jq`, `wmctrl`, `ps`), Python 3 (Ulauncher extension, stdlib only), GitHub Copilot CLI plugin hooks.

## Global Constraints

- Session state files live at `~/.copilot-bar/sessions/<pid>.json`, overridable via `COPILOT_BAR_SESSIONS_DIR` (tests always override this — never touch the real directory).
- `pid` is always the value of the `COPILOT_LOADER_PID` environment variable available inside a hook process — this is the actual OS pid of the running `copilot` process, confirmed by direct experiment (see design spec, "Confirmed via experimentation").
- The "just finished" window is 5 minutes (300000 ms), matching claude-bar.
- Colors/icons/labels (copied verbatim from claude-bar, they're just Gruvbox hex + Unicode dots):
  - `needs_input`: `#fb4934`, `●`, "needs input"
  - `just_finished`: `#b57614`, `○`, "just finished"
  - `working`: `#458588`, `◐`, "working"
  - `dormant`: `#7c6f64`, `·`, "idle"
- Every script that shells out to a sibling script resolves its own location via `dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")"`, never `$0` or a relative path — both Argos and Ulauncher may invoke scripts through a symlink.
- No placeholders, no partial output: a missing `jq` or `wmctrl`, a malformed session file, or a dead pid must degrade visibly and gracefully, never crash the whole render.

---

### Task 1: Repo scaffold and shared state library

**Files:**
- Create: `lib/state.sh`
- Create: `tests/test_states.sh`
- Modify: (none)

**Interfaces:**
- Produces (used by every later task): `derive_display_state(state, updated_at_ms, now_ms)`, `state_color(display_state)`, `state_icon(display_state)`, `state_label(display_state)`, `format_age(age_ms)`, `state_rank(display_state)`, `most_urgent()` (reads display states from stdin, one per line), `read_sessions()` (reads `$SESSIONS_DIR/*.json`, prints `pid\tsessionId\tproject\tstate\tstateUpdatedAt` TSV rows, one `jq` invocation per file so a single malformed file can't abort the batch), `SESSIONS_DIR` (env-overridable via `COPILOT_BAR_SESSIONS_DIR`), `JUST_FINISHED_WINDOW_MS=300000`.

- [ ] **Step 1: Create `lib/state.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable and create the test harness**

```bash
chmod +x lib/state.sh
```

Create `tests/test_states.sh`:

```bash
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

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
```

```bash
chmod +x tests/test_states.sh
```

- [ ] **Step 3: Run the tests and verify they pass**

Run: `./tests/test_states.sh`
Expected: every line printed starts with `ok   -`, ending with `all checks passed` and exit code 0.

- [ ] **Step 4: Commit**

```bash
git add lib/state.sh tests/test_states.sh
git commit -m "Add shared state-derivation library with unit tests

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Session fixtures and the dead-process / malformed-file guards

**Files:**
- Create: `tests/fixtures/live_working.json`
- Create: `tests/fixtures/live_needs_input.json`
- Create: `tests/fixtures/live_dormant.json`
- Create: `tests/fixtures/dead.json`
- Create: `tests/fixtures/malformed.json`
- Create: `tests/fixtures/unparseable.json`
- Modify: `tests/test_states.sh` (append `read_sessions` checks)

**Interfaces:**
- Consumes: `read_sessions` and `SESSIONS_DIR` from Task 1's `lib/state.sh`.
- Produces: a fixtures directory later tasks (3, 4) also read from, and the `PID_PLACEHOLDER`/`TIMESTAMP_PLACEHOLDER` substitution convention used throughout the rest of the test suite.

- [ ] **Step 1: Create the fixtures**

`tests/fixtures/live_working.json` (a live, working session — pid substituted at test time):

```json
{"pid":PID_PLACEHOLDER,"sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/home/dev/deltatom","project":"deltatom","state":"working","stateUpdatedAt":TIMESTAMP_PLACEHOLDER}
```

`tests/fixtures/live_needs_input.json`:

```json
{"pid":PID_PLACEHOLDER,"sessionId":"22222222-2222-2222-2222-222222222222","cwd":"/home/dev/arthur","project":"arthur","state":"needs_input","stateUpdatedAt":TIMESTAMP_PLACEHOLDER}
```

`tests/fixtures/live_dormant.json` (idle for hours — fixed timestamp, no placeholder needed since dormant only requires "long ago"):

```json
{"pid":PID_PLACEHOLDER,"sessionId":"33333333-3333-3333-3333-333333333333","cwd":"/home/dev/pipe|farm","project":"pipe|farm","state":"idle","stateUpdatedAt":1785183600000}
```

`tests/fixtures/dead.json` (a pid that is never running — no placeholder):

```json
{"pid":999999,"sessionId":"44444444-4444-4444-4444-444444444444","cwd":"/home/dev/ghost","project":"ghost","state":"working","stateUpdatedAt":1785183600000}
```

`tests/fixtures/malformed.json` (non-numeric timestamp, must be skipped rather than crash arithmetic):

```json
{"pid":PID_PLACEHOLDER,"sessionId":"55555555-5555-5555-5555-555555555555","cwd":"/home/dev/broken","project":"broken","state":"working","stateUpdatedAt":"not-a-number"}
```

`tests/fixtures/unparseable.json` (invalid JSON entirely, on purpose):

```
this is not json at all {
```

- [ ] **Step 2: Append `read_sessions` checks to `tests/test_states.sh`**

Insert before the final `if (( failures ))` block:

```bash
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

rows=$(COPILOT_BAR_SESSIONS_DIR="$fixture_dir" read_sessions)

check "read_sessions emits one row per well-formed file" \
  "5" "$(printf '%s\n' "$rows" | grep -c .)"

check "read_sessions carries the project name through" \
  "1" "$(printf '%s\n' "$rows" | grep -cF $'\tdeltatom\t')"

check "the unparseable file produces no row and does not abort the batch" \
  "0" "$(printf '%s\n' "$rows" | grep -cF 'unparseable')"
```

- [ ] **Step 3: Run the tests and verify they pass**

Run: `./tests/test_states.sh`
Expected: all `ok` lines including the three new `read_sessions` checks, `all checks passed`, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures tests/test_states.sh
git commit -m "Add session fixtures and read_sessions coverage

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Argos menu bar renderer

**Files:**
- Create: `bar/copilot_sessions.sh`
- Modify: `tests/test_states.sh` (append rendering checks)

**Interfaces:**
- Consumes: `lib/state.sh`'s `derive_display_state`, `state_color`, `state_icon`, `state_label`, `format_age`, `most_urgent`, `read_sessions`, `SESSIONS_DIR`. Also references `focus/copilot_focus.sh` by path (created in Task 5 — the render only builds a string with that path in it, it does not need the file to exist yet for this task's tests to pass, since no test in this task clicks a row).
- Produces: `bar/copilot_sessions.sh`, an executable script printing the Argos/BitBar text protocol to stdout, runnable standalone or symlinked.

- [ ] **Step 1: Create `bar/copilot_sessions.sh`**

```bash
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

FOCUS_SCRIPT="$SCRIPT_DIR/../focus/copilot_focus.sh"

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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bar/copilot_sessions.sh
mkdir -p focus && touch focus/copilot_focus.sh && chmod +x focus/copilot_focus.sh
```

(`focus/copilot_focus.sh` is a placeholder-free empty executable for now — Task 5 fills it in. It only needs to exist so `readlink -f` in this task's tests resolves a real path.)

- [ ] **Step 3: Append rendering checks to `tests/test_states.sh`**

Insert after the `read_sessions` block from Task 2, before the final `if (( failures ))`:

```bash
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

no_jq_out=$(PATH=/bin "$PWD/bar/copilot_sessions.sh")

check "with jq missing the title warns instead of lying about zero" \
  "✦ ⚠ | color=#fb4934" "$(printf '%s\n' "$no_jq_out" | sed -n '1p')"

check "with jq missing the dropdown says why" \
  "jq not found in PATH | color=#fb4934" \
  "$(printf '%s\n' "$no_jq_out" | sed -n '/^---$/,$p' | tail -n +2)"

no_wmctrl_out=$(PATH="$(dirname "$(command -v jq)")" "$PWD/bar/copilot_sessions.sh")

check "with wmctrl missing (but jq present) the title still warns" \
  "✦ ⚠ | color=#fb4934" "$(printf '%s\n' "$no_wmctrl_out" | sed -n '1p')"

check "with wmctrl missing the dropdown says why" \
  "wmctrl not found in PATH | color=#fb4934" \
  "$(printf '%s\n' "$no_wmctrl_out" | sed -n '/^---$/,$p' | tail -n +2)"
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./tests/test_states.sh`
Expected: all `ok` lines, `all checks passed`, exit code 0. (Note: "every dropdown row is clickable" and the symlink check depend on `focus/copilot_focus.sh` existing as a file, which Step 2 created — they do not depend on its contents.)

- [ ] **Step 5: Commit**

```bash
git add bar/copilot_sessions.sh focus/copilot_focus.sh tests/test_states.sh
git commit -m "Add Argos menu bar renderer with rendering tests

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: JSON session feed for Ulauncher

**Files:**
- Create: `bin/copilot-bar-feed`
- Modify: `tests/test_states.sh` (append feed checks)

**Interfaces:**
- Consumes: `lib/state.sh` (same functions as Task 3).
- Produces: `bin/copilot-bar-feed`, an executable printing `{"items":[{"title":...,"subtitle":...,"pid":"..."}]}` sorted by urgency then by longest wait, or `{"items":[],"error":"jq not found in PATH"}` / `{"items":[],"error":"wmctrl not found in PATH"}` if either tool is missing. Consumed by the Ulauncher extension in Task 7.

- [ ] **Step 1: Create `bin/copilot-bar-feed`**

```bash
#!/usr/bin/env bash
# JSON session feed for the Ulauncher extension (ulauncher/copilot-bar/main.py).
#
# Reuses lib/state.sh's state functions wholesale — the only new logic here is
# the urgency ranking and the JSON assembly. jq builds the JSON rather than
# printf, because a project directory holding a quote or backslash would
# otherwise emit a feed the extension cannot parse.
set -uo pipefail

SCRIPT_DIR="$(dirname "$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/state.sh
source "$SCRIPT_DIR/../lib/state.sh"

# One TSV row per live session: rank, age, title, subtitle, pid. Rank ascending
# then age descending within a rank, so the longest-waiting session in a given
# state sorts first — the one you meant among several needing input.
session_rows() {
  local now=$1
  local pid sid project state updated display age

  while IFS=$'\t' read -r pid sid project state updated; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    [[ "$updated" =~ ^[0-9]+$ ]] || continue

    age=$(( now - updated ))
    display=$(derive_display_state "$state" "$updated" "$now")

    printf '%s\t%s\t%s %s\t%s · %s · pid %s\t%s\n' \
      "$(state_rank "$display")" "$age" \
      "$(state_icon "$display")" "$project" \
      "$(state_label "$display")" "$(format_age "$age")" "$pid" \
      "$pid"
  done < <(read_sessions)
}

feed() {
  session_rows "$1" \
    | sort -t$'\t' -k1,1n -k2,2nr \
    | cut -f3- \
    | jq -Rs '
        [ split("\n")[]
          | select(length > 0)
          | split("\t")
          | { title: .[0], subtitle: .[1], pid: .[2] } ]
        | if length == 0
          then [ { title: "No Copilot CLI sessions", pid: null } ]
          else . end
        | { items: . }
      '
}

main() {
  if ! command -v jq >/dev/null; then
    printf '{"items":[],"error":"jq not found in PATH"}\n'
    return 0
  fi
  if ! command -v wmctrl >/dev/null; then
    printf '{"items":[],"error":"wmctrl not found in PATH"}\n'
    return 0
  fi

  feed "$(( $(date +%s) * 1000 ))"
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
mkdir -p bin
chmod +x bin/copilot-bar-feed
```

- [ ] **Step 3: Append feed checks to `tests/test_states.sh`**

Insert after the Argos rendering block, before `if (( failures ))`:

```bash
# --- copilot-bar-feed --------------------------------------------------------

feed_out=$(COPILOT_BAR_SESSIONS_DIR="$fixture_dir" ./bin/copilot-bar-feed)

check "the feed is valid JSON" \
  "ok" "$(printf '%s\n' "$feed_out" | jq -e . >/dev/null 2>&1 && echo ok)"

check "the feed is ordered by urgency, then by longest wait" \
  "● arthur ◐ deltatom · pipe∣farm" \
  "$(printf '%s\n' "$feed_out" | jq -r '[.items[].title] | join(" ")')"

check "every item carries its pid" \
  "$$ $$ $$" "$(printf '%s\n' "$feed_out" | jq -r '[.items[].pid] | join(" ")')"

check "the subtitle carries state, age and pid" \
  "1" "$(printf '%s\n' "$feed_out" | jq -r '.items[0].subtitle' | grep -cE "^needs input · [0-9]+[smh] · pid $$\$")"

feed_empty=$(COPILOT_BAR_SESSIONS_DIR="$empty_dir" ./bin/copilot-bar-feed)

check "with no sessions the feed says so, unactionably" \
  "No Copilot CLI sessions " \
  "$(printf '%s\n' "$feed_empty" | jq -r '.items[0] | "\(.title) \(.pid // "")"')"

no_jq_feed=$(PATH=/bin "$PWD/bin/copilot-bar-feed")

check "with jq missing the feed reports the error, not a crash" \
  '{"items":[],"error":"jq not found in PATH"}' "$no_jq_feed"

no_wmctrl_feed=$(PATH="$(dirname "$(command -v jq)")" "$PWD/bin/copilot-bar-feed")

check "with wmctrl missing (but jq present) the feed reports that error" \
  '{"items":[],"error":"wmctrl not found in PATH"}' "$no_wmctrl_feed"
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./tests/test_states.sh`
Expected: all `ok` lines, `all checks passed`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add bin/copilot-bar-feed tests/test_states.sh
git commit -m "Add JSON session feed for the Ulauncher extension

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Window focus via wmctrl and an OSC-title marker

**Files:**
- Modify: `focus/copilot_focus.sh` (currently an empty placeholder file from Task 3)
- Modify: `tests/test_states.sh` (append focus checks)

**Interfaces:**
- Produces: `focus/copilot_focus.sh <pid>`, exit 0 on success, exit 1 with a stderr message if the pid has no controlling tty or no window is found, exit 64 with a usage message if called with no/non-numeric argument. Honors `COPILOT_BAR_DEV_PREFIX` (default `/dev`) as the directory prefix for writing tty escape sequences — this seam exists purely for testing (a genuine `/dev/pts/N` cannot be created without a real pty), production always uses the default.

- [ ] **Step 1: Write `focus/copilot_focus.sh`**

```bash
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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x focus/copilot_focus.sh
```

- [ ] **Step 3: Append focus checks to `tests/test_states.sh`**

Insert after the feed block, before `if (( failures ))`:

```bash
# --- window focus ------------------------------------------------------------
# wmctrl and ps are stubbed: a real X11 window and a real /dev/pts entry can't
# be created in a test. The stub wmctrl reads/writes the marker through a
# plain file under COPILOT_BAR_DEV_PREFIX instead of a real tty device, and
# the stub ps reports a fixed fake tty name for any pid.

focus_fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir" "$empty_dir" "$focus_fixture_dir"' EXIT

fake_bin="$focus_fixture_dir/bin"
fake_dev="$focus_fixture_dir/dev"
mkdir -p "$fake_bin" "$fake_dev"
: > "$fake_dev/faketty0"
printf 'wmctrl calls:\n' > "$focus_fixture_dir/wmctrl_calls.log"

cat > "$fake_bin/ps" << 'EOF'
#!/usr/bin/env bash
echo " faketty0"
EOF
chmod +x "$fake_bin/ps"

cat > "$fake_bin/wmctrl" << EOF
#!/usr/bin/env bash
TITLE_FILE="$fake_dev/faketty0"
case "\$1" in
  -l)
    raw=\$(cat "\$TITLE_FILE" 2>/dev/null)
    title=\$(printf '%s' "\$raw" | sed -n 's/.*\\x1b\\]2;\\(.*\\)\\x07.*/\\1/p')
    [[ -z "\$title" ]] && title="Terminator - old title"
    echo "0x0400001  0 host \$title"
    ;;
  -ia)
    echo "activated \$2" >> "$focus_fixture_dir/wmctrl_calls.log"
    ;;
esac
EOF
chmod +x "$fake_bin/wmctrl"

focus_result=$(PATH="$fake_bin:$PATH" COPILOT_BAR_DEV_PREFIX="$fake_dev" ./focus/copilot_focus.sh 4242; echo "exit:$?")

check "focusing a session activates its window" \
  "1" "$(grep -c 'activated 0x0400001' "$focus_fixture_dir/wmctrl_calls.log")"

check "focusing a session exits 0" \
  "exit:0" "$(printf '%s\n' "$focus_result" | tail -1)"

check "focusing a session restores the previous title" \
  "1" "$(cat -v "$fake_dev/faketty0" | grep -cF 'Terminator - old title')"

check "an empty argument prints usage and exits 64" \
  "64" "$(./focus/copilot_focus.sh >/dev/null 2>&1; echo $?)"

check "a non-numeric argument prints usage and exits 64" \
  "64" "$(./focus/copilot_focus.sh abc >/dev/null 2>&1; echo $?)"

check "a PATH without wmctrl fails with a clear message" \
  "1" "$(PATH=/bin ./focus/copilot_focus.sh 4242 2>&1 >/dev/null | grep -cF 'wmctrl not found')"

rm -f "$fake_dev/faketty0.notfound" # no-op, keeps shellcheck quiet about unused var if any
cat > "$fake_bin/ps" << 'EOF'
#!/usr/bin/env bash
echo " ?"
EOF
chmod +x "$fake_bin/ps"

check "a pid with no controlling terminal fails with a clear message" \
  "1" "$(PATH="$fake_bin:$PATH" COPILOT_BAR_DEV_PREFIX="$fake_dev" ./focus/copilot_focus.sh 4242 2>&1 >/dev/null | grep -cF 'no controlling terminal')"
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `./tests/test_states.sh`
Expected: all `ok` lines, `all checks passed`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add focus/copilot_focus.sh tests/test_states.sh
git commit -m "Add wmctrl-based window focus with OSC title marker

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: Copilot CLI plugin (hooks → session state files)

**Files:**
- Create: `plugin/plugin.json`
- Create: `plugin/hooks.json`
- Create: `plugin/hooks/update-session-state.sh`
- Create: `tests/test_plugin_hooks.sh`

**Interfaces:**
- Consumes: `COPILOT_LOADER_PID` and `COPILOT_PLUGIN_ROOT` environment variables set by Copilot CLI around every hook invocation (confirmed present, see design spec), and the JSON payload on the hook command's stdin (confirmed fields: `sessionId`, `cwd`, `timestamp`, plus `initialPrompt` on `sessionStart` and `reason` on `sessionEnd`).
- Produces: `~/.copilot-bar/sessions/<pid>.json` (or `$COPILOT_BAR_SESSIONS_DIR/<pid>.json` under test), written atomically (temp file + `mv`), matching the schema every earlier task's fixtures already assume: `{pid, sessionId, cwd, project, state, stateUpdatedAt}`.

- [ ] **Step 1: Write `plugin/hooks/update-session-state.sh`**

```bash
#!/usr/bin/env bash
# Copilot CLI hook: maintain ~/.copilot-bar/sessions/<pid>.json for the running
# session, so bar/copilot_sessions.sh and bin/copilot-bar-feed have a live
# status signal to read — Copilot CLI itself keeps no such file.
#
# Registered once per hook event in ../hooks.json, each registration passing
# its own event name as $1. The hook JSON payload arrives on stdin.
set -uo pipefail

EVENT="${1:-}"
SESSIONS_DIR="${COPILOT_BAR_SESSIONS_DIR:-$HOME/.copilot-bar/sessions}"
mkdir -p "$SESSIONS_DIR"

# postToolUse never changes the displayed state (the agent usually keeps
# working right after a tool call), so there is nothing to persist. Wired in
# hooks.json anyway for completeness/future use, but a pure no-op today.
if [[ "$EVENT" == "postToolUse" ]]; then
  exit 0
fi

# COPILOT_LOADER_PID is the OS pid of the running `copilot` process — the
# same role the pid plays in Claude Code's own `<pid>.json` filename.
# Without it there's no reliable key for the state file, so do nothing.
PID="${COPILOT_LOADER_PID:-}"
[[ -n "$PID" ]] || exit 0

FILE="$SESSIONS_DIR/$PID.json"

if [[ "$EVENT" == "sessionEnd" ]]; then
  rm -f "$FILE"
  exit 0
fi

PAYLOAD=$(cat)

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.sessionId // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)
INITIAL_PROMPT=$(printf '%s' "$PAYLOAD" | jq -r '.initialPrompt // empty' 2>/dev/null)
PROJECT=$(basename "${CWD:-unknown}")
NOW_MS=$(( $(date +%s%3N) ))

case "$EVENT" in
  sessionStart)
    if [[ -n "$INITIAL_PROMPT" ]]; then STATE=working; else STATE=idle; fi
    ;;
  preToolUse)   STATE=working ;;
  notification) STATE=needs_input ;;
  stop)         STATE=idle ;;
  *) exit 0 ;;
esac

TMP=$(mktemp "$SESSIONS_DIR/.tmp.XXXXXX")
jq -n --arg pid "$PID" --arg sessionId "$SESSION_ID" --arg cwd "$CWD" \
      --arg project "$PROJECT" --arg state "$STATE" --argjson updatedAt "$NOW_MS" \
  '{pid: ($pid|tonumber), sessionId: $sessionId, cwd: $cwd, project: $project, state: $state, stateUpdatedAt: $updatedAt}' \
  > "$TMP"
mv "$TMP" "$FILE"
```

- [ ] **Step 2: Write `plugin/hooks.json`**

```json
{
  "hooks": {
    "sessionStart": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" sessionStart" }
    ],
    "preToolUse": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" preToolUse" }
    ],
    "postToolUse": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" postToolUse" }
    ],
    "notification": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" notification" }
    ],
    "stop": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" stop" }
    ],
    "sessionEnd": [
      { "type": "command", "command": "\"${COPILOT_PLUGIN_ROOT}/hooks/update-session-state.sh\" sessionEnd" }
    ]
  },
  "version": 1
}
```

- [ ] **Step 3: Write `plugin/plugin.json`**

```json
{
  "name": "copilot-bar",
  "version": "1.0.0",
  "description": "Maintains live session state files for the copilot-bar menu bar and Ulauncher integrations.",
  "hooks": "hooks.json"
}
```

- [ ] **Step 4: Make the hook script executable**

```bash
chmod +x plugin/hooks/update-session-state.sh
```

- [ ] **Step 5: Write `tests/test_plugin_hooks.sh`, driving the hook script directly with the exact payload shapes confirmed in the design spec**

```bash
#!/usr/bin/env bash
# Drives plugin/hooks/update-session-state.sh the way Copilot CLI does: event
# name as $1, JSON payload on stdin, COPILOT_LOADER_PID in the environment.
# Run: ./tests/test_plugin_hooks.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

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

sessions_dir=$(mktemp -d)
trap 'rm -rf "$sessions_dir"' EXIT
export COPILOT_BAR_SESSIONS_DIR="$sessions_dir"
export COPILOT_LOADER_PID=424242

run_hook() {
  printf '%s' "$2" | ./plugin/hooks/update-session-state.sh "$1"
}

run_hook sessionStart '{"sessionId":"s1","timestamp":1,"cwd":"/tmp/proj-a","source":"new","initialPrompt":"hello"}'

check "sessionStart with an initial prompt writes state=working" \
  "working" "$(jq -r .state "$sessions_dir/424242.json")"

check "sessionStart writes the project name from cwd" \
  "proj-a" "$(jq -r .project "$sessions_dir/424242.json")"

run_hook preToolUse '{"sessionId":"s1","timestamp":2,"cwd":"/tmp/proj-a","toolName":"bash","toolArgs":"{}"}'

check "preToolUse writes state=working" \
  "working" "$(jq -r .state "$sessions_dir/424242.json")"

before_json=$(cat "$sessions_dir/424242.json")
run_hook postToolUse '{"sessionId":"s1","timestamp":3,"cwd":"/tmp/proj-a","toolName":"bash","toolArgs":"{}","toolResult":{"resultType":"success"}}'

check "postToolUse leaves the state file untouched" \
  "$before_json" "$(cat "$sessions_dir/424242.json")"

run_hook notification '{"sessionId":"s1","timestamp":4,"cwd":"/tmp/proj-a"}'

check "notification writes state=needs_input" \
  "needs_input" "$(jq -r .state "$sessions_dir/424242.json")"

run_hook stop '{"sessionId":"s1","timestamp":5,"cwd":"/tmp/proj-a"}'

check "stop writes state=idle" \
  "idle" "$(jq -r .state "$sessions_dir/424242.json")"

run_hook sessionEnd '{"sessionId":"s1","timestamp":6,"cwd":"/tmp/proj-a","reason":"complete"}'

check "sessionEnd removes the state file" \
  "0" "$(ls "$sessions_dir"/*.json 2>/dev/null | grep -c .)"

unset COPILOT_LOADER_PID
run_hook sessionStart '{"sessionId":"s2","timestamp":1,"cwd":"/tmp/proj-b"}'

check "without COPILOT_LOADER_PID no file is written" \
  "0" "$(ls "$sessions_dir"/*.json 2>/dev/null | grep -c .)"

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
```

```bash
chmod +x tests/test_plugin_hooks.sh
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `./tests/test_plugin_hooks.sh`
Expected: all `ok` lines, `all checks passed`, exit code 0.

- [ ] **Step 7: Manually confirm the `notification` and `stop` payload shapes against a real interactive session**

The design spec flags these two hooks as unconfirmed against a real interactive session (only `sessionStart`/`preToolUse`/`postToolUse`/`sessionEnd` were captured directly). Before relying on this plugin day to day:

```bash
mkdir -p /tmp/copilot-bar-hook-debug
cat > /tmp/copilot-bar-hook-debug/plugin.json << 'EOF'
{"name":"hook-debug","version":"1.0.0","hooks":"hooks.json"}
EOF
cat > /tmp/copilot-bar-hook-debug/hooks.json << 'EOF'
{
  "hooks": {
    "notification": [{"type":"command","command":"bash -c 'cat >> /tmp/copilot-bar-hook-debug/notification.log'"}],
    "stop": [{"type":"command","command":"bash -c 'cat >> /tmp/copilot-bar-hook-debug/stop.log'"}]
  },
  "version": 1
}
EOF
copilot plugin install /tmp/copilot-bar-hook-debug
```

Then, in a fresh terminal, run `copilot` interactively, ask it to do something that requires a permission prompt (without `--allow-all-tools`), approve it, let it finish, and exit. Inspect:

```bash
cat /tmp/copilot-bar-hook-debug/notification.log
cat /tmp/copilot-bar-hook-debug/stop.log
```

Confirm both payloads include a `sessionId` field (the only field `update-session-state.sh` reads from them, besides the always-present `cwd`). If either is missing `sessionId`, adjust `plugin/hooks/update-session-state.sh`'s `jq -r '.sessionId // empty'` line to match whatever field is actually present before proceeding, and re-run `./tests/test_plugin_hooks.sh`. Then clean up:

```bash
copilot plugin uninstall hook-debug
rm -rf /tmp/copilot-bar-hook-debug
```

- [ ] **Step 8: Commit**

```bash
git add plugin tests/test_plugin_hooks.sh
git commit -m "Add Copilot CLI plugin maintaining live session state via hooks

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 7: Ulauncher extension

**Files:**
- Create: `ulauncher/copilot-bar/manifest.json`
- Create: `ulauncher/copilot-bar/versions.json`
- Create: `ulauncher/copilot-bar/main.py`
- Create: `ulauncher/copilot-bar/images/icon.png`
- Create: `tests/test_ulauncher_main.py`

**Interfaces:**
- Consumes: `bin/copilot-bar-feed`'s JSON shape (`{"items":[{"title","subtitle","pid"}], "error"?}`) from Task 4, and `focus/copilot_focus.sh <pid>` from Task 5.
- Produces: `build_items(feed_json: dict) -> list[dict]` (pure function, no Ulauncher import — the piece this task's tests exercise directly) and `feed_path()` / `focus_path()` (path helpers resolving siblings relative to `main.py`'s own location, the same convention every bash script in this repo uses).

- [ ] **Step 1: Write `ulauncher/copilot-bar/main.py`**

```python
#!/usr/bin/env python3
"""Ulauncher extension: list live Copilot CLI sessions, focus on Enter.

Delegates all state logic to bin/copilot-bar-feed (itself built on
lib/state.sh) rather than re-implementing the state machine in Python — one
implementation, read from two renderers (Argos and this extension).

build_items() and the path helpers below have no dependency on the ulauncher
package, so they can be unit tested directly (tests/test_ulauncher_main.py)
without installing Ulauncher itself.
"""
import json
import os
import subprocess

EXTENSION_DIR = os.path.dirname(os.path.realpath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(EXTENSION_DIR))


def feed_path():
    return os.path.join(REPO_ROOT, "bin", "copilot-bar-feed")


def focus_path():
    return os.path.join(REPO_ROOT, "focus", "copilot_focus.sh")


def build_items(feed_json):
    """Turn bin/copilot-bar-feed's JSON into a list of {title, subtitle, pid}.

    A feed reporting a missing jq/wmctrl surfaces as one unselectable
    "copilot-bar: <error>" row, matching the Argos renderer's behavior of
    showing an explicit warning rather than a misleading empty list. A feed
    with no live sessions surfaces as one unselectable "No Copilot CLI
    sessions" row. Both cases use pid None so ItemEnterEventListener knows
    not to try to focus anything for them.
    """
    if feed_json.get("error"):
        return [{"title": f"copilot-bar: {feed_json['error']}", "subtitle": "", "pid": None}]

    items = [
        {"title": it["title"], "subtitle": it.get("subtitle", ""), "pid": it["pid"]}
        for it in feed_json.get("items", [])
        if it.get("pid")
    ]
    return items or [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}]


def fetch_items():
    try:
        result = subprocess.run(
            [feed_path()], capture_output=True, text=True, timeout=5, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return [{"title": "copilot-bar: failed to run copilot-bar-feed", "subtitle": "", "pid": None}]

    try:
        feed_json = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return [{"title": "copilot-bar: copilot-bar-feed returned invalid JSON", "subtitle": "", "pid": None}]

    return build_items(feed_json)


def focus(pid):
    subprocess.Popen(
        [focus_path(), str(pid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


if __name__ == "__main__":
    from ulauncher.api.client.Extension import Extension
    from ulauncher.api.client.EventListener import EventListener
    from ulauncher.api.shared.event import KeywordQueryEvent, ItemEnterEvent
    from ulauncher.api.shared.item.ExtensionResultItem import ExtensionResultItem
    from ulauncher.api.shared.action.RenderResultListAction import RenderResultListAction
    from ulauncher.api.shared.action.HideWindowAction import HideWindowAction
    from ulauncher.api.shared.action.ExtensionCustomAction import ExtensionCustomAction

    class CopilotBarExtension(Extension):
        def __init__(self):
            super().__init__()
            self.subscribe(KeywordQueryEvent, KeywordQueryEventListener())
            self.subscribe(ItemEnterEvent, ItemEnterEventListener())

    class KeywordQueryEventListener(EventListener):
        def on_event(self, event, extension):
            result_items = [
                ExtensionResultItem(
                    icon="images/icon.png",
                    name=item["title"],
                    description=item["subtitle"],
                    on_enter=(
                        ExtensionCustomAction({"pid": item["pid"]}, keep_app_open=False)
                        if item["pid"]
                        else HideWindowAction()
                    ),
                )
                for item in fetch_items()
            ]
            return RenderResultListAction(result_items)

    class ItemEnterEventListener(EventListener):
        def on_event(self, event, extension):
            data = event.get_data()
            pid = data.get("pid")
            if pid:
                focus(pid)
            return HideWindowAction()

    CopilotBarExtension().run()
```

- [ ] **Step 2: Write `ulauncher/copilot-bar/manifest.json`**

```json
{
  "required_api_version": "2",
  "name": "copilot-bar",
  "description": "List live GitHub Copilot CLI sessions and focus their terminal window.",
  "developer_name": "AmauryBchp",
  "icon": "images/icon.png",
  "options": {
    "query_debounce": 0.1
  },
  "preferences": [
    {
      "id": "copilot_bar_kw",
      "type": "keyword",
      "name": "Copilot sessions",
      "description": "List live Copilot CLI sessions",
      "default_value": "cc"
    }
  ]
}
```

- [ ] **Step 3: Write `ulauncher/copilot-bar/versions.json`**

```json
[
  {"required_api_version": "2", "commit": "main"}
]
```

- [ ] **Step 4: Create the icon**

```bash
mkdir -p ulauncher/copilot-bar/images
base64 -d > ulauncher/copilot-bar/images/icon.png << 'EOF'
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR42mNwbe34TwlmGDVg1IBRA4aLAQC6DVEfURMMEwAAAABJRU5ErkJggg==
EOF
```

(A flat 16×16 icon in the same blue used for `working` sessions — placeholder art, easy to swap for something nicer later; verify with `file ulauncher/copilot-bar/images/icon.png`, expected: `PNG image data, 16 x 16, 8-bit/color RGBA, non-interlaced`.)

- [ ] **Step 5: Write `tests/test_ulauncher_main.py`**

```python
#!/usr/bin/env python3
"""Unit tests for the pure-Python parts of the Ulauncher extension.
Run: python3 tests/test_ulauncher_main.py
"""
import importlib.util
import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN_PATH = os.path.join(REPO_ROOT, "ulauncher", "copilot-bar", "main.py")

spec = importlib.util.spec_from_file_location("copilot_bar_main", MAIN_PATH)
main = importlib.util.module_from_spec(spec)
# main.py only imports the ulauncher package inside `if __name__ == "__main__"`,
# so loading it as a library module never requires ulauncher to be installed.
spec.loader.exec_module(main)


class BuildItemsTests(unittest.TestCase):
    def test_drops_items_without_a_pid_and_falls_back_to_no_sessions(self):
        feed = {"items": [{"title": "No Copilot CLI sessions", "pid": None}]}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}],
        )

    def test_keeps_items_with_a_pid(self):
        feed = {
            "items": [
                {"title": "● arthur", "subtitle": "needs input · 3s · pid 123", "pid": "123"}
            ]
        }
        self.assertEqual(
            main.build_items(feed),
            [{"title": "● arthur", "subtitle": "needs input · 3s · pid 123", "pid": "123"}],
        )

    def test_missing_items_key_yields_no_sessions_row(self):
        self.assertEqual(
            main.build_items({}),
            [{"title": "No Copilot CLI sessions", "subtitle": "", "pid": None}],
        )

    def test_missing_subtitle_defaults_to_empty_string(self):
        feed = {"items": [{"title": "◐ deltatom", "pid": "456"}]}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "◐ deltatom", "subtitle": "", "pid": "456"}],
        )

    def test_error_key_yields_one_unselectable_warning_row(self):
        feed = {"items": [], "error": "wmctrl not found in PATH"}
        self.assertEqual(
            main.build_items(feed),
            [{"title": "copilot-bar: wmctrl not found in PATH", "subtitle": "", "pid": None}],
        )


class PathHelperTests(unittest.TestCase):
    def test_feed_path_points_at_bin_copilot_bar_feed(self):
        self.assertTrue(main.feed_path().endswith(os.path.join("bin", "copilot-bar-feed")))

    def test_focus_path_points_at_focus_copilot_focus_sh(self):
        self.assertTrue(
            main.focus_path().endswith(os.path.join("focus", "copilot_focus.sh"))
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 6: Run the tests and verify they pass**

Run: `python3 tests/test_ulauncher_main.py -v`
Expected: 6 tests, all `ok`, ending with `OK`.

- [ ] **Step 7: Commit**

```bash
git add ulauncher tests/test_ulauncher_main.py
git commit -m "Add Ulauncher extension for keyboard session switching

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 8: README and end-to-end install verification

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: every path and command from Tasks 1–7 (this task only documents and wires them together; it creates no new script).

- [ ] **Step 1: Write `README.md`**

```markdown
# copilot-bar

Keep an eye on every running `copilot-cli` session at once, from your GNOME
top bar and from the keyboard — a port of
[jcgay/claude-bar](https://github.com/jcgay/claude-bar) from Claude Code +
macOS to GitHub Copilot CLI + Ubuntu. Design rationale lives in
`docs/superpowers/specs/2026-07-28-copilot-bar-design.md`.

```
menu bar:  ✦ 3  ● arthur

── dropdown ──────────────────
● arthur      needs input 8s
◐ deltatom    working 1m
· pipe∣farm   idle 3h
```

| Icon | State | Color |
| --- | --- | --- |
| `●` | Needs input (permission prompt) | red |
| `○` | Finished within the last 5 minutes | yellow |
| `◐` | Working | blue |
| `·` | Idle for over 5 minutes | grey |

## Install

### 1. Requirements

```bash
sudo apt install jq wmctrl
```

Argos (GNOME Shell extension) and Ulauncher are assumed already installed.
This has only been tested on X11 — `wmctrl` needs a real or XWayland-visible
window, so it will not work on native Wayland.

### 2. The Copilot CLI plugin

From your checkout of this repository:

```bash
copilot plugin install "$PWD/plugin"
```

This maintains `~/.copilot-bar/sessions/<pid>.json` for every live session —
see `docs/superpowers/specs/2026-07-28-copilot-bar-design.md` for exactly
which hook sets which state. Verify it's live:

```bash
copilot plugin list   # should include copilot-bar
```

### 3. Argos menu bar

```bash
mkdir -p ~/.config/argos
ln -sfn "$PWD/bar/copilot_sessions.sh" ~/.config/argos/copilot-bar.20s.sh
```

The `20s` in that filename is the refresh interval — Argos reads it from the
name. Symlinking rather than copying keeps the checkout as the source of
truth, so `git pull` is the whole update path.

### 4. Ulauncher extension

```bash
ln -sfn "$PWD/ulauncher/copilot-bar" ~/.local/share/ulauncher/extensions/copilot-bar
```

Restart Ulauncher (or run `ulauncher-toggle` twice) to pick it up. The default
keyword is `cc` — type it, or bind Ulauncher's own global hotkey
(Ulauncher Preferences → Shortcuts) to open it directly. Selecting a session
focuses its terminal window.

### 5. Window focus

No extra setup: `focus/copilot_focus.sh` uses `wmctrl` and an OSC-title marker
written to the session's own tty — see the design spec for how, and for the
known limitation with split-pane terminal windows (a Terminator window comes
to the front, but keyboard focus may remain on whichever pane held it before
the switch).

## How it works

See `docs/superpowers/specs/2026-07-28-copilot-bar-design.md` for the full
design: the state machine driven by Copilot CLI's hooks, the session file
schema, and the focus algorithm.

## Development

```bash
./tests/test_states.sh          # state derivation, rendering, feed, focus
./tests/test_plugin_hooks.sh    # plugin hook behavior
python3 tests/test_ulauncher_main.py -v   # Ulauncher extension logic
```

Every plugin/script can also be run by hand to see exactly what it emits:

```bash
./bar/copilot_sessions.sh          # what Argos will show
./bin/copilot-bar-feed | jq .      # what Ulauncher will show
./focus/copilot_focus.sh <pid>     # focus a session directly
```
```

- [ ] **Step 2: Run the full test suite one last time**

```bash
./tests/test_states.sh && ./tests/test_plugin_hooks.sh && python3 tests/test_ulauncher_main.py -v
```

Expected: all three report success (`all checks passed` ×2, `OK` for the Python suite).

- [ ] **Step 3: End-to-end manual verification checklist**

Not automatable — walk through this once after installing for real:

1. `copilot plugin install "$PWD/plugin"` (if not already done in Task 6).
2. Symlink the Argos script and the Ulauncher extension as in the README.
3. Open a Terminator window, run `copilot` interactively, ask it to do
   something.
4. Confirm the Argos panel button shows `✦ 1` and, while a tool is running,
   tints blue; open its dropdown and confirm the row reads `working`.
5. Ask Copilot to run a command that needs approval (without
   `--allow-all-tools`); confirm the panel button turns red and badges the
   project name before you approve it.
6. Approve it, let the turn finish; confirm the dropdown row switches to
   `idle` (shown as "just finished" for the next 5 minutes).
7. Click that dropdown row; confirm the Terminator window comes to the front.
8. Type `cc` in Ulauncher; confirm the same session appears, select it with
   Enter, confirm the same window comes to the front.
9. Exit the `copilot` session; confirm both the Argos dropdown and the
   Ulauncher list stop showing it.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Add README with install and verification instructions

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```
