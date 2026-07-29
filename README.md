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

### Known limitations

The Copilot CLI plugin's `notification` and `stop` hooks (which drive the
`needs_input` red-badge and `idle` states) were built against payload shapes
that were not confirmed against a real interactive `copilot` session. The
`needs_input` and `idle` states may not fire exactly as expected until a
human verifies this with a real tty. See plugin development notes for
verification instructions.

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
