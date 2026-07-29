# copilot-bar

Keep an eye on every running `copilot-cli` session at once, from your GNOME
top bar and from the keyboard — a port of
[jcgay/claude-bar](https://github.com/jcgay/claude-bar) from Claude Code +
macOS to GitHub Copilot CLI + Ubuntu. Design rationale lives in
`docs/superpowers/specs/2026-07-28-copilot-bar-design.md`.

```
menu bar:  ✦ 3  🔴 arthur

── dropdown ──────────────────
🔴 arthur      needs input 8s
🔵 deltatom    working 1m
⚪ pipe∣farm   idle 3h
```

| Icon | State | Color |
| --- | --- | --- |
| `🔴` | Needs input (permission prompt) | red |
| `🟡` | Finished within the last 5 minutes | yellow |
| `🔵` | Working | blue |
| `⚪` | Idle for over 5 minutes | grey |

The icons above are color emoji, not colored text: GNOME Shell's own panel
widget does not support colored *text* for the top-bar button itself — a
GNOME Shell/Argos limitation (not Ubuntu-specific, and not something
copilot-bar can work around: no `color=` attribute has any effect there).
Color emoji sidestep this entirely, since they're rendered as actual colored
glyphs rather than text with a color attribute — so the bar itself *is*
colored, both in the top-bar button and the dropdown, as long as a color
emoji font is installed (see requirements below).

## Install

### 1. Requirements

```bash
sudo apt install jq wmctrl fonts-noto-color-emoji
```

Argos (GNOME Shell extension) and Ulauncher are assumed already installed.
This has only been tested on X11 — `wmctrl` needs a real or XWayland-visible
window, so it will not work on native Wayland.

### 2. Argos menu bar

```bash
mkdir -p ~/.config/argos
ln -sfn "$PWD/bar/copilot_sessions.sh" ~/.config/argos/copilot-bar.10s.sh
```

The `10s` in that filename is the refresh interval — Argos reads it from the
name. Symlinking rather than copying keeps the checkout as the source of
truth, so `git pull` is the whole update path.

### 3. Ulauncher extension

```bash
ln -sfn "$PWD/ulauncher/copilot-bar" ~/.local/share/ulauncher/extensions/copilot-bar
```

Restart Ulauncher (or run `ulauncher-toggle` twice) to pick it up. The default
keyword is `cc` — type it, or bind Ulauncher's own global hotkey
(Ulauncher Preferences → Shortcuts) to open it directly. Selecting a session
focuses its terminal window.

### 4. Window focus

No extra setup: `focus/copilot_focus.sh` uses `wmctrl` and an OSC-title marker
written to the session's own tty — see the design spec for how, and for the
known limitation with split-pane terminal windows (a Terminator window comes
to the front, but keyboard focus may remain on whichever pane held it before
the switch).

### Known limitations

**No plugin or hook install is required.** copilot-bar reads session state
directly from Copilot CLI's own per-session event log at
`~/.copilot/session-state/<uuid>/events.jsonl`, present for every session
without any configuration. An earlier version of this tool used a
hooks-based plugin instead — that approach is documented in git history
(see commits up to and including `f8e6907`) but has been fully replaced,
because it turned out to have a real gap: the CLI's `notification` hook
never fires for `ask_user`-style "choose between these options" dialogs, so
a session could sit waiting on the user while the bar still showed
`working`. Reading `events.jsonl` directly covers that case (via a
`tool.execution_start` for `toolName: "ask_user"` with no matching
`tool.execution_complete`) along with every genuine permission prompt (via
`permission.requested`/`permission.completed`, tracked for every `kind`
observed — an earlier revision of this tool restricted this to
`shell`/`write`/`url` and wrongly treated `kind: "hook"` as a silent,
non-blocking auto-decision; that was wrong, `kind: "hook"` is exactly the
"RTK auto-rewrite" hook-permission dialog a user actually clicks Yes/No on,
confirmed by `denied-interactively-by-user` outcomes in real event logs —
so it's tracked the same as every other kind now), with no hook coverage
gaps.

- **`~/.copilot/session-state/` is undocumented and internal.** Its format
  (`events.jsonl` event types and field names, `workspace.yaml` layout,
  `inuse.<pid>.lock` naming) is not part of any public Copilot CLI API and
  could change without notice in a future CLI release, unlike the
  documented hooks API the old plugin relied on. If a future CLI version
  changes this layout, `read_sessions()` in `lib/state.sh` is the single
  place that needs updating.
- **`inuse.<pid>.lock` files can outlive their process.** They are written
  by the CLI per session directory but are not reliably cleaned up when a
  session crashes or is killed, so `read_sessions()` does not trust their
  mere existence — every consumer (`bar/copilot_sessions.sh`,
  `bin/copilot-bar-feed`) still filters dead pids with `kill -0` before
  rendering a row, exactly as before.
- **`events.jsonl` can grow large** (17MB+ observed for a long-running
  session), so only the trailing `COPILOT_BAR_EVENTS_TAIL_LINES` (default
  500) lines are read per refresh, not the whole file. A session with an
  unusually bursty tail (hundreds of tool calls between the last
  turn-boundary and now) could in theory scroll the relevant turn-start out
  of that window; raise the env var if that's ever observed in practice.

## How it works

See `docs/superpowers/specs/2026-07-28-copilot-bar-design.md` for the
original design rationale (menu bar layout, focus algorithm, Ulauncher
integration). The state machine itself was rewritten after that spec was
written: `lib/state.sh`'s `read_sessions()` now derives each session's raw
state (`working` / `needs_input` / `idle`) by tailing its
`~/.copilot/session-state/<uuid>/events.jsonl` and reducing over
`assistant.turn_start`/`turn_end`, `permission.requested`/`.completed`, and
`tool.execution_start`/`.complete` events with a small `jq` state machine —
see the comments directly above `read_sessions()` for the exact rules.

## Development

```bash
./tests/test_states.sh                    # state derivation, rendering, feed, focus
python3 tests/test_ulauncher_main.py -v   # Ulauncher extension logic
```

Every plugin/script can also be run by hand to see exactly what it emits:

```bash
./bar/copilot_sessions.sh          # what Argos will show
./bin/copilot-bar-feed | jq .      # what Ulauncher will show
./focus/copilot_focus.sh <pid>     # focus a session directly
```
