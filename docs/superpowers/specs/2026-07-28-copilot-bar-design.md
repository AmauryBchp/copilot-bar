# copilot-bar design

Port of [jcgay/claude-bar](https://github.com/jcgay/claude-bar) — a menu bar and
keyboard session switcher — from Claude Code + macOS to **GitHub Copilot CLI +
Ubuntu**.

## Goal

Keep an eye on every running `copilot-cli` session at once, from two places:

- A GNOME top bar indicator (Argos), showing which sessions need attention.
- A keyboard-driven switcher (Ulauncher), narrowing the list as you type.

Selecting a session in either place refreshes focus to the terminal window
running it.

## Why this can't be a 1:1 port

claude-bar relies on three things that don't exist for Copilot CLI on Ubuntu:

1. Claude Code writes one `~/.claude/sessions/<pid>.json` file per live
   session, updated in place with a `status` field (`busy`/`waiting`/`idle`).
   Copilot CLI has no equivalent live status file — its on-disk state
   (`~/.copilot/session-store.db`, `~/.copilot/session-state/<uuid>/`) is a
   history store, not a live status signal.
2. SwiftBar (macOS menu bar) has no Ubuntu/GNOME equivalent.
3. Alfred (macOS keyboard launcher) has no Ubuntu equivalent, and the
   click-to-focus trick used a Ghostty-specific AppleScript dictionary tied to
   macOS Accessibility/Automation permissions.

This design replaces each with an Ubuntu-native equivalent:

1. **A Copilot CLI plugin using its native hook system** (`sessionStart`,
   `preToolUse`, `postToolUse`, `notification`, `stop`, `sessionEnd`) computes
   and persists the live status ourselves, in the same spirit as Claude Code's
   own status file.
2. **Argos**, a GNOME Shell extension that runs scripts in the exact BitBar/
   SwiftBar text-protocol shape (title line, `---`, dropdown lines with
   `key=value` params), so the plugin's rendering logic ports almost
   unchanged.
3. **Ulauncher**, already installed by the user, whose extension API
   (keyword trigger + dynamic result list + on-select action) covers the same
   role as an Alfred Script Filter + Run Script pair — and Ulauncher owns its
   own global hotkey, so no separate "Hotkey object" is needed.

Window focus is re-implemented with `wmctrl` and the same OSC-title-marker
technique claude-bar uses for Ghostty, generalized to any X11 terminal.

## Confirmed via experimentation

Before writing this spec, a throwaway plugin was installed locally
(`copilot plugin install <path>`, requires a `plugin.json` with a `"hooks":
"hooks.json"` field) and exercised with `copilot -p "..." --allow-all-tools`.
Confirmed hook payloads (delivered as JSON on the hook command's stdin):

```jsonc
// sessionStart
{"sessionId":"...","timestamp":1785232366156,"cwd":"/tmp","source":"new","initialPrompt":"..."}
// preToolUse
{"sessionId":"...","timestamp":...,"cwd":"/tmp","toolName":"bash","toolArgs":"{\"command\":\"ls\",...}"}
// postToolUse
{"sessionId":"...","timestamp":...,"cwd":"/tmp","toolName":"bash","toolArgs":"...","toolResult":{"resultType":"success","textResultForLlm":"..."}}
// sessionEnd
{"sessionId":"...","timestamp":1785232372359,"cwd":"/tmp","reason":"complete"}
```

The hook process's environment additionally carries `COPILOT_LOADER_PID` (the
OS pid of the running `copilot` process — the same role Claude Code's
`<pid>.json` filename plays) and `COPILOT_PROJECT_DIR`.

**Not yet confirmed**: the exact payload shape for `notification` and `stop`.
Both hook names exist in the CLI (verified by string search in the installed
binary), but a non-interactive (`-p --allow-all-tools`) session never
triggers them — `notification` is presumed to fire on a permission prompt,
`stop` when a turn ends and the CLI is about to wait on the user again.
Confirming this against a real interactive session is the first task of the
implementation plan, before the rest of the plugin is built against it.

## Architecture

Four independent pieces, mirroring claude-bar's `plugins/` split:

```
copilot-bar/
├── plugin/                     # Copilot CLI plugin (hooks)
│   ├── plugin.json
│   ├── hooks.json
│   └── hooks/update-session-state.sh
├── bar/
│   └── copilot_sessions.sh     # Argos script (BitBar/SwiftBar protocol)
├── focus/
│   └── copilot_focus.sh        # wmctrl + OSC-title-marker focus
├── ulauncher/
│   └── copilot-bar/            # Ulauncher extension (manifest.json + main.py)
├── tests/
│   ├── fixtures/*.json
│   └── test_states.sh
└── README.md
```

`bar/copilot_sessions.sh` and `ulauncher/.../main.py` both source their state
derivation logic from one shared shell library (`lib/state.sh`), the way
claude-bar's `claude_alfred.sh` sources `claude_sessions.sh` — one
implementation of `derive_state`/`state_color`/`state_icon`/`most_urgent`,
two renderers.

## Data flow and state machine

The plugin writes one file per live session to
`~/.copilot-bar/sessions/<pid>.json`:

```json
{
  "pid": 147278,
  "sessionId": "640414c6-...",
  "cwd": "/home/abeauchamp@france.groupe.intra/some-project",
  "project": "some-project",
  "state": "working",
  "stateUpdatedAt": 1785232369990
}
```

Hook effects on `state`:

| Hook            | New `state`                                             |
|-----------------|----------------------------------------------------------|
| `sessionStart`  | `working` if `initialPrompt` is set, else `idle`          |
| `preToolUse`    | `working`                                                 |
| `postToolUse`   | unchanged (stays `working` — the agent usually continues) |
| `notification`  | `needs_input`                                             |
| `stop`          | `idle`                                                    |
| `sessionEnd`    | file is deleted                                           |

Every write is `pid`-keyed and atomic (write to a temp file, `mv` into place),
so a crash mid-write never leaves a half-written file for the reader to trip
over.

Readers (Argos script and Ulauncher extension) turn the raw `state` plus the
age of `stateUpdatedAt` into the same four display states claude-bar uses,
with the same 5-minute "just finished" window and urgency order:

- `needs_input` → red `●` — always shown, always most urgent.
- `just_finished` → yellow `○` — `state == idle` and `stateUpdatedAt` is less
  than 5 minutes old.
- `working` → blue `◐`.
- `dormant` → grey `·` — `state == idle` for 5+ minutes.

A session file whose `pid` fails `kill -0` is skipped (crashed process; the
`sessionEnd` hook never ran). This is the same liveness check claude-bar uses
for Claude Code's own session files, and it's necessary here for the same
reason: hooks can't run once the process is dead.

## Window focus

`focus/copilot_focus.sh <pid>`:

1. `ps -o tty= -p <pid>` to find the controlling tty. No tty (headless/detached)
   → error, nothing to focus.
2. `wmctrl -l` to snapshot every window's id and title.
3. Write a unique marker (`⟦copilot-bar:<pid>⟧`) as an OSC 2 title escape to
   `/dev/<tty>`.
4. Poll `wmctrl -l` briefly for a window whose title is that marker.
5. `wmctrl -ia <id>` to raise and focus it.
6. Look up that window id's previous title in the step-2 snapshot and write it
   back to the tty, so the marker doesn't linger on screen.

This is the same algorithm as claude-bar's Ghostty AppleScript script, with
`wmctrl` standing in for the AppleScript dictionary — X11 window titles are the
portable primitive AppleScript's `terminal` objects were on macOS.

**Known limitation**: because the user runs one Terminator window per
session, split into two panes (Copilot on the left, a plain shell on the
right), `wmctrl -ia` reliably raises and focuses the *correct window*, but
Terminator has no scripting API to force keyboard focus onto a specific pane.
If the right-hand shell pane held focus before the switch, the window comes
to the front with focus still on that pane, not on Copilot. The user has
accepted this tradeoff; it is not a bug to fix in v1.

## Argos menu bar

`bar/copilot_sessions.sh`, symlinked as `~/.config/argos/copilot-bar.20s.sh`
(interval encoded in the filename, same convention as SwiftBar). Reads every
`~/.copilot-bar/sessions/*.json`, filters dead pids, renders:

```
✦ 3  ● arthur

── dropdown ──────────────────
● arthur      needs input 8s
◐ deltatom    working 1m
· copilot-bar idle 3h
```

Each dropdown line carries `bash="<path>/focus/copilot_focus.sh" param1=<pid>
terminal=false`, matching the Argos/BitBar param syntax. A missing `jq` or
`wmctrl` renders a visible warning line instead of silently showing "no
sessions" — Argos, like SwiftBar, runs plugins with a GUI process's minimal
`PATH`.

## Ulauncher extension

`ulauncher/copilot-bar/` is a standard Ulauncher extension: `manifest.json`
declaring a keyword (default `cc`), and `main.py` with a
`KeywordQueryEventListener` that lists sessions sorted by urgency (same rank
as the Argos dropdown: `needs_input` > `just_finished` > `working` >
`dormant`, then longest-waiting first within a rank) and an
`ItemEnterEventListener` that shells out to `focus/copilot_focus.sh <pid>`.
Ulauncher supplies its own global hotkey configuration (Ulauncher Preferences
→ Shortcuts), so unlike the Alfred workflow there is no separate hotkey
object to wire — one extension covers both the keyword and the hotkey path.

## Error handling

- Missing `jq` or `wmctrl`: both the Argos script and the Ulauncher extension
  show one explicit "tool not found" row rather than an empty list.
- Malformed/truncated JSON session file: skipped for that file only (one `jq`
  invocation per file, as in claude-bar), never aborts the whole read.
- Dead process (pid fails `kill -0`): file ignored by readers. The plugin
  itself does not need to clean these up — a stale file with a dead pid is
  invisible to every reader, and `sessionEnd` deletes files for graceful
  exits.
- Non-numeric `stateUpdatedAt`: guarded before doing arithmetic on it, same
  as claude-bar's `[[ "$updated" =~ ^[0-9]+$ ]]` guard.

## Testing

`tests/test_states.sh`, no external dependencies beyond `bash` and `jq`,
covering:

- State derivation from raw `state` + age (`working`/`needs_input`/
  `just_finished`/`dormant`).
- Urgency ranking and the "longest wait first" tiebreak.
- Colors and icons per state.
- Age formatting.
- Rendered output for both the Argos dropdown and the Ulauncher list, against
  fixtures in `tests/fixtures/` carrying a pid placeholder rewritten to the
  test's own pid (so the dead-process filter is exercised for real, as in
  claude-bar).

## Out of scope for v1

- Forcing keyboard focus onto a specific Terminator pane (accepted
  limitation, see above).
- Wayland support (the user's session is X11; `wmctrl` requires X11 or
  XWayland-visible windows).
- Any terminal other than Terminator is not explicitly tested, though the
  OSC-title-marker + `wmctrl` approach should generalize to any X11 terminal
  emulator that honors OSC 2.
